// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LibTmuxSpikes",
    // macOS 26 rather than the 13 this library needs, because
    // swift-subprocess 1.0.0 — its only release — has a `run` overload taking
    // a `borrowing Span` and calling `.bytes` on it, and both are macOS 26
    // API carrying no availability guard. Nothing here calls that overload,
    // but a module compiles as a whole, so the floor is upstream's rather
    // than ours. Lower it again when a release fixes that.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "fixture-owner-helper", targets: ["FixtureOwnerHelper"]),
        .executable(name: "process-probe", targets: ["ProcessProbe"]),
        .executable(name: "pty-client-probe", targets: ["PtyClientProbe"]),
        .executable(name: "sigpipe-probe", targets: ["SigpipeProbe"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-subprocess.git",
            .upToNextMinor(from: "1.0.0")
        )
    ],
    targets: [
        .target(name: "SpikeSupport"),
        .executableTarget(
            name: "ProcessProbe",
            dependencies: ["SpikeSupport"]
        ),
        .executableTarget(name: "PtyClientProbe"),
        .target(
            name: "TransportBakeoff",
            dependencies: [
                "SpikeSupport",
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .target(
            name: "OwnershipBakeoff",
            dependencies: ["SpikeSupport"]
        ),
        .target(
            name: "KeyPathBakeoff",
            dependencies: ["SpikeSupport"]
        ),
        .target(
            name: "FixtureBakeoff",
            dependencies: ["SpikeSupport"]
        ),
        .target(
            name: "FormatsBakeoff",
            dependencies: ["SpikeSupport"]
        ),
        .executableTarget(
            name: "FixtureOwnerHelper",
            dependencies: ["SpikeSupport", "TransportBakeoff"]
        ),
        .executableTarget(
            name: "SigpipeProbe",
            dependencies: ["SpikeSupport", "TransportBakeoff"]
        ),
        .testTarget(
            name: "SpikeSupportTests",
            dependencies: ["SpikeSupport"]
        ),
        .testTarget(
            name: "TransportBakeoffTests",
            dependencies: ["SpikeSupport", "TransportBakeoff"]
        ),
        .testTarget(
            name: "OwnershipBakeoffTests",
            dependencies: ["SpikeSupport", "OwnershipBakeoff"]
        ),
        .testTarget(
            name: "KeyPathBakeoffTests",
            dependencies: ["SpikeSupport", "KeyPathBakeoff"]
        ),
        .testTarget(
            name: "FormatsBakeoffTests",
            dependencies: [
                "SpikeSupport",
                "FormatsBakeoff",
                "FixtureBakeoff",
                "TransportBakeoff",
            ]
        ),
        .testTarget(
            name: "FixtureBakeoffTests",
            dependencies: [
                "SpikeSupport",
                "FixtureBakeoff",
                "PtyClientProbe",
                "TransportBakeoff",
                "FixtureOwnerHelper",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
