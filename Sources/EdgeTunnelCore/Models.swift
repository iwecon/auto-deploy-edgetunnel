import Foundation

public struct DeploymentOptions: Equatable {
  public let accountID: String
  public let projectName: String
  public let kvNamespaceTitle: String
  public let stateFile: URL
  public let workerFile: URL?
  public let adoptExisting: Bool
  let usesDefaultProjectName: Bool
  let usesDefaultKVNamespaceTitle: Bool

  public init(
    accountID: String,
    projectName: String? = nil,
    kvNamespaceTitle: String? = nil,
    stateFile: URL,
    workerFile: URL? = nil,
    adoptExisting: Bool = false
  ) throws {
    let accountID = try InputValidator.accountID(accountID)
    self.accountID = accountID
    self.usesDefaultProjectName = projectName == nil
    self.projectName = try InputValidator.projectName(
      projectName ?? EdgeTunnelConstants.defaultProjectName(accountID: accountID)
    )
    self.usesDefaultKVNamespaceTitle = kvNamespaceTitle == nil
    self.kvNamespaceTitle = try InputValidator.kvTitle(
      kvNamespaceTitle ?? EdgeTunnelConstants.defaultKVTitle
    )
    self.stateFile = stateFile.standardizedFileURL
    self.workerFile = workerFile?.standardizedFileURL
    self.adoptExisting = adoptExisting
  }
}

public struct DeploymentState: Codable, Equatable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var accountID: String
  public var projectName: String
  public var pagesProjectID: String?
  public var pagesProjectCreationPending: Bool?
  public var kvNamespaceID: String?
  public var kvNamespaceCreationPending: Bool?
  public var kvNamespaceTitle: String
  public var hostname: String?
  public var uuid: String
  public var adminPassword: String
  public var deploymentID: String?
  public var deploymentComplete: Bool
  public var upstreamCommit: String

  public init(
    accountID: String,
    projectName: String,
    pagesProjectID: String? = nil,
    pagesProjectCreationPending: Bool? = false,
    kvNamespaceID: String? = nil,
    kvNamespaceCreationPending: Bool? = false,
    kvNamespaceTitle: String,
    hostname: String? = nil,
    uuid: String = UUID().uuidString.lowercased(),
    adminPassword: String = SecureRandom.adminPassword(),
    deploymentID: String? = nil,
    deploymentComplete: Bool = false,
    upstreamCommit: String = EdgeTunnelConstants.upstreamCommit
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.accountID = accountID
    self.projectName = projectName
    self.pagesProjectID = pagesProjectID
    self.pagesProjectCreationPending = pagesProjectCreationPending
    self.kvNamespaceID = kvNamespaceID
    self.kvNamespaceCreationPending = kvNamespaceCreationPending
    self.kvNamespaceTitle = kvNamespaceTitle
    self.hostname = hostname
    self.uuid = uuid
    self.adminPassword = adminPassword
    self.deploymentID = deploymentID
    self.deploymentComplete = deploymentComplete
    self.upstreamCommit = upstreamCommit
  }

  public func validate(for options: DeploymentOptions) throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw EdgeTunnelError.state("不支持的 schemaVersion \(schemaVersion)。")
    }
    guard accountID == options.accountID else {
      throw EdgeTunnelError.stateConflict("Account ID 与当前输入不一致。")
    }
    guard projectName == options.projectName else {
      throw EdgeTunnelError.stateConflict("Pages 项目名与当前输入不一致。")
    }
    guard kvNamespaceTitle == options.kvNamespaceTitle else {
      throw EdgeTunnelError.stateConflict("KV 命名空间标题与当前输入不一致。")
    }
    if let pagesProjectID, pagesProjectID.isEmpty {
      throw EdgeTunnelError.state("Pages 项目 ID 为空。")
    }
    if let kvNamespaceID, kvNamespaceID.isEmpty {
      throw EdgeTunnelError.state("KV 命名空间 ID 为空。")
    }
    guard Self.isUUIDv4(uuid) else {
      throw EdgeTunnelError.state("UUID 不是 RFC 4122 v4 格式。")
    }
    guard adminPassword.count >= 32 else {
      throw EdgeTunnelError.state("管理密码长度不足。")
    }
  }

  private static func isUUIDv4(_ value: String) -> Bool {
    let parts = value.lowercased().split(separator: "-", omittingEmptySubsequences: false)
    guard parts.map(\.count) == [8, 4, 4, 4, 12],
      parts.joined().utf8.allSatisfy({ byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }),
      parts[2].first == "4",
      let variant = parts[3].first,
      "89ab".contains(variant)
    else {
      return false
    }
    return true
  }
}

public struct DeploymentResult: Codable, Equatable {
  public let accountID: String
  public let projectName: String
  public let pagesProjectID: String
  public let hostname: String
  public let siteURL: String
  public let adminURL: String
  public let subscriptionURL: String
  public let uuid: String
  public let adminPassword: String
  public let kvNamespaceID: String
  public let kvNamespaceTitle: String
  public let deploymentID: String
  public let upstreamCommit: String
  public let stateFile: String
  public let reused: Bool
  public let recommendedDefaultsReady: Bool

  public init(state: DeploymentState, stateFile: URL, reused: Bool) throws {
    guard let pagesProjectID = state.pagesProjectID,
      let hostname = state.hostname,
      let kvNamespaceID = state.kvNamespaceID,
      let deploymentID = state.deploymentID
    else {
      throw EdgeTunnelError.state("部署结果缺少 Cloudflare 资源标识。")
    }
    let subscriptionURL = try Subscription.makeURL(hostname: hostname, uuid: state.uuid)
      .absoluteString
    self.accountID = state.accountID
    self.projectName = state.projectName
    self.pagesProjectID = pagesProjectID
    self.hostname = hostname
    self.siteURL = "https://\(hostname)/"
    self.adminURL = "https://\(hostname)/admin"
    self.subscriptionURL = subscriptionURL
    self.uuid = state.uuid
    self.adminPassword = state.adminPassword
    self.kvNamespaceID = kvNamespaceID
    self.kvNamespaceTitle = state.kvNamespaceTitle
    self.deploymentID = deploymentID
    self.upstreamCommit = state.upstreamCommit
    self.stateFile = stateFile.path
    self.reused = reused
    self.recommendedDefaultsReady = true
  }
}

public enum SecureRandom {
  public static func adminPassword() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }
}

struct KVNamespace: Equatable {
  let id: String
  let title: String
}

struct PagesProject: Equatable {
  let id: String
  let name: String
  let subdomain: String
  let canonicalDeploymentID: String?
}

enum PagesDeploymentStage: Equatable {
  case pending(String)
  case success
  case failed(String)
}
