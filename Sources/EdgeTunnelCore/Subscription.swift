import Foundation

public enum Subscription {
  public static func token(hostname: String, uuid: String) -> String {
    let first = Digest.md5Hex(hostname.lowercased() + uuid.lowercased())
    let start = first.index(first.startIndex, offsetBy: 7)
    let end = first.index(start, offsetBy: 20)
    return Digest.md5Hex(String(first[start..<end])).lowercased()
  }

  public static func makeURL(hostname: String, uuid: String) throws -> URL {
    let hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !hostname.isEmpty else {
      throw EdgeTunnelError.invalidResponse(status: nil)
    }
    var components = URLComponents()
    components.scheme = "https"
    components.host = hostname
    components.path = "/sub"
    components.queryItems = [
      URLQueryItem(name: "token", value: token(hostname: hostname, uuid: uuid)),
      URLQueryItem(name: "target", value: "mixed"),
      URLQueryItem(name: "b64", value: "1"),
    ]
    guard let url = components.url else {
      throw EdgeTunnelError.invalidResponse(status: nil)
    }
    return url
  }

  @discardableResult
  public static func validateBase64VLESS(
    _ data: Data,
    expectedUUID: String? = nil
  ) throws -> [String] {
    guard let encodedText = String(data: data, encoding: .utf8) else {
      throw EdgeTunnelError.invalidResponse(status: nil)
    }
    let compact = encodedText.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
    }.map(String.init).joined()
    guard !compact.isEmpty,
      compact.utf8.count % 4 == 0,
      compact.unicodeScalars.allSatisfy({ scalar in
        ("A"..."Z").contains(Character(String(scalar)))
          || ("a"..."z").contains(Character(String(scalar)))
          || ("0"..."9").contains(Character(String(scalar)))
          || scalar == "+" || scalar == "/" || scalar == "="
      }),
      let decoded = Data(base64Encoded: compact),
      let decodedText = String(data: decoded, encoding: .utf8)
    else {
      throw EdgeTunnelError.invalidResponse(status: nil)
    }

    let links =
      decodedText
      .split(whereSeparator: \Character.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { isCompatibleVLESS($0, expectedUUID: expectedUUID) }
    guard !links.isEmpty else {
      throw EdgeTunnelError.invalidResponse(status: nil)
    }
    return links
  }

  private static func isCompatibleVLESS(_ value: String, expectedUUID: String?) -> Bool {
    guard value.lowercased().hasPrefix("vless://"),
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "vless",
      let user = components.user,
      isUUID(user),
      let host = components.host,
      !host.isEmpty,
      let port = components.port,
      (1...65_535).contains(port)
    else {
      return false
    }
    if let expectedUUID, user.lowercased() != expectedUUID.lowercased() {
      return false
    }
    let query = Dictionary(
      (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name.lowercased(), $0.lowercased()) }
      },
      uniquingKeysWith: { first, _ in first }
    )
    return query["encryption"] == "none"
      && query["security"] == "tls"
      && query["type"] == "ws"
      && !(query["sni"] ?? "").isEmpty
      && !(query["host"] ?? "").isEmpty
  }

  private static func isUUID(_ value: String) -> Bool {
    let parts = value.lowercased().split(separator: "-", omittingEmptySubsequences: false)
    return parts.map(\.count) == [8, 4, 4, 4, 12]
      && parts.joined().utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}

public struct SubscriptionVerifier {
  public typealias Sleep = (UInt64) async throws -> Void

  private let transport: HTTPTransport
  private let sleep: Sleep

  public init(
    transport: HTTPTransport,
    sleep: @escaping Sleep = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.transport = transport
    self.sleep = sleep
  }

  public func verify(_ url: URL, expectedUUID: String, attempts: Int = 8) async throws {
    let attempts = max(1, attempts)
    for attempt in 0..<attempts {
      do {
        let response = try await transport.send(
          HTTPRequest(
            method: "GET",
            url: url,
            headers: [
              "Accept": "text/plain",
              "User-Agent": "EdgeTunnelSwift/1.0",
            ],
            timeout: 30,
            maximumResponseSize: EdgeTunnelConstants.maximumWorkerSize
          )
        )
        guard (200..<300).contains(response.statusCode) else {
          throw EdgeTunnelError.invalidResponse(status: response.statusCode)
        }
        try Subscription.validateBase64VLESS(response.body, expectedUUID: expectedUUID)
        return
      } catch {
        if Task.isCancelled { throw error }
        if attempt + 1 < attempts {
          let milliseconds = min(500 * (1 << min(attempt, 4)), 5_000)
          try await sleep(UInt64(milliseconds) * 1_000_000)
        }
      }
    }
    throw EdgeTunnelError.subscriptionVerificationFailed(attempts: attempts)
  }
}
