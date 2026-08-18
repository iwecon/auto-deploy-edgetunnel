import EdgeTunnelCore
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

@main
struct EdgeTunnelCommand {
  static func main() async {
    do {
      let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
      if arguments.help {
        print(Arguments.helpText)
        return
      }

      let environment = ProcessInfo.processInfo.environment
      let accountID = try resolveAccountID(arguments: arguments, environment: environment)
      let apiToken = try resolveAPIToken(arguments: arguments, environment: environment)
      let currentDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
      )
      let stateFile = resolveFile(
        arguments.stateFile ?? EdgeTunnelConstants.defaultStateFile,
        relativeTo: currentDirectory
      )
      let workerFile = arguments.workerFile.map {
        resolveFile($0, relativeTo: currentDirectory)
      }
      let options = try DeploymentOptions(
        accountID: accountID,
        projectName: arguments.projectName,
        kvNamespaceTitle: arguments.kvTitle,
        stateFile: stateFile,
        workerFile: workerFile,
        adoptExisting: arguments.adoptExisting
      )

      writeError("正在验证凭据并部署 EdgeTunnel…\n")
      let result = try await DeploymentService(transport: URLSessionTransport())
        .deploy(token: apiToken, options: options)
      if arguments.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        guard let json = String(data: data, encoding: .utf8) else {
          throw EdgeTunnelError.invalidResponse(status: nil)
        }
        print(json)
      } else {
        printHumanResult(result)
      }
    } catch let error as EdgeTunnelError {
      writeError("部署失败：\(error.localizedDescription)\n")
      exit(1)
    } catch {
      writeError("部署失败：发生未预期错误；未输出底层内容以避免泄露凭据。\n")
      exit(1)
    }
  }

  private static func resolveAccountID(
    arguments: Arguments,
    environment: [String: String]
  ) throws -> String {
    if let value = arguments.accountID?.trimmedNonempty {
      return value
    }
    if let value = environment["CLOUDFLARE_ACCOUNT_ID"]?.trimmedNonempty {
      return value
    }
    guard isatty(STDIN_FILENO) == 1 else {
      throw EdgeTunnelError.usage(
        "非交互模式必须通过 --account-id 或 CLOUDFLARE_ACCOUNT_ID 提供 Account ID。"
      )
    }
    writeError("Cloudflare Account ID: ")
    guard let value = readLine()?.trimmedNonempty else {
      throw EdgeTunnelError.usage("Cloudflare Account ID 不能为空。")
    }
    return value
  }

  private static func resolveAPIToken(
    arguments: Arguments,
    environment: [String: String]
  ) throws -> String {
    if arguments.apiTokenStdin {
      guard let value = readLine()?.trimmedNonempty else {
        throw EdgeTunnelError.usage("标准输入中没有 API Token。")
      }
      return value
    }
    if let value = environment["CLOUDFLARE_API_TOKEN"]?.trimmedNonempty {
      return value
    }
    return try readHiddenLine(prompt: "Cloudflare API Token: ")
  }

  private static func readHiddenLine(prompt: String) throws -> String {
    guard isatty(STDIN_FILENO) == 1 else {
      throw EdgeTunnelError.usage(
        "非交互模式必须设置 CLOUDFLARE_API_TOKEN 或使用 --api-token-stdin。"
      )
    }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw EdgeTunnelError.usage("无法读取终端属性，Token 输入已取消。")
    }
    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    writeError(prompt)
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else {
      throw EdgeTunnelError.usage("无法关闭终端回显，Token 输入已取消。")
    }
    defer {
      _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      writeError("\n")
    }
    guard let value = readLine()?.trimmedNonempty else {
      throw EdgeTunnelError.usage("Cloudflare API Token 不能为空。")
    }
    return value
  }

  private static func resolveFile(_ path: String, relativeTo directory: URL) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    return directory.appendingPathComponent(path).standardizedFileURL
  }

  private static func printHumanResult(_ result: DeploymentResult) {
    print(
      """

      EdgeTunnel 部署成功\(result.reused ? "（已复用现有部署）" : "")

      Account ID:       \(result.accountID)
      Pages 项目:       \(result.projectName)
      Pages 项目 ID:    \(result.pagesProjectID)
      主机名:           \(result.hostname)
      站点:             \(result.siteURL)
      管理后台:         \(result.adminURL)
      订阅地址 [敏感]:  \(result.subscriptionURL)
      UUID [敏感]:      \(result.uuid)
      管理密码 [敏感]:  \(result.adminPassword)
      KV 标题:          \(result.kvNamespaceTitle)
      KV ID:            \(result.kvNamespaceID)
      Deployment ID:    \(result.deploymentID)
      推荐节点地址:     已初始化或确认
      上游提交:         \(result.upstreamCommit)
      状态文件 [0600]:  \(result.stateFile)

      请妥善保管订阅地址、UUID、管理密码和状态文件。API Token 未保存。
      """)
  }

  private static func writeError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }
}

private struct Arguments {
  var accountID: String?
  var apiTokenStdin = false
  var stateFile: String?
  var workerFile: String?
  var projectName: String?
  var kvTitle: String?
  var adoptExisting = false
  var json = false
  var help = false

  static func parse(_ rawArguments: [String]) throws -> Arguments {
    var arguments = rawArguments
    if arguments.first == "deploy" {
      arguments.removeFirst()
    }
    var result = Arguments()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      switch argument {
      case "--help", "-h":
        result.help = true
      case "--api-token-stdin":
        result.apiTokenStdin = true
      case "--json":
        result.json = true
      case "--adopt-existing":
        result.adoptExisting = true
      case "--account-id", "--state-file", "--worker-file", "--project-name", "--kv-title":
        index += 1
        guard index < arguments.count else {
          throw EdgeTunnelError.usage("参数 \(argument) 缺少值。")
        }
        let value = arguments[index]
        switch argument {
        case "--account-id": result.accountID = value
        case "--state-file": result.stateFile = value
        case "--worker-file": result.workerFile = value
        case "--project-name": result.projectName = value
        case "--kv-title": result.kvTitle = value
        default: break
        }
      default:
        throw EdgeTunnelError.usage("存在未知参数。使用 --help 查看帮助；参数值未回显以避免泄露凭据。")
      }
      index += 1
    }
    return result
  }

  static let helpText = """
    用法:
      edgetunnel [deploy] [选项]

    默认会交互式询问 Cloudflare Account ID，并隐藏输入 API Token。

    选项:
      --account-id <32hex>   Cloudflare Account ID
      --api-token-stdin      从标准输入读取一行 API Token（适合自动化）
      --state-file <path>    状态文件路径（默认 .edgetunnel-state.json）
      --worker-file <path>   使用本地 _worker.js，仍强制校验固定 SHA-256
      --project-name <name>  覆盖默认 in-iiiam-<account-id> Pages 项目名
      --kv-title <title>     覆盖默认 in.iiiam-edgetunnel KV 标题
      --adopt-existing       显式接管并覆盖身份不明或已变化的同名资源
      --json                 以 JSON 输出部署参数（包含敏感字段）
      --help, -h             显示帮助

    环境变量:
      CLOUDFLARE_ACCOUNT_ID
      CLOUDFLARE_API_TOKEN

    安全说明:
      不支持 --api-token <value>，避免 Token 出现在 shell history 或进程列表。
      成功输出包含订阅地址、UUID 与管理密码；API Token 永不输出或写入状态文件。
    """
}

extension String {
  fileprivate var trimmedNonempty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
