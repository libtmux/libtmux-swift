// swift-tools-version: 6.2

import PackageDescription

// The examples are their own package so they reach the library the way a reader
// does — through the products, with no `@testable` and no access to anything the
// manifest does not vend. An example that compiles here is one a consumer can
// paste; an example that compiles inside the suite proves less, because the
// suite can see internals a consumer cannot.
//
// This is the shape the other ports already settled on: `libtmux-go` keeps
// `examples/` as its own module with `replace … => ../`, and `libtmux-ts` keeps
// `examples/` as a private workspace package depending on `libtmux`. Neither
// publishes it.
//
// The dependency names itself rather than inheriting an identity from the
// directory this repository happens to be cloned into: a path dependency is
// identified by its last path component, so `package:` below would otherwise
// only resolve in a checkout called `libtmux-swift`.
//
// `.defaults` is listed alongside the trait rather than replaced by it. The
// parameter's default value is `[.defaults]`, so naming a trait *replaces* that
// set — with the root's default set empty today the two spellings agree, and
// the moment a default-enabled trait is added they would not.
let package = Package(
    name: "Examples",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "libtmux", path: "..", traits: [.defaults, "YAMLWorkspaces"])
    ],
    targets: [
        // The examples themselves, as a library rather than as snippets: a
        // snippet is an executable and cannot be imported, which is what forces
        // the documented text to be typed a second time inside a test. A
        // library target is compiled by the build *and* callable by a test, so
        // the example that runs is the example that is documented.
        .target(
            name: "ExampleCode",
            dependencies: [
                .product(name: "LibTmux", package: "libtmux"),
                .product(name: "TmuxWorkspace", package: "libtmux"),
            ]
        ),
        // Top-level code cannot live in a library target — `statements are not
        // allowed at the top level` — so the one documented example written that
        // way is an executable. A `Snippets/` directory does not work here: a
        // snippet in a package whose library arrives through a path dependency
        // fails to find the transitive C module `CSystem`.
        .executableTarget(
            name: "QuickStart",
            dependencies: [.product(name: "LibTmux", package: "libtmux")]
        ),
        .testTarget(
            name: "ExampleTests",
            dependencies: [
                "ExampleCode",
                .product(name: "LibTmux", package: "libtmux"),
                .product(name: "TmuxWorkspace", package: "libtmux"),
                .product(name: "TmuxTestSupport", package: "libtmux"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
