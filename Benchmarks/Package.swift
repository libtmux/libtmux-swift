// swift-tools-version: 6.2

import PackageDescription

// The benchmark is its own package so the shipped manifest names only what
// ships. It depends on the library by path rather than carrying a copy, so the
// numbers it prints still come from the library as built.
//
// The dependency names itself rather than inheriting an identity from the
// directory this repository happens to be cloned into: a path dependency is
// identified by its last path component, so `package:` below would otherwise
// only resolve in a checkout called `libtmux-swift`.
//
// `TmuxFixture` is a symlink to the one the suites use, because a target path
// cannot leave its package root and the fixture is not worth vending as a
// product to reach it. Provisioning and reaping stay identical to the suites'
// by construction: it is the same file.
let package = Package(
    name: "Benchmarks",
    // macOS 13 is what this library needs. It cannot currently be built for
    // any macOS at all: swift-subprocess 1.0.0 — its only release — has a
    // `run` overload taking a `borrowing Span` and calling `.bytes` on it,
    // both macOS 26 API with no availability guard, and SwiftPM compiles a
    // dependency at that dependency's own declared minimum rather than the
    // root's. Raising this number does not help; only a release upstream does.
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "libtmux", path: "..")],
    targets: [
        .target(
            name: "TmuxFixture",
            dependencies: [.product(name: "LibTmux", package: "libtmux")]
        ),
        .executableTarget(
            name: "libtmux-bench",
            dependencies: [
                .product(name: "LibTmux", package: "libtmux"),
                "TmuxFixture",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
