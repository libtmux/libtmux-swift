// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "libtmux",
    // macOS 13 is what this library needs. It cannot currently be built for
    // any macOS at all: swift-subprocess 1.0.0 — its only release — has a
    // `run` overload taking a `borrowing Span` and calling `.bytes` on it,
    // both macOS 26 API with no availability guard, and SwiftPM compiles a
    // dependency at that dependency's own declared minimum rather than the
    // root's. Raising this number does not help; only a release upstream does.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LibTmux", targets: ["LibTmux"]),
        .library(name: "TmuxWorkspace", targets: ["TmuxWorkspace"]),
        .library(name: "LibTmuxMCP", targets: ["LibTmuxMCP"]),
        .executable(name: "libtmux-mcp", targets: ["libtmux-mcp"]),
    ],
    // Reading tmuxp files is the one thing here that needs a YAML parser, and
    // a trait is what keeps that from being everyone's problem: with it off,
    // SwiftPM drops Yams before resolution rather than after, so a consumer of
    // LibTmux alone never fetches it. WorkspaceBuilder still builds without it
    // — workspaces described in Swift or in JSON need no parser — and only
    // `Workspace.decode(yaml:)` goes away.
    traits: [.default(enabledTraits: []), "YAMLWorkspaces"],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            .upToNextMinor(from: "1.0.0")
        ),
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
            ],
            // Beside the sources it documents, and named here because
            // SwiftPM treats an undeclared file in a target directory as a
            // resource somebody forgot.
            exclude: ["README.md"]
        ),
        .target(
            name: "TmuxWorkspace",
            dependencies: [
                "LibTmux",
                .product(
                    name: "Yams",
                    package: "Yams",
                    condition: .when(traits: ["YAMLWorkspaces"])
                ),
            ],
            // Beside the sources it documents, and named here because
            // SwiftPM treats an undeclared file in a target directory as a
            // resource somebody forgot.
            exclude: ["README.md"]
        ),
        .target(
            name: "LibTmuxMCP",
            dependencies: ["LibTmux"],
            // Beside the sources it documents, and named here because
            // SwiftPM treats an undeclared file in a target directory as a
            // resource somebody forgot.
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "libtmux-mcp",
            dependencies: ["LibTmux", "LibTmuxMCP"],
            // Beside the sources it documents, and named here because
            // SwiftPM treats an undeclared file in a target directory as a
            // resource somebody forgot.
            exclude: ["README.md"]
        ),
        // Shared by every suite that talks to a real tmux, so that all of them
        // provision and reap servers the same way. `Benchmarks/` symlinks this
        // directory rather than being handed a product, so the benchmark
        // provisions servers the same way without widening what ships.
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
            name: "TmuxWorkspaceTests",
            dependencies: ["TmuxWorkspace", "LibTmux", "TmuxFixture"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LibTmuxMCPTests",
            dependencies: ["LibTmuxMCP", "LibTmux", "TmuxFixture"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
