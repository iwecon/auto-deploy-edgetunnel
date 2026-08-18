import Foundation

public final class CloudflareClient {
  private let token: String
  private let transport: HTTPTransport
  private let baseURL: URL

  public init(
    token: String,
    transport: HTTPTransport,
    baseURL: URL = EdgeTunnelConstants.cloudflareAPIBaseURL
  ) throws {
    let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw EdgeTunnelError.usage("Cloudflare API Token 不能为空。")
    }
    self.token = normalized
    self.transport = transport
    self.baseURL = baseURL
  }

  public func verifyToken(accountID: String) async throws {
    let accountPath = ["accounts", accountID, "tokens", "verify"]
    do {
      let payload = try await apiRequest(method: "GET", path: accountPath)
      try ensureActiveToken(payload)
      return
    } catch {
      let payload = try await apiRequest(method: "GET", path: ["user", "tokens", "verify"])
      try ensureActiveToken(payload)
    }
  }

  func listKVNamespaces(accountID: String) async throws -> [KVNamespace] {
    var namespaces: [KVNamespace] = []
    var page = 1
    var totalPages = 1
    repeat {
      let payload = try await apiRequest(
        method: "GET",
        path: ["accounts", accountID, "storage", "kv", "namespaces"],
        query: [
          URLQueryItem(name: "per_page", value: "100"),
          URLQueryItem(name: "page", value: String(page)),
        ]
      )
      guard let result = payload["result"] as? [[String: Any]] else {
        throw EdgeTunnelError.invalidResponse(status: 200)
      }
      namespaces.append(
        contentsOf: result.compactMap { item in
          guard let id = item["id"] as? String,
            let title = item["title"] as? String
          else {
            return nil
          }
          return KVNamespace(id: id, title: title)
        })
      if let resultInfo = payload["result_info"] as? [String: Any],
        let number = Self.integer(resultInfo["total_pages"])
      {
        totalPages = max(1, number)
      }
      page += 1
    } while page <= totalPages
    return namespaces
  }

  func createKVNamespace(accountID: String, title: String) async throws -> KVNamespace {
    let body = try Self.jsonData(["title": title])
    let payload = try await apiRequest(
      method: "POST",
      path: ["accounts", accountID, "storage", "kv", "namespaces"],
      headers: ["Content-Type": "application/json"],
      body: body
    )
    guard let result = payload["result"] as? [String: Any],
      let id = result["id"] as? String,
      !id.isEmpty
    else {
      throw EdgeTunnelError.invalidResponse(status: 200)
    }
    return KVNamespace(id: id, title: (result["title"] as? String) ?? title)
  }

  func getKVValue(
    accountID: String,
    namespaceID: String,
    key: String
  ) async throws -> Data? {
    let response = try await rawAPIRequest(
      method: "GET",
      path: [
        "accounts", accountID, "storage", "kv", "namespaces", namespaceID, "values", key,
      ],
      maximumResponseSize: EdgeTunnelConstants.maximumWorkerSize
    )
    if response.statusCode == 404 {
      return nil
    }
    guard (200..<300).contains(response.statusCode) else {
      _ = try parseAPIResponse(response, redacting: [])
      throw EdgeTunnelError.invalidResponse(status: response.statusCode)
    }
    return response.body
  }

  func putKVValue(
    _ value: Data,
    contentType: String,
    accountID: String,
    namespaceID: String,
    key: String
  ) async throws {
    guard value.count <= EdgeTunnelConstants.maximumWorkerSize else {
      throw EdgeTunnelError.responseTooLarge(limit: EdgeTunnelConstants.maximumWorkerSize)
    }
    let response = try await rawAPIRequest(
      method: "PUT",
      path: [
        "accounts", accountID, "storage", "kv", "namespaces", namespaceID, "values", key,
      ],
      headers: ["Content-Type": contentType],
      body: value,
      maximumResponseSize: EdgeTunnelConstants.maximumWorkerSize
    )
    _ = try parseAPIResponse(response, redacting: [])
  }

  func getPagesProject(accountID: String, name: String) async throws -> PagesProject? {
    let response = try await rawAPIRequest(
      method: "GET",
      path: ["accounts", accountID, "pages", "projects", name]
    )
    if response.statusCode == 404 {
      return nil
    }
    let payload = try parseAPIResponse(response, redacting: [])
    return try Self.pagesProject(from: payload)
  }

  func createPagesProject(accountID: String, name: String) async throws -> PagesProject {
    let body = try Self.jsonData([
      "name": name,
      "production_branch": "main",
    ])
    let payload = try await apiRequest(
      method: "POST",
      path: ["accounts", accountID, "pages", "projects"],
      headers: ["Content-Type": "application/json"],
      body: body
    )
    return try Self.pagesProject(from: payload)
  }

  func configurePagesProject(
    accountID: String,
    name: String,
    namespaceID: String,
    uuid: String,
    adminPassword: String,
    upstreamCommit: String
  ) async throws -> PagesProject {
    let configuration: [String: Any] = [
      "deployment_configs": [
        "production": [
          "compatibility_date": EdgeTunnelConstants.compatibilityDate,
          "env_vars": [
            "UUID": ["type": "secret_text", "value": uuid],
            "ADMIN": ["type": "secret_text", "value": adminPassword],
            "EDGETUNNEL_UPSTREAM": ["type": "plain_text", "value": upstreamCommit],
            "OFF_LOG": ["type": "plain_text", "value": "true"],
          ],
          "kv_namespaces": [
            "KV": ["namespace_id": namespaceID]
          ],
        ]
      ]
    ]
    let payload = try await apiRequest(
      method: "PATCH",
      path: ["accounts", accountID, "pages", "projects", name],
      headers: ["Content-Type": "application/json"],
      body: try Self.jsonData(configuration),
      redacting: [uuid, adminPassword]
    )
    return try Self.pagesProject(from: payload)
  }

  func createPagesDeployment(
    accountID: String,
    projectName: String,
    worker: Data,
    upstreamCommit: String,
    redacting secrets: [String]
  ) async throws -> String {
    var form = MultipartForm()
    form.addField(name: "commit_dirty", value: "false")
    form.addField(name: "commit_hash", value: upstreamCommit)
    form.addField(name: "commit_message", value: "EdgeTunnel Swift \(upstreamCommit)")
    form.addField(name: "manifest", value: "{}")
    form.addFile(
      name: "_worker.js",
      filename: "_worker.js",
      contentType: "application/javascript+module",
      contents: worker
    )
    form.finish()
    let payload = try await apiRequest(
      method: "POST",
      path: ["accounts", accountID, "pages", "projects", projectName, "deployments"],
      headers: ["Content-Type": "multipart/form-data; boundary=\(form.boundary)"],
      body: form.data,
      timeout: 60,
      redacting: secrets
    )
    guard let result = payload["result"] as? [String: Any],
      let id = result["id"] as? String,
      !id.isEmpty
    else {
      throw EdgeTunnelError.invalidResponse(status: 200)
    }
    return id
  }

  func getPagesDeploymentStage(
    accountID: String,
    projectName: String,
    deploymentID: String
  ) async throws -> PagesDeploymentStage {
    let payload = try await apiRequest(
      method: "GET",
      path: [
        "accounts", accountID, "pages", "projects", projectName,
        "deployments", deploymentID,
      ]
    )
    guard let result = payload["result"] as? [String: Any],
      let latestStage = result["latest_stage"] as? [String: Any],
      let rawStatus = latestStage["status"] as? String
    else {
      throw EdgeTunnelError.invalidResponse(status: 200)
    }
    let status = rawStatus.lowercased()
    switch status {
    case "success":
      return .success
    case "failure", "failed", "canceled", "cancelled":
      return .failed(status)
    default:
      return .pending(status)
    }
  }

  private func ensureActiveToken(_ payload: [String: Any]) throws {
    guard let result = payload["result"] as? [String: Any],
      (result["status"] as? String)?.lowercased() == "active"
    else {
      throw EdgeTunnelError.tokenInactive
    }
  }

  private func apiRequest(
    method: String,
    path: [String],
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 30,
    redacting: [String] = []
  ) async throws -> [String: Any] {
    let response = try await rawAPIRequest(
      method: method,
      path: path,
      query: query,
      headers: headers,
      body: body,
      timeout: timeout
    )
    return try parseAPIResponse(response, redacting: redacting)
  }

  private func rawAPIRequest(
    method: String,
    path: [String],
    query: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 30,
    maximumResponseSize: Int = EdgeTunnelConstants.maximumResponseSize
  ) async throws -> HTTPResponse {
    var url = baseURL
    for segment in path {
      url.appendPathComponent(segment)
    }
    if !query.isEmpty {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        throw EdgeTunnelError.invalidResponse(status: nil)
      }
      components.queryItems = query
      guard let queryURL = components.url else {
        throw EdgeTunnelError.invalidResponse(status: nil)
      }
      url = queryURL
    }
    var requestHeaders = [
      "Authorization": "Bearer \(token)",
      "Accept": "application/json",
      "User-Agent": "EdgeTunnelSwift/1.0",
    ]
    for (name, value) in headers {
      requestHeaders[name] = value
    }
    return try await transport.send(
      HTTPRequest(
        method: method,
        url: url,
        headers: requestHeaders,
        body: body,
        timeout: timeout,
        maximumResponseSize: maximumResponseSize
      )
    )
  }

  private func parseAPIResponse(
    _ response: HTTPResponse,
    redacting additionalSecrets: [String]
  ) throws -> [String: Any] {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: response.body)
    } catch {
      throw EdgeTunnelError.invalidResponse(status: response.statusCode)
    }
    guard let payload = object as? [String: Any] else {
      throw EdgeTunnelError.invalidResponse(status: response.statusCode)
    }
    if (200..<300).contains(response.statusCode), payload["success"] as? Bool == true {
      return payload
    }
    let secrets = [token] + additionalSecrets
    let problems = (payload["errors"] as? [[String: Any]] ?? [])
      .prefix(3)
      .map { item in
        let raw = (item["message"] as? String) ?? "Cloudflare API error"
        let compact =
          raw
          .replacingOccurrences(of: "\r", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
        let limited = String(compact.prefix(256))
        return CloudflareAPIProblem(
          code: Self.integer(item["code"]),
          message: SensitiveDataRedactor.redact(limited, secrets: secrets)
        )
      }
    throw EdgeTunnelError.cloudflareAPI(status: response.statusCode, problems: problems)
  }

  private static func pagesProject(from payload: [String: Any]) throws -> PagesProject {
    guard let result = payload["result"] as? [String: Any],
      let id = result["id"] as? String,
      let name = result["name"] as? String,
      let subdomain = result["subdomain"] as? String,
      !id.isEmpty,
      !name.isEmpty,
      !subdomain.isEmpty
    else {
      throw EdgeTunnelError.invalidResponse(status: 200)
    }
    let canonical = result["canonical_deployment"] as? [String: Any]
    return PagesProject(
      id: id,
      name: name,
      subdomain: subdomain.lowercased(),
      canonicalDeploymentID: canonical?["id"] as? String
    )
  }

  private static func jsonData(_ object: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      throw EdgeTunnelError.invalidResponse(status: nil)
    }
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func integer(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value)
    }
    return nil
  }
}
