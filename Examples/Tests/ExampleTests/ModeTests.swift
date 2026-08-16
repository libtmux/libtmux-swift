import ExampleCode
import LibTmux
import Testing
import TmuxFixture
import TmuxWorkspace

/// The mode examples all attach to a session called `main`, which the fixture's
/// bootstrap server does not have. Creating it is setup rather than part of the
/// example, so it lives here.
private func withMain<Result>(
    _ body: (Server) async throws -> Result
) async throws -> Result {
    try await withTmuxServer { server in
        _ = try await server.newSession(named: "main")
        return try await body(server)
    }
}

@Suite("choosing a mode", .timeLimit(.minutes(1)))
struct ModeTests {
    @Test("a connected scope returns what the direct one would")
    func aConnectedScopeAgreesWithDirect() async throws {
        try await withMain { server in
            let overConnection = try await overOneConnection(server)
            let directly = try await server.sessions().map(\.name)
            #expect(overConnection.sorted() == directly.sorted())
        }
    }

    @Test("choosing the mode at runtime changes neither the calls nor the answer")
    func choosingAtRuntimeChangesNothing() async throws {
        try await withMain { server in
            let attached = try await chosenAtRuntime(server, true).map(\.name)
            let direct = try await chosenAtRuntime(server, false).map(\.name)
            #expect(attached.sorted() == direct.sorted())
        }
    }

    @Test("two listings pipelined over one connection both answer")
    func aPipelinedBatchAnswersBoth() async throws {
        try await withMain { server in
            let (sessions, panes) = try await aPipelinedBatch(server)
            #expect(sessions == (try await server.sessions().count))
            #expect(panes == (try await server.panes().count))
        }
    }

    @Test("a workspace built over a connection is the session tmux ends up with")
    func aWorkspaceBuildsOverAConnection() async throws {
        try await withMain { server in
            let workspace = describeAWorkspaceInSwift()
            let session = try await aConsumerThatNeverMentionsAMode(server, workspace)
            #expect(session.name == "work")
            #expect(try await server.hasSession("work"))
        }
    }
}
