// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "intel-sky-service",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "IntelSkyCore", targets: ["IntelSkyCore"]),
    .executable(name: "intel-sky-service", targets: ["IntelSkyService"]),
    .executable(name: "sky-smoke-client", targets: ["SkySmokeClient"]),
    .executable(name: "pip-layer-smoke", targets: ["PIPLayerSmoke"]),
  ],
  targets: [
    .target(name: "IntelSkyCore"),
    .executableTarget(name: "IntelSkyService", dependencies: ["IntelSkyCore"]),
    .executableTarget(name: "SkySmokeClient", dependencies: ["IntelSkyCore"]),
    .executableTarget(name: "PIPLayerSmoke"),
    .testTarget(name: "IntelSkyCoreTests", dependencies: ["IntelSkyCore"]),
  ]
)
