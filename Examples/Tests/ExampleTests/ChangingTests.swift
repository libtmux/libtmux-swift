import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("changing", .timeLimit(.minutes(1)))
struct ChangingTests {
    @Test("the session the README builds is the session tmux ends up with")
    func theDocumentedSessionIsBuilt() async throws {
        try await withTmuxServer { server in
            let pane = try await buildASessionByHand(server)

            let snapshot = try await server.snapshot()
            #expect(snapshot.sessions.contains { $0.name == "work" })

            let work = try #require(snapshot.sessions.first { $0.name == "work" })
            let windows = snapshot.windows(of: work)
            #expect(windows.map(\.name).sorted() == ["editor", "logs"])

            let logs = try #require(windows.first { $0.name == "logs" })
            let panes = snapshot.panes(of: logs)
            #expect(panes.count == 2)
            #expect(panes.contains { $0.id == pane.id })
        }
    }

    @Test("capture reads back what a pane printed")
    func captureReadsBackWhatWasPrinted() async throws {
        try await withTmuxServer { server in
            let marker = "libtmux-capture-marker"
            let pane = try #require(try await server.panes().first)
            _ = try await server.run(
                TmuxCommand("send-keys", ["-t", pane.id.rawValue, "echo \(marker)", "Enter"])
            )
            let arrived = try await waitUntil {
                try await readBackWhatAPanePrinted(server, pane)
                    .contains { $0.contains(marker) }
            }
            #expect(arrived, "the marker never reached the pane's history")
        }
    }

    @Test("a command list spends one invocation on all of it")
    func aCommandListSpendsOneInvocation() async throws {
        try await withTmuxServer { server in
            try await spendOneProcessOnAllOfIt(server)
            let names = try await server.windows().map(\.name)
            for wanted in ["edit", "test", "logs"] {
                #expect(names.contains(wanted), "window \(wanted) was not created")
            }
        }
    }
}
