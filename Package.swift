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
    ],
    targets: [
        .target(name: "InkRelayCore"),
        .executableTarget(name: "inkrelay", dependencies: ["InkRelayCore"]),
        .testTarget(name: "InkRelayCoreTests", dependencies: ["InkRelayCore"]),
    ]
)
