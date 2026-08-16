import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("querying", .timeLimit(.minutes(1)))
struct QueryingTests {
    @Test("the three listings answer about a real server")
    func theThreeListings() async throws {
        try await withTmuxServer { server in
            let (sessions, windows, panes) = try await askWhatExists(server)
            #expect(sessions == 1)
            #expect(windows == 1)
            #expect(panes == 1)
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
            // No `work` session yet: the guard takes the early return.
            try await askBeforeActing(server)
            _ = try await server.newSession(named: "work")
            // Now it exists, so the guard falls through to the other branch.
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
