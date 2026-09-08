// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "McpSwap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mcp-swap", targets: ["McpSwap"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")
    ],
    targets: [
        .target(name: "CMcpSwap"),
        .target(
            name: "McpSwapCore",
            dependencies: [
                "CMcpSwap",
                .product(name: "TOML", package: "swift-toml"),
            ]
        ),
        .executableTarget(name: "McpSwap", dependencies: ["McpSwapCore"]),
        .testTarget(name: "McpSwapCoreTests", dependencies: ["McpSwapCore"]),
    ],
    swiftLanguageModes: [.v6]
)
