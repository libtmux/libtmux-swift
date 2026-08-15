// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "libtmux",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LibTmux", targets: ["LibTmux"]),
        .library(name: "WorkspaceBuilder", targets: ["WorkspaceBuilder"]),
        .library(name: "LibTmuxMCP", targets: ["LibTmuxMCP"]),
        .executable(name: "libtmux-mcp", targets: ["libtmux-mcp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            .upToNextMinor(from: "1.0.0")
        ),
        // Used only by WorkspaceBuilder, and named as that target's
        // dependency rather than the library's: building LibTmux alone compiles
        // none of it. A consumer of the core still resolves the checkout, which
        // is the whole of what it costs them.
        .package(
            url: "https://github.com/jpsim/Yams.git",
            .upToNextMinor(from: "6.2.2")
        ),
        // A build-time plugin: it renders the DocC catalogue in CI and is not
        // linked into anything that ships.
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin.git",
            from: "1.4.3"
        ),
    ],
    targets: [
        .target(
            name: "LibTmux",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess")
            ]
        ),
        .target(
            name: "WorkspaceBuilder",
            dependencies: [
                "LibTmux",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "LibTmuxMCP",
            dependencies: ["LibTmux"]
        ),
        .executableTarget(
            name: "libtmux-mcp",
            dependencies: ["LibTmux", "LibTmuxMCP"]
        ),
        // Prints the mode comparison in the docs. Kept as a target rather than
        // a script so the numbers come from the library as shipped, and it
        // reaps its servers through the same fixture the suites use.
        .executableTarget(
            name: "libtmux-bench",
            dependencies: ["LibTmux", "TmuxFixture"]
        ),
        // Shared by every suite that talks to a real tmux, so that all of them
        // provision and reap servers the same way.
        .target(
            name: "TmuxFixture",
            dependencies: ["LibTmux"],
            path: "Tests/TmuxFixture"
        ),
        .testTarget(
            name: "LibTmuxTests",
            dependencies: ["LibTmux", "TmuxFixture"]
        ),
        .testTarget(
            name: "WorkspaceBuilderTests",
            dependencies: ["WorkspaceBuilder", "LibTmux", "TmuxFixture"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LibTmuxMCPTests",
            dependencies: ["LibTmuxMCP", "LibTmux", "TmuxFixture"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
