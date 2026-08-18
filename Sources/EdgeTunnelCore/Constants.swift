import Foundation

public enum EdgeTunnelConstants {
  public static let upstreamCommit = "92fc6cc4a4cbfdf536394bc9b0397e5948b039f8"
  public static let upstreamURL = URL(
    string:
      "https://raw.githubusercontent.com/cmliu/edgetunnel/92fc6cc4a4cbfdf536394bc9b0397e5948b039f8/_worker.js"
  )!
  public static let upstreamSHA256 =
    "01e932b492aad13bedb742d9d9b87923062f4bb5a973fda5bb7c78b53181e55a"
  public static let maximumWorkerSize = 1_048_576
  public static let compatibilityDate = "2025-11-04"
  public static let defaultKVTitle = "in.iiiam-edgetunnel"
  public static let defaultStateFile = ".edgetunnel-state.json"
  public static let defaultsMarkerKey = "in.iiiam-defaults.json"
  public static let configKey = "config.json"
  public static let preferredIPsKey = "ADD.txt"
  public static let recommendedSubconfig =
    "https://raw.githubusercontent.com/cmliu/ACL4SSR/refs/heads/main/Clash/config/ACL4SSR_Online_Full_MultiMode_CF.ini"
  public static let upstreamDefaultSubconfig =
    "https://raw.githubusercontent.com/cmliu/ACL4SSR/refs/heads/main/Clash/config/ACL4SSR_Online_Mini_MultiMode_CF.ini"
  public static let recommendedPreferredSubscriptions = [
    "https://bestcf.pages.dev/domain/all.txt",
    "https://bestcf.pages.dev/vps789/top20.txt",
    "https://bestcf.pages.dev/wetest/ipv4.txt",
    "https://bestcf.pages.dev/uouin/all.txt",
    "https://bestcf.pages.dev/cfyes/ipv4.txt",
    "https://090227.pages.dev/bestcf?isp=all&ips=20",
    "https://bestcf.pages.dev/luoli/all.txt",
    "https://bestcf.pages.dev/xinyitang3/ipv4.txt",
    "https://bestcf.pages.dev/tiancheng/all.txt",
    "https://bestcf.pages.dev/gslege/Cfxyz.txt",
    "https://bestcf.pages.dev/ircf/ipv4.txt",
    "https://bestcf.pages.dev/s5gy/all.txt",
  ]
  public static let maximumResponseSize = 2_097_152
  public static let cloudflareAPIBaseURL = URL(string: "https://api.cloudflare.com/client/v4")!
  public static let defaultProjectNamePrefix = "in.iiiam"

  public static func defaultProjectName(accountID: String) -> String {
    let pagesSafePrefix = defaultProjectNamePrefix.replacingOccurrences(of: ".", with: "-")
    return "\(pagesSafePrefix)-\(accountID.lowercased())"
  }
}

public struct UpstreamDescriptor: Equatable {
  public let commit: String
  public let url: URL
  public let sha256: String
  public let maximumSize: Int

  public init(commit: String, url: URL, sha256: String, maximumSize: Int) {
    self.commit = commit
    self.url = url
    self.sha256 = sha256
    self.maximumSize = maximumSize
  }

  public static let pinned = UpstreamDescriptor(
    commit: EdgeTunnelConstants.upstreamCommit,
    url: EdgeTunnelConstants.upstreamURL,
    sha256: EdgeTunnelConstants.upstreamSHA256,
    maximumSize: EdgeTunnelConstants.maximumWorkerSize
  )
}
