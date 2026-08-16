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
// The fixture arrives as `TmuxTestSupport` rather than by path: two targets of
// the same name in one package graph is an error, not a duplicate.
let package = Package(
    name: "Benchmarks",
    // macOS 13 is what this library needs, and no macOS can build it:
    // swift-subprocess 1.0.0 calls macOS 26 API with no availability guard, and
    // SwiftPM compiles a dependency at that dependency's own declared minimum.
    // Raising this number does not help; only a release upstream does.
    platforms: [.macOS(.v13)],
    dependencies: [.package(name: "libtmux", path: "..")],
    targets: [
        .executableTarget(
            name: "libtmux-bench",
            dependencies: [
                .product(name: "LibTmux", package: "libtmux"),
                .product(name: "TmuxTestSupport", package: "libtmux"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
