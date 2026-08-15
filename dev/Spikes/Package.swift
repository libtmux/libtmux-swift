// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LibTmuxSpikes",
    // macOS 13 is what this library needs. It cannot currently be built for
    // any macOS at all: swift-subprocess 1.0.0 — its only release — has a
    // `run` overload taking a `borrowing Span` and calling `.bytes` on it,
    // both macOS 26 API with no availability guard, and SwiftPM compiles a
    // dependency at that dependency's own declared minimum rather than the
    // root's. Raising this number does not help; only a release upstream does.
    platforms: [.macOS(.v13)],
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
