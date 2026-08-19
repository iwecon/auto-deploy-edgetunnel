// swift-tools-version: 5.9

import PackageDescription

#if os(Windows)
  let edgeTunnelCoreExcludes = ["StateStore.swift"]
#else
  let edgeTunnelCoreExcludes = ["StateStoreWindows.swift"]
#endif

let package = Package(
  name: "auto-deploy-edgetunnel",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "EdgeTunnelCore", targets: ["EdgeTunnelCore"]),
    .executable(name: "edgetunnel", targets: ["edgetunnel"]),
  ],
  targets: [
    .target(name: "EdgeTunnelCore", exclude: edgeTunnelCoreExcludes),
    .executableTarget(
      name: "edgetunnel",
      dependencies: ["EdgeTunnelCore"]
    ),
    .testTarget(
      name: "EdgeTunnelCoreTests",
      dependencies: ["EdgeTunnelCore"]
    ),
  ]
)
