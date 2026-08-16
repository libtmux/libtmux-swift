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
// The fixture arrives as `TmuxTestSupport`, the product the library vends for
// exactly this. It used to be a symlink, which a target path cannot avoid being
// when it needs a file outside its own package root; a product reaches it
// without the copy, and two targets of the same name in one package graph is an
// error rather than a duplicate.
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
