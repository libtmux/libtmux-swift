import Foundation
import Testing

@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private let fakeTmuxBinarySHA256 =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

private enum FakeLaneAuthenticationError: Error {
    case acceptedInvalidEnvironment
    case chmodFailed(Int32)
}

private struct FakeLaneAuthenticationScope {
    let binary: URL
    let binaryRoot: URL
    let declaration: URL
    let laneRoot: URL
    let manifest: URL

    init() throws {
        let fileManager = FileManager.default
        let requestedRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "libtmux-lane-auth-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: requestedRoot,
            withIntermediateDirectories: false
        )
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        laneRoot = root.appendingPathComponent("lane-root", isDirectory: true)
        binaryRoot = root.appendingPathComponent("binary-root", isDirectory: true)
        declaration = root.appendingPathComponent("tmux-matrix.json")
        manifest = binaryRoot.appendingPathComponent("manifest.json")
        binary = binaryRoot.appendingPathComponent("3.7b/tmux")

        for directory in [
            laneRoot,
            laneRoot.appendingPathComponent("tmp", isDirectory: true),
            laneRoot.appendingPathComponent("run", isDirectory: true),
            laneRoot.appendingPathComponent("config", isDirectory: true),
            binary.deletingLastPathComponent(),
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        try Data("[\"3.7b\"]\n".utf8).write(to: declaration)
        try Data().write(to: binary)
        guard chmod(binary.path, 0o700) == 0 else {
            throw FakeLaneAuthenticationError.chmodFailed(errno)
        }

        let manifestText = """
            {
              "documentKind": "libtmux.tmux-matrix-manifest",
              "schemaVersion": 1,
              "source": {
                "originURL": "https://github.com/tmux/tmux.git",
                "head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "initialStatus": "",
                "finalStatus": "",
                "initialRefsSHA256": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                "finalRefsSHA256": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
                "initialIndexSHA256": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
                "finalIndexSHA256": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
                "sourceUnchanged": true
              },
              "lanes": [
                {
                  "tag": "3.7b",
                  "tagObject": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                  "peeledSourceObject": "cccccccccccccccccccccccccccccccccccccccc",
                  "binaryPath": "3.7b/tmux",
                  "binarySHA256": "\(fakeTmuxBinarySHA256)",
                  "reportedVersion": "tmux 3.7b",
                  "compilerIdentity": "fake compiler",
                  "buildStatus": "passed"
                }
              ]
            }
            """
        try Data(manifestText.utf8).write(to: manifest)
    }

    var environment: [String: String] {
        [
            "LIBTMUX_TMUX_BIN": binary.path,
            "LIBTMUX_TMUX_TAG": "3.7b",
            "LIBTMUX_MATRIX_ROOT": laneRoot.path,
            "LIBTMUX_MATRIX_MANIFEST": manifest.path,
            "LIBTMUX_MATRIX_BINARY_ROOT": binaryRoot.path,
            "LIBTMUX_PTY_CLIENT_PROBE": binary.path,
            "TMPDIR": laneRoot.appendingPathComponent("tmp", isDirectory: true).path,
            "XDG_RUNTIME_DIR": laneRoot.appendingPathComponent("run", isDirectory: true).path,
            "XDG_CONFIG_HOME": laneRoot.appendingPathComponent("config", isDirectory: true).path,
            "PATH": "/usr/bin:/bin",
        ]
    }

    func remove() {
        try? FileManager.default.removeItem(
            at: declaration.deletingLastPathComponent()
        )
    }
}

private func requireLaneAuthenticationFailure(
    environment: [String: String],
    declaration: URL
) throws {
    do {
        _ = try authenticatedTmuxLane(
            environment: environment,
            laneDeclarationAt: declaration
        )
        throw FakeLaneAuthenticationError.acceptedInvalidEnvironment
    } catch FakeLaneAuthenticationError.acceptedInvalidEnvironment {
        throw FakeLaneAuthenticationError.acceptedInvalidEnvironment
    } catch {
    }
}

@Suite("authenticated tmux lane environment")
struct TmuxLaneAuthenticationTests {
    @Test("exact manifest tag binary hash and sandbox root are accepted")
    func exactLaneEnvironmentIsAccepted() throws {
        let scope = try FakeLaneAuthenticationScope()
        defer { scope.remove() }

        let lane = try authenticatedTmuxLane(
            environment: scope.environment,
            laneDeclarationAt: scope.declaration
        )

        #expect(lane.binary == scope.binary.path)
        #expect(lane.root == scope.laneRoot)
    }

    @Test("a complete forged tag environment is rejected")
    func completeForgedTagIsRejected() throws {
        let scope = try FakeLaneAuthenticationScope()
        defer { scope.remove() }
        var environment = scope.environment
        environment["LIBTMUX_TMUX_TAG"] = "3.7a"

        try requireLaneAuthenticationFailure(
            environment: environment,
            declaration: scope.declaration
        )
    }

    @Test("a complete stale binary environment is rejected")
    func completeStaleBinaryIsRejected() throws {
        let scope = try FakeLaneAuthenticationScope()
        defer { scope.remove() }
        try Data("stale".utf8).write(to: scope.binary)

        try requireLaneAuthenticationFailure(
            environment: scope.environment,
            declaration: scope.declaration
        )
    }

    @Test("a complete environment with a forged binary path is rejected")
    func completeForgedBinaryPathIsRejected() throws {
        let scope = try FakeLaneAuthenticationScope()
        defer { scope.remove() }
        let forgedBinary = scope.binary
            .deletingLastPathComponent()
            .appendingPathComponent("forged-tmux")
        try Data().write(to: forgedBinary)
        guard chmod(forgedBinary.path, 0o700) == 0 else {
            throw FakeLaneAuthenticationError.chmodFailed(errno)
        }
        var environment = scope.environment
        environment["LIBTMUX_TMUX_BIN"] = forgedBinary.path

        try requireLaneAuthenticationFailure(
            environment: environment,
            declaration: scope.declaration
        )
    }

    @Test("a complete environment with a different sandbox root is rejected")
    func completeMismatchedRootIsRejected() throws {
        let scope = try FakeLaneAuthenticationScope()
        defer { scope.remove() }
        var environment = scope.environment
        environment["TMPDIR"] = scope.laneRoot.path

        try requireLaneAuthenticationFailure(
            environment: environment,
            declaration: scope.declaration
        )
    }
}
