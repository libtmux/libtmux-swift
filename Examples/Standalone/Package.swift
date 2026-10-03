// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ApiExample",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "libtmux", path: "libtmux-source")
    ],
    targets: [
        .executableTarget(
            name: "ApiExample",
            dependencies: [
                .product(name: "LibTmux", package: "libtmux"),
                .product(name: "TmuxFixture", package: "libtmux"),
            ],
            path: "Sources"
        )
    ]
)
