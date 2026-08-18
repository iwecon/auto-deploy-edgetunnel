// swift-tools-version: 5.9

import PackageDescription

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
    .target(name: "EdgeTunnelCore"),
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
