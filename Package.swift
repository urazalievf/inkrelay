// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "InkRelay",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "InkRelayCore", targets: ["InkRelayCore"]),
        .executable(name: "inkrelay", targets: ["inkrelay"]),
        .executable(name: "InkRelayBar", targets: ["InkRelayBar"]),
    ],
    targets: [
        .target(name: "InkRelayCore"),
        .executableTarget(name: "inkrelay", dependencies: ["InkRelayCore"]),
        .executableTarget(name: "InkRelayBar", dependencies: ["InkRelayCore"]),
        .testTarget(name: "InkRelayCoreTests", dependencies: ["InkRelayCore"]),
    ]
)
