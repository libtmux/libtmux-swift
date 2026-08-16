// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "libtmux",
    // macOS 13 is what this library needs, and no macOS can build it:
    // swift-subprocess 1.0.0 calls macOS 26 API with no availability guard, and
    // SwiftPM compiles a dependency at that dependency's own declared minimum.
    // Raising this number does not help; only a release upstream does.
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LibTmux", targets: ["LibTmux"]),
        .library(name: "TmuxWorkspace", targets: ["TmuxWorkspace"]),
        .library(name: "LibTmuxMCP", targets: ["LibTmuxMCP"]),
        .executable(name: "libtmux-mcp", targets: ["libtmux-mcp"]),
        // Provisioning and reaping, for anyone whose own tests drive tmux.
        //
        // The other ports of libtmux all vend theirs: Go exports
        // `tmux/tmuxtest`, and Python ships `libtmux.pytest_plugin` behind a
        // `pytest11` entry point so installing the library is enough to get the
        // fixtures. A consumer writing tests against tmux otherwise reinvents
        // the parts that are easy to get wrong — a socket outside the shared
        // root, or a server left running when the process is killed outright.
        .library(name: "TmuxTestSupport", targets: ["TmuxFixture"]),
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
            // SwiftPM treats an undeclared file in a target directory as an
            // unhandled resource.
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
            exclude: ["README.md"]
        ),
        .target(
            name: "LibTmuxMCP",
            dependencies: ["LibTmux"],
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "libtmux-mcp",
            dependencies: ["LibTmux", "LibTmuxMCP"],
            exclude: ["README.md"]
        ),
        // Shared by every suite that talks to a real tmux, so that all of them
        // provision and reap servers the same way. It stays under `Tests/`
        // because that is where it is read from most: SwiftPM is happy to vend
        // a product whose target lives there, so `TmuxTestSupport` reaches it
        // without the file moving. Everything outside this package — the
        // examples, the benchmark — takes the product, because two targets of
        // this name in one package graph is an error rather than a duplicate.
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
