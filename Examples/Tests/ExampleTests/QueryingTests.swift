import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture

private let artifactID = "swift-querying"

private func assertThreeListings(on server: Server) async throws {
    let (sessions, windows, panes) = try await askWhatExists(server)
    try #require(sessions == 1)
    try #require(windows == 1)
    try #require(panes == 1)
}

@Suite("querying", .timeLimit(.minutes(1)))
struct QueryingTests {
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
                    "LIBTMUX_ARENA_ARTIFACT": artifactID,
                    "LIBTMUX_SOCKET_PATH": socketPath,
                    "LIBTMUX_TMUX_BIN": owner.tmuxExecutable,
                ],
                artifact: artifactID
            )
            let borrowed = try #require(try arenaServer(for: route))

            #expect(borrowed.tmuxExecutable == owner.tmuxExecutable)
            try await assertThreeListings(on: borrowed)
            let evidence = try await arenaEvidence(
                for: borrowed,
                requestedSocket: socketPath,
                artifact: artifactID
            )
            let decoded = try JSONDecoder().decode(ArenaEvidence.self, from: evidence)

            #expect(decoded.artifact == artifactID)
            #expect(decoded.challenge == challenge)
            #expect(decoded.socketPath == socketPath)
            #expect(decoded.serverProcessID == (try await owner.serverProcessID()))
            #expect(try await owner.serverProcessID() != nil)
        }
    }

    @Test("the three listings answer about a real server")
    func theThreeListings() async throws {
        let route = try arenaRoute(
            environment: ProcessInfo.processInfo.environment,
            artifact: artifactID
        )
        if case let .arena(socketPath, _) = route {
            let server = try #require(try arenaServer(for: route))
            try await assertThreeListings(on: server)
            let evidence = try await arenaEvidence(
                for: server,
                requestedSocket: socketPath,
                artifact: artifactID
            )
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
