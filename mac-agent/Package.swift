// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LampAgent", targets: ["LampAgent"]),
        .executable(name: "lamp-agent", targets: ["lamp-agent"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "LampAgent"),
        .executableTarget(name: "lamp-agent", dependencies: ["LampAgent"]),
        .testTarget(name: "LampAgentTests", dependencies: ["LampAgent"]),
    ]
)
