import Foundation
import XCTest

@testable import EdgeTunnelCore

final class HashingAndValidationTests: XCTestCase {
  func testDigestKnownVectors() {
    XCTAssertEqual(Digest.md5Hex(""), "d41d8cd98f00b204e9800998ecf8427e")
    XCTAssertEqual(Digest.md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
    XCTAssertEqual(
      Digest.sha256Hex(Data()),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    XCTAssertEqual(
      Digest.sha256Hex(Data("abc".utf8)),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
  }

  func testAccountAndDefaultProjectValidation() throws {
    let account = "ABCDEF0123456789ABCDEF0123456789"
    let normalized = try InputValidator.accountID(account)
    XCTAssertEqual(normalized, account.lowercased())
    XCTAssertEqual(
      EdgeTunnelConstants.defaultProjectName(accountID: normalized),
      "in-iiiam-abcdef0123456789abcdef0123456789"
    )
    XCTAssertThrowsError(try InputValidator.accountID("not-an-account"))
    XCTAssertThrowsError(try InputValidator.projectName("-bad"))
  }

  func testSubscriptionTokenAndStrictVLESSDecode() throws {
    let hostname = "llet-0123456789abcdef0123456789abcdef.pages.dev"
    let uuid = "11111111-2222-4333-8444-555555555555"
    XCTAssertEqual(
      Subscription.token(hostname: hostname, uuid: uuid),
      "2fc135d3099fd66e6cfe5f15577c37cc"
    )
    let valid =
      "vless://11111111-2222-4333-8444-555555555555@edge.example.com:443?encryption=none&security=tls&type=ws&sni=tls.example.com&host=ws.example.com"
    let encoded = Data(valid.utf8).base64EncodedData()
    XCTAssertEqual(try Subscription.validateBase64VLESS(encoded), [valid])
    XCTAssertEqual(
      try Subscription.validateBase64VLESS(encoded, expectedUUID: uuid),
      [valid]
    )
    XCTAssertThrowsError(
      try Subscription.validateBase64VLESS(
        encoded,
        expectedUUID: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
      )
    )

    let invalid = Data("trojan://ignored".utf8).base64EncodedData()
    XCTAssertThrowsError(try Subscription.validateBase64VLESS(invalid))
    XCTAssertThrowsError(try Subscription.validateBase64VLESS(Data("not-base64!".utf8)))
  }
}

final class StateAndWorkerTests: XCTestCase {
  func testStateUsesPlatformProtectionAndContainsNoToken() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("state.json")
    let state = DeploymentState(
      accountID: String(repeating: "a", count: 32),
      projectName: "llet-\(String(repeating: "a", count: 32))",
      kvNamespaceTitle: "in.iiiam-edgetunnel"
    )
    try DeploymentStateStore(fileURL: file).save(state)
    #if !os(Windows)
      let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    #endif
    let contents = try String(contentsOf: file, encoding: .utf8)
    XCTAssertFalse(contents.contains("super-secret-token"))
    XCTAssertTrue(contents.contains(state.adminPassword))
  }

  func testWorkerIntegrityMismatchFails() async throws {
    let source = Data("worker".utf8)
    let transport = MockTransport { request in
      XCTAssertEqual(request.url.host, "example.invalid")
      return HTTPResponse(statusCode: 200, body: source)
    }
    let descriptor = UpstreamDescriptor(
      commit: "test",
      url: URL(string: "https://example.invalid/_worker.js")!,
      sha256: String(repeating: "0", count: 64),
      maximumSize: 1024
    )
    do {
      _ = try await WorkerSourceLoader(transport: transport, upstream: descriptor).load(file: nil)
      XCTFail("Expected integrity failure")
    } catch let error as EdgeTunnelError {
      guard case .workerIntegrity = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testStateRejectsWidePermissionsAndSymlink() throws {
    #if os(Windows)
      throw XCTSkip("Windows 使用继承 ACL，无法执行 POSIX 权限断言；创建符号链接还依赖开发者模式。")
    #else
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let stateFile = directory.appendingPathComponent("state.json")
      let state = DeploymentState(
        accountID: String(repeating: "a", count: 32),
        projectName: "llet-\(String(repeating: "a", count: 32))",
        kvNamespaceTitle: "in.iiiam-edgetunnel"
      )
      try DeploymentStateStore(fileURL: stateFile).save(state)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: stateFile.path)
      XCTAssertThrowsError(try DeploymentStateStore(fileURL: stateFile).load())

      try FileManager.default.removeItem(at: stateFile)
      let target = directory.appendingPathComponent("target.json")
      try DeploymentStateStore(fileURL: target).save(state)
      try FileManager.default.createSymbolicLink(at: stateFile, withDestinationURL: target)
      XCTAssertThrowsError(try DeploymentStateStore(fileURL: stateFile).load())
    #endif
  }

  func testDeploymentLockIsExclusiveForAccountAcrossProjects() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let lockDirectory = directory.appendingPathComponent("locks")
    let accountID = String(repeating: "e", count: 32)
    let first = try DeploymentStateLock(
      accountID: accountID,
      lockDirectory: lockDirectory
    )
    XCTAssertThrowsError(
      try DeploymentStateLock(
        accountID: accountID,
        lockDirectory: lockDirectory
      )
    ) { error in
      XCTAssertEqual(error as? EdgeTunnelError, .deploymentInProgress)
    }
    let differentAccount = try DeploymentStateLock(
      accountID: String(repeating: "d", count: 32),
      lockDirectory: lockDirectory
    )
    differentAccount.release()
    first.release()
    let reacquired = try DeploymentStateLock(
      accountID: accountID,
      lockDirectory: lockDirectory
    )
    reacquired.release()
  }

  func testDeploymentLockTightensOwnedDirectoryPermissions() throws {
    #if os(Windows)
      throw XCTSkip("Windows 使用 ACL，不适用 POSIX 权限断言。")
    #else
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let lockDirectory = directory.appendingPathComponent("locks")
      try FileManager.default.createDirectory(
        at: lockDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: lockDirectory.path
      )

      let lock = try DeploymentStateLock(
        accountID: String(repeating: "f", count: 32),
        lockDirectory: lockDirectory
      )
      defer { lock.release() }

      let attributes = try FileManager.default.attributesOfItem(atPath: lockDirectory.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    #endif
  }
}

final class RecommendedDefaultsTests: XCTestCase {
  func testMergePreservesUnknownConfigAndAppendsRecommendedLinks() throws {
    let config = json([
      "未知字段": ["keep": true],
      "启用0RTT": false,
      "ECH": false,
      "订阅转换配置": [
        "SUBCONFIG": EdgeTunnelConstants.upstreamDefaultSubconfig,
        "other": "keep",
      ],
      "优选订阅生成": [
        "local": true,
        "本地IP库": ["随机IP": true, "随机数量": 16, "指定端口": -1],
        "SUB": NSNull(),
      ],
    ])
    let existing = Data(
      "  https://custom.example/list  \nhttps://bestcf.pages.dev/domain/all.txt\nhttps://bestcf.pages.dev/domain/all.txt\n"
        .utf8
    )

    let merged = try RecommendedDefaults.merge(
      config: config,
      preferredSubscriptions: existing
    )

    XCTAssertTrue(merged.configChanged)
    XCTAssertTrue(merged.preferredSubscriptionsChanged)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: merged.config) as? [String: Any]
    )
    XCTAssertEqual((object["未知字段"] as? [String: Bool])?["keep"], true)
    XCTAssertEqual(object["启用0RTT"] as? Bool, true)
    XCTAssertEqual(object["ECH"] as? Bool, true)
    let conversion = try XCTUnwrap(object["订阅转换配置"] as? [String: Any])
    XCTAssertEqual(conversion["SUBCONFIG"] as? String, EdgeTunnelConstants.recommendedSubconfig)
    XCTAssertEqual(conversion["other"] as? String, "keep")
    let preferred = try XCTUnwrap(object["优选订阅生成"] as? [String: Any])
    let localIPs = try XCTUnwrap(preferred["本地IP库"] as? [String: Any])
    XCTAssertEqual(localIPs["随机IP"] as? Bool, false)

    let add = try XCTUnwrap(String(data: merged.preferredSubscriptions, encoding: .utf8))
    XCTAssertTrue(add.hasPrefix("  https://custom.example/list  \n"))
    XCTAssertTrue(add.hasSuffix("\n"))
    for url in EdgeTunnelConstants.recommendedPreferredSubscriptions {
      XCTAssertEqual(add.components(separatedBy: url).count, 2)
    }
  }

  func testMergePreservesCustomConversionAndPreferredMode() throws {
    let config = json([
      "启用0RTT": true,
      "ECH": true,
      "订阅转换配置": ["SUBCONFIG": "https://custom.example/config.ini"],
      "优选订阅生成": [
        "local": true,
        "本地IP库": ["随机IP": true, "随机数量": 8, "指定端口": 8443],
        "SUB": NSNull(),
      ],
    ])

    let merged = try RecommendedDefaults.merge(config: config, preferredSubscriptions: nil)

    XCTAssertFalse(merged.configChanged)
    XCTAssertEqual(merged.config, config)
    let object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: merged.config) as? [String: Any]
    )
    let conversion = try XCTUnwrap(object["订阅转换配置"] as? [String: Any])
    XCTAssertEqual(conversion["SUBCONFIG"] as? String, "https://custom.example/config.ini")
    let preferred = try XCTUnwrap(object["优选订阅生成"] as? [String: Any])
    let localIPs = try XCTUnwrap(preferred["本地IP库"] as? [String: Any])
    XCTAssertEqual(localIPs["随机IP"] as? Bool, true)
    XCTAssertEqual(localIPs["随机数量"] as? Int, 8)
    XCTAssertEqual(localIPs["指定端口"] as? Int, 8443)
  }

  func testInitializerWritesConfigAddAndMarkerLast() async throws {
    let accountID = String(repeating: "3", count: 32)
    let config = json(["启用0RTT": false, "ECH": false, "extra": true])
    let transport = MockTransport { request in
      switch (request.method, request.url.path) {
      case ("GET", let path) where path.hasSuffix("/in.iiiam-defaults.json"):
        return HTTPResponse(statusCode: 404)
      case ("GET", let path) where path.hasSuffix("/config.json"):
        return HTTPResponse(statusCode: 200, body: config)
      case ("GET", let path) where path.hasSuffix("/ADD.txt"):
        return HTTPResponse(statusCode: 404)
      case ("PUT", let path) where path.contains("/values/"):
        return apiSuccess([String: String]())
      default:
        XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
        return HTTPResponse(statusCode: 500)
      }
    }
    let client = try CloudflareClient(token: "token", transport: transport)

    try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
      accountID: accountID,
      namespaceID: "namespace-id",
      upstreamCommit: "test-commit"
    )

    let requests = await transport.recordedRequests()
    let writes = requests.filter { $0.method == "PUT" }
    XCTAssertEqual(
      writes.map(\.url.path),
      [
        "/client/v4/accounts/\(accountID)/storage/kv/namespaces/namespace-id/values/config.json",
        "/client/v4/accounts/\(accountID)/storage/kv/namespaces/namespace-id/values/ADD.txt",
        "/client/v4/accounts/\(accountID)/storage/kv/namespaces/namespace-id/values/in.iiiam-defaults.json",
      ]
    )
    XCTAssertEqual(writes[0].headers["Content-Type"], "application/json")
    XCTAssertEqual(writes[1].headers["Content-Type"], "text/plain; charset=utf-8")
    XCTAssertEqual(writes[2].headers["Content-Type"], "application/json")
    let add = try XCTUnwrap(writes[1].body.flatMap { String(data: $0, encoding: .utf8) })
    for url in EdgeTunnelConstants.recommendedPreferredSubscriptions {
      XCTAssertTrue(add.contains(url))
    }
    let marker = try XCTUnwrap(
      writes[2].body.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      }
    )
    XCTAssertEqual(marker["version"] as? Int, 1)
    XCTAssertEqual(marker["upstreamCommit"] as? String, "test-commit")
  }

  func testInvalidMarkerFailsClosedWithoutWrites() async throws {
    let transport = MockTransport { request in
      if request.method == "GET", request.url.path.hasSuffix("/in.iiiam-defaults.json") {
        return HTTPResponse(statusCode: 200, body: json(["version": 0]))
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let client = try CloudflareClient(token: "token", transport: transport)
    do {
      try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
        accountID: String(repeating: "4", count: 32),
        namespaceID: "namespace-id",
        upstreamCommit: "test-commit"
      )
      XCTFail("Expected invalid marker failure")
    } catch let error as EdgeTunnelError {
      guard case .recommendedDefaults = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertFalse(requests.contains { $0.method == "PUT" })
  }

  func testBooleanMarkerVersionFailsClosedWithoutWrites() async throws {
    let transport = MockTransport { request in
      if request.method == "GET", request.url.path.hasSuffix("/in.iiiam-defaults.json") {
        return HTTPResponse(statusCode: 200, body: json(["version": true]))
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let client = try CloudflareClient(token: "token", transport: transport)

    do {
      try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
        accountID: String(repeating: "8", count: 32),
        namespaceID: "namespace-id",
        upstreamCommit: "test-commit"
      )
      XCTFail("Expected boolean marker version failure")
    } catch let error as EdgeTunnelError {
      guard case .recommendedDefaults = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertFalse(requests.contains { $0.method == "PUT" })
  }

  func testUnsupportedMarkerVersionFailsClosedWithoutWrites() async throws {
    let transport = MockTransport { request in
      if request.method == "GET", request.url.path.hasSuffix("/in.iiiam-defaults.json") {
        return HTTPResponse(statusCode: 200, body: json(["version": 2]))
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let client = try CloudflareClient(token: "token", transport: transport)

    do {
      try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
        accountID: String(repeating: "9", count: 32),
        namespaceID: "namespace-id",
        upstreamCommit: "test-commit"
      )
      XCTFail("Expected unsupported marker version failure")
    } catch let error as EdgeTunnelError {
      guard case .recommendedDefaults = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertFalse(requests.contains { $0.method == "PUT" })
  }

  func testNumericBooleanConfigValueIsRejected() throws {
    let config = json([
      "启用0RTT": true,
      "ECH": 1,
    ])

    XCTAssertThrowsError(
      try RecommendedDefaults.merge(config: config, preferredSubscriptions: nil)
    ) { error in
      guard let edgeError = error as? EdgeTunnelError,
        case .recommendedDefaults = edgeError
      else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testBooleanIntegerConfigValueIsRejected() throws {
    let config = json([
      "启用0RTT": true,
      "ECH": true,
      "优选订阅生成": [
        "local": true,
        "本地IP库": ["随机IP": true, "随机数量": true, "指定端口": -1],
        "SUB": NSNull(),
      ],
    ])

    XCTAssertThrowsError(
      try RecommendedDefaults.merge(config: config, preferredSubscriptions: nil)
    ) { error in
      guard let edgeError = error as? EdgeTunnelError,
        case .recommendedDefaults = edgeError
      else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testValidMarkerSkipsConfigurationReadsAndWrites() async throws {
    let transport = MockTransport { request in
      if request.method == "GET", request.url.path.hasSuffix("/in.iiiam-defaults.json") {
        return HTTPResponse(statusCode: 200, body: json(["version": 1]))
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let client = try CloudflareClient(token: "token", transport: transport)

    try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
      accountID: String(repeating: "5", count: 32),
      namespaceID: "namespace-id",
      upstreamCommit: "newer-commit"
    )

    let requests = await transport.recordedRequests()
    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(requests.allSatisfy { $0.method == "GET" })
  }

  func testInvalidUTF8AddFailsBeforeAnyWrite() async throws {
    let config = json(["启用0RTT": false, "ECH": false])
    let transport = MockTransport { request in
      switch (request.method, request.url.path) {
      case ("GET", let path) where path.hasSuffix("/in.iiiam-defaults.json"):
        return HTTPResponse(statusCode: 404)
      case ("GET", let path) where path.hasSuffix("/config.json"):
        return HTTPResponse(statusCode: 200, body: config)
      case ("GET", let path) where path.hasSuffix("/ADD.txt"):
        return HTTPResponse(statusCode: 200, body: Data([0xff]))
      default:
        XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
        return HTTPResponse(statusCode: 500)
      }
    }
    let client = try CloudflareClient(token: "token", transport: transport)
    do {
      try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
        accountID: String(repeating: "6", count: 32),
        namespaceID: "namespace-id",
        upstreamCommit: "test-commit"
      )
      XCTFail("Expected invalid UTF-8 failure")
    } catch let error as EdgeTunnelError {
      guard case .recommendedDefaults = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertFalse(requests.contains { $0.method == "PUT" })
  }

  func testFailedConfigWriteDoesNotWriteAddOrMarker() async throws {
    let config = json(["启用0RTT": false, "ECH": false])
    let transport = MockTransport { request in
      switch (request.method, request.url.path) {
      case ("GET", let path) where path.hasSuffix("/in.iiiam-defaults.json"):
        return HTTPResponse(statusCode: 404)
      case ("GET", let path) where path.hasSuffix("/config.json"):
        return HTTPResponse(statusCode: 200, body: config)
      case ("GET", let path) where path.hasSuffix("/ADD.txt"):
        return HTTPResponse(statusCode: 404)
      case ("PUT", let path) where path.hasSuffix("/config.json"):
        return HTTPResponse(statusCode: 200, body: Data("not-json".utf8))
      default:
        XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
        return HTTPResponse(statusCode: 500)
      }
    }
    let client = try CloudflareClient(token: "token", transport: transport)
    do {
      try await RecommendedDefaultsInitializer(cloudflare: client, sleep: { _ in }).ensure(
        accountID: String(repeating: "7", count: 32),
        namespaceID: "namespace-id",
        upstreamCommit: "test-commit"
      )
      XCTFail("Expected malformed Cloudflare response failure")
    } catch let error as EdgeTunnelError {
      guard case .invalidResponse = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertEqual(
      requests.filter { $0.method == "PUT" }.map(\.url.lastPathComponent), ["config.json"])
  }
}

final class CloudflareAndDeploymentTests: XCTestCase {
  func testCloudflareErrorRedactsToken() async throws {
    let token = "super-secret-token"
    let body = json([
      "success": false,
      "errors": [["code": 10_000, "message": "denied \(token)"]],
    ])
    let transport = MockTransport { _ in
      HTTPResponse(statusCode: 403, body: body)
    }
    let client = try CloudflareClient(token: token, transport: transport)
    do {
      _ = try await client.listKVNamespaces(accountID: String(repeating: "a", count: 32))
      XCTFail("Expected API failure")
    } catch {
      XCTAssertFalse(error.localizedDescription.contains(token))
      XCTAssertTrue(error.localizedDescription.contains("<redacted>"))
    }
  }

  func testFullCreateDeploymentPathAndMultipart() async throws {
    let token = "super-secret-token"
    let accountID = String(repeating: "a", count: 32)
    let projectName = "in-iiiam-\(accountID)"
    let hostname = "\(projectName).pages.dev"
    let worker = Data("export default { fetch() { return new Response('ok') } }".utf8)
    let upstream = UpstreamDescriptor(
      commit: "test-commit",
      url: URL(string: "https://source.invalid/_worker.js")!,
      sha256: Digest.sha256Hex(worker),
      maximumSize: 1024
    )
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    var projectReadCount = 0

    let transport = MockTransport { request in
      let path = request.url.path
      switch (request.method, request.url.host, path) {
      case ("GET", "api.cloudflare.com", let value) where value.hasSuffix("/tokens/verify"):
        return apiSuccess(["status": "active"])
      case ("GET", "api.cloudflare.com", let value) where value.hasSuffix("/storage/kv/namespaces"):
        return apiSuccess([], resultInfo: ["total_pages": 1])
      case ("GET", "api.cloudflare.com", let value)
      where value.hasSuffix("/pages/projects/\(projectName)"):
        projectReadCount += 1
        if projectReadCount == 1 {
          return HTTPResponse(statusCode: 404, body: json(["success": false, "errors": []]))
        }
        return apiSuccess([
          "id": "project-id",
          "name": projectName,
          "subdomain": hostname,
          "canonical_deployment": ["id": "deployment-id"],
        ])
      case ("GET", "source.invalid", "/_worker.js"):
        return HTTPResponse(statusCode: 200, body: worker)
      case ("POST", "api.cloudflare.com", let value) where value.hasSuffix("/storage/kv/namespaces"):
        return apiSuccess(["id": "namespace-id", "title": "in.iiiam-edgetunnel"])
      case ("POST", "api.cloudflare.com", let value) where value.hasSuffix("/pages/projects"):
        return apiSuccess(["id": "project-id", "name": projectName, "subdomain": hostname])
      case ("PATCH", "api.cloudflare.com", let value)
      where value.hasSuffix("/pages/projects/\(projectName)"):
        return apiSuccess(["id": "project-id", "name": projectName, "subdomain": hostname])
      case ("POST", "api.cloudflare.com", let value)
      where value.hasSuffix("/pages/projects/\(projectName)/deployments"):
        return apiSuccess(["id": "deployment-id"])
      case ("GET", "api.cloudflare.com", let value)
      where value.hasSuffix("/pages/projects/\(projectName)/deployments/deployment-id"):
        return apiSuccess(["id": "deployment-id", "latest_stage": ["status": "success"]])
      case ("GET", "api.cloudflare.com", let value)
      where value.hasSuffix("/values/in.iiiam-defaults.json"):
        return HTTPResponse(statusCode: 404)
      case ("GET", "api.cloudflare.com", let value) where value.hasSuffix("/values/config.json"):
        return HTTPResponse(
          statusCode: 200,
          body: json(["启用0RTT": false, "ECH": false, "extra": true])
        )
      case ("GET", "api.cloudflare.com", let value) where value.hasSuffix("/values/ADD.txt"):
        return HTTPResponse(statusCode: 404)
      case ("PUT", "api.cloudflare.com", let value) where value.contains("/values/"):
        return apiSuccess([String: String]())
      case ("GET", hostname, "/sub"):
        let saved = try! XCTUnwrap(try DeploymentStateStore(fileURL: stateFile).load())
        return HTTPResponse(statusCode: 200, body: validSubscriptionData(uuid: saved.uuid))
      default:
        XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
        return HTTPResponse(statusCode: 500, body: Data())
      }
    }

    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    let result = try await DeploymentService(
      transport: transport,
      upstream: upstream,
      verifierSleep: { _ in }
    ).deploy(token: token, options: options)

    XCTAssertEqual(result.projectName, projectName)
    XCTAssertEqual(result.pagesProjectID, "project-id")
    XCTAssertEqual(result.accountID, accountID)
    XCTAssertEqual(result.hostname, hostname)
    XCTAssertEqual(result.kvNamespaceID, "namespace-id")
    XCTAssertEqual(result.deploymentID, "deployment-id")
    XCTAssertEqual(result.upstreamCommit, "test-commit")
    XCTAssertFalse(result.reused)
    XCTAssertTrue(result.recommendedDefaultsReady)

    let requests = await transport.recordedRequests()
    let cloudflareRequests = requests.filter { $0.url.host == "api.cloudflare.com" }
    XCTAssertTrue(
      cloudflareRequests.allSatisfy {
        $0.headers["Authorization"] == "Bearer \(token)"
      })
    let patch = try XCTUnwrap(requests.first { $0.method == "PATCH" })
    let patchText = try XCTUnwrap(patch.body.flatMap { String(data: $0, encoding: .utf8) })
    XCTAssertTrue(patchText.contains("secret_text"))
    XCTAssertTrue(patchText.contains("namespace-id"))
    XCTAssertTrue(patchText.contains(result.adminPassword))
    XCTAssertTrue(patchText.contains(result.uuid))

    let upload = try XCTUnwrap(
      requests.first {
        $0.method == "POST" && $0.url.path.hasSuffix("/deployments")
      })
    XCTAssertTrue(
      upload.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
    let uploadText = try XCTUnwrap(upload.body.flatMap { String(data: $0, encoding: .utf8) })
    XCTAssertTrue(uploadText.contains("name=\"manifest\""))
    XCTAssertFalse(uploadText.contains("name=\"branch\""))
    XCTAssertTrue(uploadText.contains("name=\"_worker.js\""))
    XCTAssertTrue(uploadText.contains("application/javascript+module"))
    XCTAssertTrue(uploadText.contains("test-commit"))

    let defaultsWrites = requests.filter {
      $0.method == "PUT" && $0.url.path.contains("/values/")
    }
    XCTAssertEqual(
      defaultsWrites.map(\.url.lastPathComponent),
      ["config.json", "ADD.txt", "in.iiiam-defaults.json"]
    )
    XCTAssertEqual(
      requests.filter { $0.method == "GET" && $0.url.host == hostname && $0.url.path == "/sub" }
        .count,
      2
    )
    let firstSubscriptionIndex = try XCTUnwrap(
      requests.firstIndex { $0.method == "GET" && $0.url.host == hostname && $0.url.path == "/sub" }
    )
    let defaultsWriteIndex = try XCTUnwrap(
      requests.firstIndex { $0.method == "PUT" && $0.url.path.contains("/values/") }
    )
    let finalSubscriptionIndex = try XCTUnwrap(
      requests.lastIndex { $0.method == "GET" && $0.url.host == hostname && $0.url.path == "/sub" }
    )
    XCTAssertLessThan(firstSubscriptionIndex, defaultsWriteIndex)
    XCTAssertLessThan(defaultsWriteIndex, finalSubscriptionIndex)

    let stateContents = try String(contentsOf: stateFile, encoding: .utf8)
    XCTAssertFalse(stateContents.contains(token))
    XCTAssertTrue(stateContents.contains("\"deploymentComplete\" : true"))
    XCTAssertTrue(stateContents.contains("\"kvNamespaceCreationPending\" : false"))
    XCTAssertTrue(stateContents.contains("\"pagesProjectCreationPending\" : false"))
  }

  func testCompleteCanonicalDeploymentIsReusedWithoutUpload() async throws {
    let token = "token"
    let accountID = String(repeating: "b", count: 32)
    let projectName = "llet-\(accountID)"
    let kvNamespaceTitle = "legacy-edgetunnel"
    let hostname = "\(projectName).pages.dev"
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    var state = DeploymentState(
      accountID: accountID,
      projectName: projectName,
      pagesProjectID: "project-id",
      kvNamespaceID: "namespace-id",
      kvNamespaceTitle: kvNamespaceTitle,
      hostname: hostname,
      deploymentID: "deployment-id",
      deploymentComplete: true
    )
    state.upstreamCommit = EdgeTunnelConstants.upstreamCommit
    try DeploymentStateStore(fileURL: stateFile).save(state)

    let transport = MockTransport { request in
      let path = request.url.path
      if path.hasSuffix("/tokens/verify") {
        return apiSuccess(["status": "active"])
      }
      if path.hasSuffix("/storage/kv/namespaces") {
        return apiSuccess(
          [["id": "namespace-id", "title": kvNamespaceTitle]],
          resultInfo: ["total_pages": 1]
        )
      }
      if path.hasSuffix("/pages/projects/\(projectName)") {
        return apiSuccess([
          "id": "project-id",
          "name": projectName,
          "subdomain": hostname,
          "canonical_deployment": ["id": "deployment-id"],
        ])
      }
      if request.method == "GET", path.hasSuffix("/values/in.iiiam-defaults.json") {
        return HTTPResponse(statusCode: 200, body: json(["version": 1]))
      }
      if request.url.host == hostname, path == "/sub" {
        return HTTPResponse(statusCode: 200, body: validSubscriptionData(uuid: state.uuid))
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    let result = try await DeploymentService(
      transport: transport,
      verifierSleep: { _ in }
    ).deploy(token: token, options: options)

    XCTAssertTrue(result.reused)
    XCTAssertEqual(result.kvNamespaceTitle, kvNamespaceTitle)
    let requests = await transport.recordedRequests()
    XCTAssertFalse(
      requests.contains { $0.method == "PATCH" || $0.url.path.hasSuffix("/deployments") })
    XCTAssertFalse(requests.contains { $0.url.host == "raw.githubusercontent.com" })
    XCTAssertFalse(requests.contains { $0.method == "PUT" })
    XCTAssertEqual(
      requests.filter { $0.method == "GET" && $0.url.host == hostname && $0.url.path == "/sub" }
        .count,
      2
    )
  }

  func testExistingResourcesRequireExplicitAdoptionWithoutState() async throws {
    let accountID = String(repeating: "c", count: 32)
    let projectName = "in-iiiam-\(accountID)"
    let hostname = "\(projectName).pages.dev"
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    let transport = MockTransport { request in
      if request.url.path.hasSuffix("/tokens/verify") {
        return apiSuccess(["status": "active"])
      }
      if request.url.path.hasSuffix("/storage/kv/namespaces") {
        return apiSuccess(
          [["id": "existing-namespace", "title": "in.iiiam-edgetunnel"]],
          resultInfo: ["total_pages": 1]
        )
      }
      if request.url.path.hasSuffix("/pages/projects/\(projectName)") {
        return apiSuccess([
          "id": "existing-project-id",
          "name": projectName,
          "subdomain": hostname,
        ])
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    do {
      _ = try await DeploymentService(transport: transport).deploy(token: "token", options: options)
      XCTFail("Expected adoption refusal")
    } catch let error as EdgeTunnelError {
      guard case .stateConflict = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: stateFile.path))
    let requests = await transport.recordedRequests()
    XCTAssertFalse(requests.contains { ["POST", "PATCH", "PUT", "DELETE"].contains($0.method) })
  }

  func testFailedNewDeploymentCannotBeMaskedByOldSite() async throws {
    let accountID = String(repeating: "d", count: 32)
    let projectName = "llet-\(accountID)"
    let hostname = "\(projectName).pages.dev"
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    let state = DeploymentState(
      accountID: accountID,
      projectName: projectName,
      pagesProjectID: "project-id",
      kvNamespaceID: "namespace-id",
      kvNamespaceTitle: "in.iiiam-edgetunnel",
      hostname: hostname
    )
    try DeploymentStateStore(fileURL: stateFile).save(state)
    let worker = Data("worker".utf8)
    let upstream = UpstreamDescriptor(
      commit: "test-commit",
      url: URL(string: "https://source.invalid/_worker.js")!,
      sha256: Digest.sha256Hex(worker),
      maximumSize: 1024
    )
    let transport = MockTransport { request in
      let path = request.url.path
      if path.hasSuffix("/tokens/verify") {
        return apiSuccess(["status": "active"])
      }
      if path.hasSuffix("/storage/kv/namespaces") {
        return apiSuccess(
          [["id": "namespace-id", "title": "in.iiiam-edgetunnel"]],
          resultInfo: ["total_pages": 1]
        )
      }
      if request.method == "GET", path.hasSuffix("/pages/projects/\(projectName)") {
        return apiSuccess([
          "id": "project-id",
          "name": projectName,
          "subdomain": hostname,
          "canonical_deployment": ["id": "old-deployment"],
        ])
      }
      if request.url.host == "source.invalid" {
        return HTTPResponse(statusCode: 200, body: worker)
      }
      if request.method == "PATCH", path.hasSuffix("/pages/projects/\(projectName)") {
        return apiSuccess(["id": "project-id", "name": projectName, "subdomain": hostname])
      }
      if request.method == "POST", path.hasSuffix("/deployments") {
        return apiSuccess(["id": "new-deployment"])
      }
      if request.method == "GET", path.hasSuffix("/deployments/new-deployment") {
        return apiSuccess([
          "id": "new-deployment",
          "latest_stage": ["status": "failure"],
        ])
      }
      if request.url.host == hostname {
        XCTFail("Old subscription must not be used before the new deployment succeeds")
        return HTTPResponse(statusCode: 200, body: validSubscriptionData(uuid: state.uuid))
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }
    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    do {
      _ = try await DeploymentService(
        transport: transport,
        upstream: upstream,
        verifierSleep: { _ in }
      ).deploy(token: "token", options: options)
      XCTFail("Expected deployment failure")
    } catch let error as EdgeTunnelError {
      XCTAssertEqual(error, .pagesDeploymentFailed(status: "failure"))
    }
    let saved = try XCTUnwrap(try DeploymentStateStore(fileURL: stateFile).load())
    XCTAssertFalse(saved.deploymentComplete)
    XCTAssertEqual(saved.deploymentID, "new-deployment")
  }

  func testStaleKVIdentityStopsBeforeRemoteWrites() async throws {
    let accountID = String(repeating: "f", count: 32)
    let projectName = "llet-\(accountID)"
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    let state = DeploymentState(
      accountID: accountID,
      projectName: projectName,
      pagesProjectID: "project-id",
      kvNamespaceID: "deleted-namespace-id",
      kvNamespaceTitle: "in.iiiam-edgetunnel"
    )
    try DeploymentStateStore(fileURL: stateFile).save(state)
    let transport = MockTransport { request in
      if request.url.path.hasSuffix("/tokens/verify") {
        return apiSuccess(["status": "active"])
      }
      if request.url.path.hasSuffix("/storage/kv/namespaces") {
        return apiSuccess(
          [["id": "replacement-namespace-id", "title": "in.iiiam-edgetunnel"]],
          resultInfo: ["total_pages": 1]
        )
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }

    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    do {
      _ = try await DeploymentService(transport: transport).deploy(
        token: "token",
        options: options
      )
      XCTFail("Expected stale KV identity refusal")
    } catch let error as EdgeTunnelError {
      guard case .stateConflict = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertFalse(requests.contains { ["POST", "PATCH", "PUT", "DELETE"].contains($0.method) })
  }

  func testStalePagesIdentityStopsBeforeRemoteWrites() async throws {
    let accountID = String(repeating: "1", count: 32)
    let projectName = "llet-\(accountID)"
    let hostname = "\(projectName).pages.dev"
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    let state = DeploymentState(
      accountID: accountID,
      projectName: projectName,
      pagesProjectID: "deleted-project-id",
      kvNamespaceID: "namespace-id",
      kvNamespaceTitle: "in.iiiam-edgetunnel"
    )
    try DeploymentStateStore(fileURL: stateFile).save(state)
    let transport = MockTransport { request in
      if request.url.path.hasSuffix("/tokens/verify") {
        return apiSuccess(["status": "active"])
      }
      if request.url.path.hasSuffix("/storage/kv/namespaces") {
        return apiSuccess(
          [["id": "namespace-id", "title": "in.iiiam-edgetunnel"]],
          resultInfo: ["total_pages": 1]
        )
      }
      if request.url.path.hasSuffix("/pages/projects/\(projectName)") {
        return apiSuccess([
          "id": "replacement-project-id",
          "name": projectName,
          "subdomain": hostname,
        ])
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }

    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    do {
      _ = try await DeploymentService(transport: transport).deploy(
        token: "token",
        options: options
      )
      XCTFail("Expected stale Pages identity refusal")
    } catch let error as EdgeTunnelError {
      guard case .stateConflict = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    let requests = await transport.recordedRequests()
    XCTAssertFalse(requests.contains { ["POST", "PATCH", "PUT", "DELETE"].contains($0.method) })
  }

  func testCreationIntentRecoversRemoteIDsWithoutAdopt() async throws {
    let accountID = String(repeating: "2", count: 32)
    let projectName = "llet-\(accountID)"
    let hostname = "\(projectName).pages.dev"
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stateFile = directory.appendingPathComponent("state.json")
    let state = DeploymentState(
      accountID: accountID,
      projectName: projectName,
      pagesProjectCreationPending: true,
      kvNamespaceCreationPending: true,
      kvNamespaceTitle: "in.iiiam-edgetunnel"
    )
    try DeploymentStateStore(fileURL: stateFile).save(state)
    let transport = MockTransport { request in
      if request.url.path.hasSuffix("/tokens/verify") {
        return apiSuccess(["status": "active"])
      }
      if request.url.path.hasSuffix("/storage/kv/namespaces") {
        return apiSuccess(
          [["id": "recovered-namespace-id", "title": "in.iiiam-edgetunnel"]],
          resultInfo: ["total_pages": 1]
        )
      }
      if request.url.path.hasSuffix("/pages/projects/\(projectName)") {
        return apiSuccess([
          "id": "recovered-project-id",
          "name": projectName,
          "subdomain": hostname,
        ])
      }
      if request.url.host == "raw.githubusercontent.com" {
        return HTTPResponse(statusCode: 503)
      }
      XCTFail("Unexpected request: \(request.method) \(request.url.absoluteString)")
      return HTTPResponse(statusCode: 500)
    }

    let options = try DeploymentOptions(accountID: accountID, stateFile: stateFile)
    do {
      _ = try await DeploymentService(transport: transport).deploy(
        token: "token",
        options: options
      )
      XCTFail("Expected the intentional upstream failure")
    } catch let error as EdgeTunnelError {
      XCTAssertEqual(error, .upstreamDownloadStatus(503))
    }
    let recovered = try XCTUnwrap(try DeploymentStateStore(fileURL: stateFile).load())
    XCTAssertEqual(recovered.kvNamespaceID, "recovered-namespace-id")
    XCTAssertEqual(recovered.pagesProjectID, "recovered-project-id")
    XCTAssertEqual(recovered.kvNamespaceCreationPending, false)
    XCTAssertEqual(recovered.pagesProjectCreationPending, false)
    let requests = await transport.recordedRequests()
    XCTAssertFalse(requests.contains { ["POST", "PATCH", "PUT", "DELETE"].contains($0.method) })
  }
}

private actor MockTransport: HTTPTransport {
  private let responder: (HTTPRequest) throws -> HTTPResponse
  private var requests: [HTTPRequest] = []

  init(responder: @escaping (HTTPRequest) throws -> HTTPResponse) {
    self.responder = responder
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    return try responder(request)
  }

  func recordedRequests() -> [HTTPRequest] {
    requests
  }
}

private func temporaryDirectory() -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("edgetunnel-tests-\(UUID().uuidString)", isDirectory: true)
  try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func json(_ object: Any) -> Data {
  try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func apiSuccess(_ result: Any, resultInfo: [String: Any]? = nil) -> HTTPResponse {
  var payload: [String: Any] = [
    "success": true,
    "errors": [],
    "messages": [],
    "result": result,
  ]
  if let resultInfo {
    payload["result_info"] = resultInfo
  }
  return HTTPResponse(statusCode: 200, body: json(payload))
}

private func validSubscriptionData(uuid: String) -> Data {
  let link =
    "vless://\(uuid)@edge.example.com:443?encryption=none&security=tls&type=ws&sni=tls.example.com&host=ws.example.com"
  return Data(link.utf8).base64EncodedData()
}
