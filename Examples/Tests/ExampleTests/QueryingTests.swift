import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture

private enum ArenaRoute: Equatable {
    case fixture
    case arena(socketPath: String, tmuxExecutable: String)
}

private enum ArenaContractError: Error {
    case incomplete
    case wrongArtifact
}

private struct ArenaEvidence: Codable {
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

private func arenaRoute(environment: [String: String]) throws -> ArenaRoute {
    guard let descriptor = environment["LIBTMUX_ARENA_DESCRIPTOR"], !descriptor.isEmpty else {
        return .fixture
    }
    guard let artifact = environment["LIBTMUX_ARENA_ARTIFACT"], !artifact.isEmpty,
        let socketPath = environment["LIBTMUX_SOCKET_PATH"], !socketPath.isEmpty,
        let tmuxExecutable = environment["LIBTMUX_TMUX_BIN"], !tmuxExecutable.isEmpty
    else {
        throw ArenaContractError.incomplete
    }
    guard artifact == "swift-querying" else {
        throw ArenaContractError.wrongArtifact
    }
    return .arena(socketPath: socketPath, tmuxExecutable: tmuxExecutable)
}

private func arenaServer(for route: ArenaRoute) throws -> Server? {
    guard case let .arena(socketPath, tmuxExecutable) = route else { return nil }
    return try Server(socketPath: socketPath, tmuxExecutable: tmuxExecutable)
}

private func assertThreeListings(on server: Server) async throws {
    let (sessions, windows, panes) = try await askWhatExists(server)
    try #require(sessions == 1)
    try #require(windows == 1)
    try #require(panes == 1)
}

private func arenaEvidence(for server: Server, requestedSocket: String) async throws -> Data {
    let serverProcessID = try #require(try await server.serverProcessID())
    let actualSocketPath = try #require(try await server.format("#{socket_path}"))
    try #require(actualSocketPath == requestedSocket)
    let challenge = try #require(try await server.format("#{@libtmux_arena_challenge}"))
    try #require(!challenge.isEmpty)
    return try JSONEncoder().encode(
        ArenaEvidence(
            artifact: "swift-querying",
            challenge: challenge,
            schema: 1,
            serverProcessID: serverProcessID,
            socketPath: actualSocketPath
        )
    )
}

@Suite("querying", .timeLimit(.minutes(1)))
struct QueryingTests {
    @Test("arena aliases do not replace the fixture")
    func arenaAliasesDoNotReplaceTheFixture() throws {
        let route = try arenaRoute(
            environment: [
                "LIBTMUX_ARENA_DESCRIPTOR": "",
                "LIBTMUX_ARENA_ARTIFACT": "swift-querying",
                "LIBTMUX_SOCKET_PATH": "/not-an-arena-socket",
                "LIBTMUX_TMUX_BIN": "/not-an-arena-tmux",
            ]
        )

        #expect(route == .fixture)
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
                "LIBTMUX_ARENA_ARTIFACT": "swift-querying",
                "LIBTMUX_SOCKET_PATH": "",
                "LIBTMUX_TMUX_BIN": "/usr/bin/tmux",
            ],
            [
                "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                "LIBTMUX_ARENA_ARTIFACT": "swift-querying",
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
                try arenaRoute(environment: environment)
            }
        }
    }

    @Test("the arena route uses a borrowed real server and encodes its evidence")
    func arenaRouteUsesBorrowedServerAndEncodesEvidence() async throws {
        try await withTmuxServer { owner in
            let socketPath = try #require(try await owner.format("#{socket_path}"))
            let challenge = "arena-challenge"
            _ = try await owner.run(
                TmuxCommand("set-option", ["-g", "@libtmux_arena_challenge", challenge])
            )
            let route = try arenaRoute(
                environment: [
                    "LIBTMUX_ARENA_DESCRIPTOR": "enabled",
                    "LIBTMUX_ARENA_ARTIFACT": "swift-querying",
                    "LIBTMUX_SOCKET_PATH": socketPath,
                    "LIBTMUX_TMUX_BIN": owner.tmuxExecutable,
                ]
            )
            let borrowed = try #require(try arenaServer(for: route))

            #expect(borrowed.tmuxExecutable == owner.tmuxExecutable)
            try await assertThreeListings(on: borrowed)
            let evidence = try await arenaEvidence(for: borrowed, requestedSocket: socketPath)
            let decoded = try JSONDecoder().decode(ArenaEvidence.self, from: evidence)

            #expect(decoded.artifact == "swift-querying")
            #expect(decoded.challenge == challenge)
            #expect(decoded.socketPath == socketPath)
            #expect(decoded.serverProcessID == (try await owner.serverProcessID()))
            #expect(try await owner.serverProcessID() != nil)
        }
    }

    @Test("the three listings answer about a real server")
    func theThreeListings() async throws {
        let route = try arenaRoute(environment: ProcessInfo.processInfo.environment)
        if case let .arena(socketPath, _) = route {
            let server = try #require(try arenaServer(for: route))
            try await assertThreeListings(on: server)
            let evidence = try await arenaEvidence(for: server, requestedSocket: socketPath)
            print("LIBTMUX_ARENA_EVIDENCE=\(String(decoding: evidence, as: UTF8.self))")
            return
        }

        try await withTmuxServer { server in
            try await assertThreeListings(on: server)
        }
    }

    @Test("a pane reports what is running in it and where")
    func panesReportTheirCommandAndPath() async throws {
        try await withTmuxServer { server in
            let panes = try await readWhatEachPaneIsDoing(server)
            let pane = try #require(panes.first)
            #expect(!pane.currentCommand.isEmpty)
            #expect(pane.currentPath.hasPrefix("/"))
        }
    }

    @Test("asking before acting reaches the server on both branches")
    func askingBeforeActingReachesTheServer() async throws {
        try await withTmuxServer { server in
            // Called either side of the session existing, so the guard is
            // exercised both ways; neither call is redundant.
            try await askBeforeActing(server)
            _ = try await server.newSession(named: "work")
            try await askBeforeActing(server)
        }
    }

    @Test("a command the library does not model still answers")
    func unmodelledCommandsStillAnswer() async throws {
        try await withTmuxServer { server in
            let text = try await anythingTheLibraryDoesNotModel(server)
            // Detached server, so there is no client to name a terminal — what
            // matters is that tmux answered rather than the call throwing.
            #expect(!text.contains("unknown command"))
        }
    }
}
