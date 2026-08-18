import Foundation

public struct CloudflareAPIProblem: Codable, Equatable {
  public let code: Int?
  public let message: String

  public init(code: Int?, message: String) {
    self.code = code
    self.message = message
  }
}

public enum EdgeTunnelError: Error, Equatable {
  case usage(String)
  case invalidAccountID
  case invalidProjectName(String)
  case invalidKVTitle
  case state(String)
  case stateConflict(String)
  case transport(code: Int)
  case responseTooLarge(limit: Int)
  case invalidResponse(status: Int?)
  case cloudflareAPI(status: Int, problems: [CloudflareAPIProblem])
  case tokenInactive
  case upstreamDownloadStatus(Int)
  case workerTooLarge(limit: Int)
  case workerIntegrity(expected: String, actual: String)
  case deploymentInProgress
  case pagesDeploymentFailed(status: String)
  case pagesDeploymentTimedOut(attempts: Int)
  case subscriptionVerificationFailed(attempts: Int)
  case recommendedDefaults(String)
}

extension EdgeTunnelError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .usage(let message):
      return message
    case .invalidAccountID:
      return "Account ID 必须是 32 位十六进制字符串。"
    case .invalidProjectName(let name):
      return "Pages 项目名无效：\(name)。只能使用 1–58 位小写字母、数字和连字符，且不能以连字符开头或结尾。"
    case .invalidKVTitle:
      return "KV 命名空间标题不能为空、不能包含控制字符，且最长为 128 个 UTF-8 字节。"
    case .state(let message):
      return "状态文件错误：\(message)"
    case .stateConflict(let message):
      return "状态文件冲突：\(message)"
    case .transport(let code):
      return "网络请求失败（URL 错误代码 \(code)）。"
    case .responseTooLarge(let limit):
      return "服务器响应超过 \(limit) 字节上限。"
    case .invalidResponse(let status):
      if let status {
        return "服务器返回了无法解析的响应（HTTP \(status)）。"
      }
      return "服务器返回了无法解析的响应。"
    case .cloudflareAPI(let status, let problems):
      let details = problems.map { problem in
        if let code = problem.code {
          return "[\(code)] \(problem.message)"
        }
        return problem.message
      }.joined(separator: "; ")
      return details.isEmpty
        ? "Cloudflare API 请求失败（HTTP \(status)）。"
        : "Cloudflare API 请求失败（HTTP \(status)）：\(details)"
    case .tokenInactive:
      return "Cloudflare API Token 未处于 active 状态。"
    case .upstreamDownloadStatus(let status):
      return "下载固定上游失败（HTTP \(status)）。"
    case .workerTooLarge(let limit):
      return "_worker.js 超过 \(limit) 字节上限。"
    case .workerIntegrity(let expected, let actual):
      return "_worker.js 完整性校验失败；期望 SHA-256 \(expected)，实际为 \(actual)。"
    case .deploymentInProgress:
      return "另一个进程正在部署同一 Cloudflare Account，请等待它完成后重试。"
    case .pagesDeploymentFailed(let status):
      return "Cloudflare Pages deployment 未成功（状态：\(status)）。"
    case .pagesDeploymentTimedOut(let attempts):
      return "已创建 Pages deployment，但在 \(attempts) 次检查后仍未成为成功的 canonical deployment。"
    case .subscriptionVerificationFailed(let attempts):
      return "部署已提交，但在 \(attempts) 次尝试后仍未取得包含有效 VLESS URL 的 Base64 订阅。"
    case .recommendedDefaults(let message):
      return "初始化推荐节点地址失败：\(message)"
    }
  }
}

enum SensitiveDataRedactor {
  static func redact(_ input: String, secrets: [String]) -> String {
    secrets
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
      .reduce(input) { partial, secret in
        partial.replacingOccurrences(of: secret, with: "<redacted>")
      }
  }
}
