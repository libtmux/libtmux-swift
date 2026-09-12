// Shared arena wiring for every per-example artifact: the descriptor is the
// only activation signal, and once it is set a missing or mismatched
// artifact, socket, or tmux binary throws rather than falling back.

import Foundation
import LibTmux
import Testing

enum ArenaRoute: Equatable {
    case fixture
    case arena(socketPath: String, tmuxExecutable: String)
}

enum ArenaContractError: Error {
    case incomplete
    case wrongArtifact
}

struct ArenaEvidence: Codable {
    let artifact: String
    let challenge: String
    let schema: Int
    let serverProcessID: Int
    let socketPath: String

    enum CodingKeys: String, CodingKey {
        case artifact
        case challenge
        case schema
        case serverProcessID = "server_pid"
        case socketPath = "socket_path"
    }
}

/// Decides whether this process is running under the docs arena for `artifact`.
func arenaRoute(environment: [String: String], artifact: String) throws -> ArenaRoute {
    guard let descriptor = environment["LIBTMUX_ARENA_DESCRIPTOR"], !descriptor.isEmpty else {
        return .fixture
    }
    guard let actualArtifact = environment["LIBTMUX_ARENA_ARTIFACT"], !actualArtifact.isEmpty,
        let socketPath = environment["LIBTMUX_SOCKET_PATH"], !socketPath.isEmpty,
        let tmuxExecutable = environment["LIBTMUX_TMUX_BIN"], !tmuxExecutable.isEmpty
    else {
        throw ArenaContractError.incomplete
    }
    guard actualArtifact == artifact else {
        throw ArenaContractError.wrongArtifact
    }
    return .arena(socketPath: socketPath, tmuxExecutable: tmuxExecutable)
}

/// The server the arena lent, or `nil` off the fixture path.
func arenaServer(for route: ArenaRoute) throws -> Server? {
    guard case let .arena(socketPath, tmuxExecutable) = route else { return nil }
    return try Server(socketPath: socketPath, tmuxExecutable: tmuxExecutable)
}

/// The one `LIBTMUX_ARENA_EVIDENCE` line the docs-arena supervisor requires.
func arenaEvidence(
    for server: Server,
    requestedSocket: String,
    artifact: String
) async throws -> Data {
    let serverProcessID = try #require(try await server.serverProcessID())
    let actualSocketPath = try #require(try await server.format("#{socket_path}"))
    try #require(actualSocketPath == requestedSocket)
    let challenge = try #require(try await server.format("#{@libtmux_arena_challenge}"))
    try #require(!challenge.isEmpty)
    return try JSONEncoder().encode(
        ArenaEvidence(
            artifact: artifact,
            challenge: challenge,
            schema: 1,
            serverProcessID: serverProcessID,
            socketPath: actualSocketPath
        )
    )
}

// MARK: - Contract tests, once for every artifact rather than copied per example.

private let contractArtifact = "swift-example"

@Suite("arena support", .timeLimit(.minutes(1)))
struct ArenaSupportTests {
    @Test("arena aliases do not replace the fixture")
    func arenaAliasesDoNotReplaceTheFixture() throws {
        let route = try arenaRoute(
            environment: [
                "LIBTMUX_ARENA_DESCRIPTOR": "",
                "LIBTMUX_ARENA_ARTIFACT": contractArtifact,
                "LIBTMUX_SOCKET_PATH": "/not-an-arena-socket",
                "LIBTMUX_TMUX_BIN": "/not-an-arena-tmux",
            ],
            artifact: contractArtifact
        )

        #expect(route == .fixture)
    }

    @Test("a complete, matching descriptor selects the arena")
    func completeMatchingDescriptorSelectsTheArena() throws {
        let route = try arenaRoute(
            environment: [
                "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                "LIBTMUX_ARENA_ARTIFACT": contractArtifact,
                "LIBTMUX_SOCKET_PATH": "/arena.sock",
                "LIBTMUX_TMUX_BIN": "/usr/bin/tmux",
            ],
            artifact: contractArtifact
        )

        #expect(route == .arena(socketPath: "/arena.sock", tmuxExecutable: "/usr/bin/tmux"))
    }

    @Test("an activated arena contract fails closed before server creation")
    func activatedArenaContractFailsClosed() {
        for environment in [
            ["LIBTMUX_ARENA_DESCRIPTOR": "enabled"],
            [
                "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                "LIBTMUX_ARENA_ARTIFACT": "",
                "LIBTMUX_SOCKET_PATH": "/arena.sock",
                "LIBTMUX_TMUX_BIN": "/usr/bin/tmux",
            ],
            [
                "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                "LIBTMUX_ARENA_ARTIFACT": contractArtifact,
                "LIBTMUX_SOCKET_PATH": "",
                "LIBTMUX_TMUX_BIN": "/usr/bin/tmux",
            ],
            [
                "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                "LIBTMUX_ARENA_ARTIFACT": contractArtifact,
                "LIBTMUX_SOCKET_PATH": "/arena.sock",
                "LIBTMUX_TMUX_BIN": "",
            ],
            [
                "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                "LIBTMUX_ARENA_ARTIFACT": "other-example",
                "LIBTMUX_SOCKET_PATH": "/arena.sock",
                "LIBTMUX_TMUX_BIN": "/usr/bin/tmux",
            ],
        ] {
            #expect(throws: ArenaContractError.self) {
                try arenaRoute(environment: environment, artifact: contractArtifact)
            }
        }
    }
}
