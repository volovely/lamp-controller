// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LampAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LampAgent", targets: ["LampAgent"]),
        .executable(name: "lamp-agent", targets: ["lamp-agent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.3.0"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.4.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "LampAgent",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ]
        ),
        .executableTarget(name: "lamp-agent", dependencies: ["LampAgent"]),
        .testTarget(
            name: "LampAgentTests",
            dependencies: [
                "LampAgent",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "CustomDump", package: "swift-custom-dump"),
            ]
        ),
    ]
)
