import Foundation

struct RecommendedDefaultsMerge {
  let config: Data
  let preferredSubscriptions: Data
  let configChanged: Bool
  let preferredSubscriptionsChanged: Bool
}

enum RecommendedDefaults {
  static func merge(
    config: Data,
    preferredSubscriptions: Data?
  ) throws -> RecommendedDefaultsMerge {
    guard var root = try JSONSerialization.jsonObject(with: config) as? [String: Any],
      !root.isEmpty
    else {
      throw EdgeTunnelError.recommendedDefaults("config.json 不是非空 JSON 对象。")
    }
    var configChanged = false

    for key in ["启用0RTT", "ECH"] {
      if root[key] == nil {
        root[key] = true
        configChanged = true
      } else if let enabled = strictBoolean(root[key]) {
        if !enabled {
          root[key] = true
          configChanged = true
        }
      } else {
        throw EdgeTunnelError.recommendedDefaults("config.json 中 \(key) 的类型无效。")
      }
    }

    if root["订阅转换配置"] != nil, root["订阅转换配置"] as? [String: Any] == nil {
      throw EdgeTunnelError.recommendedDefaults("config.json 中订阅转换配置的类型无效。")
    }
    var subscriptionConfig = root["订阅转换配置"] as? [String: Any] ?? [:]
    if subscriptionConfig["SUBCONFIG"] != nil,
      subscriptionConfig["SUBCONFIG"] as? String == nil
    {
      throw EdgeTunnelError.recommendedDefaults("config.json 中 SUBCONFIG 的类型无效。")
    }
    let existingSubconfig = subscriptionConfig["SUBCONFIG"] as? String
    if existingSubconfig == nil
      || existingSubconfig == EdgeTunnelConstants.upstreamDefaultSubconfig
    {
      subscriptionConfig["SUBCONFIG"] = EdgeTunnelConstants.recommendedSubconfig
      root["订阅转换配置"] = subscriptionConfig
      configChanged = true
    }

    if root["优选订阅生成"] != nil, root["优选订阅生成"] as? [String: Any] == nil {
      throw EdgeTunnelError.recommendedDefaults("config.json 中优选订阅生成的类型无效。")
    }
    let existingPreferred = root["优选订阅生成"] as? [String: Any]
    let preferredIsMissing = existingPreferred == nil
    var preferred = existingPreferred ?? [:]
    if preferred["local"] != nil, strictBoolean(preferred["local"]) == nil {
      throw EdgeTunnelError.recommendedDefaults("config.json 中优选订阅 local 的类型无效。")
    }
    if preferred["本地IP库"] != nil, preferred["本地IP库"] as? [String: Any] == nil {
      throw EdgeTunnelError.recommendedDefaults("config.json 中本地 IP 库的类型无效。")
    }
    let localIPs = preferred["本地IP库"] as? [String: Any]
    if localIPs?["随机IP"] != nil, strictBoolean(localIPs?["随机IP"]) == nil {
      throw EdgeTunnelError.recommendedDefaults("config.json 中随机 IP 的类型无效。")
    }
    for key in ["随机数量", "指定端口"]
    where localIPs?[key] != nil && strictInteger(localIPs?[key]) == nil {
      throw EdgeTunnelError.recommendedDefaults("config.json 中 \(key) 的类型无效。")
    }
    if let subscription = preferred["SUB"],
      !(subscription is NSNull),
      !(subscription is String)
    {
      throw EdgeTunnelError.recommendedDefaults("config.json 中优选订阅 SUB 的类型无效。")
    }

    let localMode = strictBoolean(preferred["local"])
    let randomIP = strictBoolean(localIPs?["随机IP"])
    let randomCount = strictInteger(localIPs?["随机数量"])
    let designatedPort = strictInteger(localIPs?["指定端口"])
    let subscription = preferred["SUB"]
    let subscriptionIsNull = subscription == nil || subscription is NSNull
    let modeStructureMissing =
      existingPreferred != nil
      && (preferred["local"] == nil
        || localIPs == nil
        || localIPs?["随机IP"] == nil
        || preferred["SUB"] == nil)
    let defaultAuxiliarySettings =
      (randomCount == nil || randomCount == 16)
      && (designatedPort == nil || designatedPort == -1)
    let stillUpstreamDefault =
      localMode == true
      && randomIP == true
      && subscriptionIsNull
      && defaultAuxiliarySettings
    let missingStructureStillDefault =
      modeStructureMissing
      && (preferred["local"] == nil || localMode == true)
      && (randomIP == nil || randomIP == true)
      && subscriptionIsNull
      && defaultAuxiliarySettings
    if preferredIsMissing || missingStructureStillDefault || stillUpstreamDefault {
      var updatedLocalIPs = localIPs ?? [:]
      updatedLocalIPs["随机IP"] = false
      preferred["local"] = true
      preferred["本地IP库"] = updatedLocalIPs
      preferred["SUB"] = NSNull()
      root["优选订阅生成"] = preferred
      configChanged = true
    }

    guard let originalText = String(data: preferredSubscriptions ?? Data(), encoding: .utf8)
    else {
      throw EdgeTunnelError.recommendedDefaults("ADD.txt 不是有效 UTF-8。")
    }
    let originalLines = originalText.components(separatedBy: .newlines)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var seen = Set<String>()
    var mergedLines = originalLines.filter {
      seen.insert($0.trimmingCharacters(in: .whitespacesAndNewlines)).inserted
    }
    for url in EdgeTunnelConstants.recommendedPreferredSubscriptions
    where seen.insert(url).inserted {
      mergedLines.append(url)
    }
    let mergedPreferred = Data((mergedLines.joined(separator: "\n") + "\n").utf8)
    let configData =
      configChanged
      ? try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
      : config
    return RecommendedDefaultsMerge(
      config: configData,
      preferredSubscriptions: mergedPreferred,
      configChanged: configChanged,
      preferredSubscriptionsChanged: (preferredSubscriptions ?? Data()) != mergedPreferred
    )
  }

  static func strictBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber else {
      return nil
    }
    guard String(cString: number.objCType) == "c" else { return nil }
    return number.boolValue
  }

  static func strictInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber else {
      return nil
    }
    let type = String(cString: number.objCType)
    guard ["s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else {
      return nil
    }
    return Int(number.stringValue)
  }
}

struct RecommendedDefaultsInitializer {
  typealias Sleep = (UInt64) async throws -> Void

  private let cloudflare: CloudflareClient
  private let sleep: Sleep

  init(
    cloudflare: CloudflareClient,
    sleep: @escaping Sleep = { nanoseconds in
      try await Task.sleep(nanoseconds: nanoseconds)
    }
  ) {
    self.cloudflare = cloudflare
    self.sleep = sleep
  }

  func ensure(
    accountID: String,
    namespaceID: String,
    upstreamCommit: String
  ) async throws {
    if let marker = try await cloudflare.getKVValue(
      accountID: accountID,
      namespaceID: namespaceID,
      key: EdgeTunnelConstants.defaultsMarkerKey
    ) {
      guard let object = try? JSONSerialization.jsonObject(with: marker) as? [String: Any],
        RecommendedDefaults.strictInteger(object["version"]) == 1
      else {
        throw EdgeTunnelError.recommendedDefaults("现有初始化标记无效，已停止以避免覆盖配置。")
      }
      return
    }

    var config: Data?
    for attempt in 0..<5 {
      let candidate = try await cloudflare.getKVValue(
        accountID: accountID,
        namespaceID: namespaceID,
        key: EdgeTunnelConstants.configKey
      )
      if let candidate {
        guard let object = try? JSONSerialization.jsonObject(with: candidate) as? [String: Any]
        else {
          throw EdgeTunnelError.recommendedDefaults("config.json 不是 JSON 对象。")
        }
        if !object.isEmpty {
          config = candidate
          break
        }
      }
      if attempt < 4 {
        try await sleep(UInt64(300 * (attempt + 1)) * 1_000_000)
      }
    }
    guard let config else {
      throw EdgeTunnelError.recommendedDefaults("Worker 尚未生成非空 config.json。")
    }

    let preferred = try await cloudflare.getKVValue(
      accountID: accountID,
      namespaceID: namespaceID,
      key: EdgeTunnelConstants.preferredIPsKey
    )
    let merged = try RecommendedDefaults.merge(
      config: config,
      preferredSubscriptions: preferred
    )
    if merged.configChanged {
      try await cloudflare.putKVValue(
        merged.config,
        contentType: "application/json",
        accountID: accountID,
        namespaceID: namespaceID,
        key: EdgeTunnelConstants.configKey
      )
    }
    if merged.preferredSubscriptionsChanged {
      try await cloudflare.putKVValue(
        merged.preferredSubscriptions,
        contentType: "text/plain; charset=utf-8",
        accountID: accountID,
        namespaceID: namespaceID,
        key: EdgeTunnelConstants.preferredIPsKey
      )
    }
    let marker = try JSONSerialization.data(
      withJSONObject: ["version": 1, "upstreamCommit": upstreamCommit],
      options: [.sortedKeys]
    )
    try await cloudflare.putKVValue(
      marker,
      contentType: "application/json",
      accountID: accountID,
      namespaceID: namespaceID,
      key: EdgeTunnelConstants.defaultsMarkerKey
    )
  }
}
