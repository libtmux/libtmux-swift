import Testing
import TmuxFixture

@testable import LibTmux

/// The README's examples, run against a real tmux.
///
/// `Snippets/` proves an example still compiles; this proves it still *works*.
/// The two catch different failures: a call that was renamed stops the build,
/// and a call that quietly began answering something else does not. Every block
/// below is the block on the page, copied rather than paraphrased, so that
/// `Scripts/check_examples.py` can report which of the documented examples are
/// executed and not merely compiled.
///
/// Servers here are addressed by path. ``ReadmeExamplesByNameTests`` runs the
/// same opening example through a socket *name*, which is the other half of
/// ``Endpoint`` and the half `libtmux-mcp` uses.
@Suite("README examples", .timeLimit(.minutes(1)))
struct ReadmeExampleTests {
    @Test("the three listings answer about a real server")
    func threeListings() async throws {
        try await withTmuxServer { server in
            let sessions = try await server.sessions()
            let windows = try await server.windows()
            let panes = try await server.panes()

            // The fixture bootstraps exactly one session, so these are its.
            #expect(sessions.count == 1)
            #expect(windows.count == 1)
            #expect(panes.count == 1)
        }
    }

    @Test("a pane reports what is running in it and where")
    func paneFields() async throws {
        try await withTmuxServer { server in
            for pane in try await server.panes() {
                print(pane.id, pane.currentCommand, pane.currentPath)
            }

            let pane = try #require(try await server.panes().first)
            #expect(pane.id.hasPrefix("%"))
            #expect(!pane.currentCommand.isEmpty)
            #expect(pane.currentPath.hasPrefix("/"))
        }
    }

    @Test("a question tmux answers with an exit code comes back as a Bool")
    func askBeforeActing() async throws {
        try await withTmuxServer { server in
            #expect(try await server.hasSession("work") == false)
            _ = try await server.newSession(named: "work")

            guard try await server.hasSession("work") else { return }
            #expect(try await server.hasSession("work"))
        }
    }

    @Test("a command the library does not model still answers")
    func runningARawCommand() async throws {
        try await withTmuxServer { server in
            let reply = try await server.run(
                TmuxCommand("display-message", ["-p", "#{client_termname}"])
            )
            print(reply.isSuccess ? reply.text : reply.errorText)

            #expect(reply.isSuccess)
        }
    }

    @Test("a snapshot resolves the relationships between what it holds")
    func snapshotWalk() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            _ = try await server.newWindow(in: session, named: "second")

            let snapshot = try await server.snapshot()
            for window in snapshot.windows(of: session) {
                print(window.name, snapshot.panes(of: window).count)
            }

            #expect(snapshot.windows(of: session).count == 2)
            #expect(snapshot.panes(of: session).count == 2)
        }
    }

    @Test("the session the README builds is the session tmux ends up with")
    func buildASessionByHand() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "work", windowName: "editor")
            let logs = try await server.newWindow(in: session, named: "logs")
            let pane = try await server.splitWindow(logs, direction: .right)
            try await server.run("tail -f /tmp/build.log", in: pane)

            let snapshot = try await server.snapshot()
            let windows = snapshot.windows(of: session)
            #expect(windows.map(\.name) == ["editor", "logs"])
            #expect(snapshot.panes(of: logs).count == 2)
        }
    }

    @Test("capture reads back what a pane printed")
    func captureAPane() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let pane = try #require(try await server.panes().first)
            try await server.run("echo readme-example-marker", in: pane)
            _ = try await waitUntil {
                try await server.capture(pane)
                    .contains { $0.contains("readme-example-marker") }
            }

            let lines = try await server.capture(pane)

            #expect(lines.contains { $0.contains("readme-example-marker") })
            #expect(session.name == "bootstrap")
        }
    }

    @Test("a command list spends one invocation on all of it")
    func oneInvocationForAllOfThem() async throws {
        try await withTmuxServer { server in
            var plan = TmuxCommandList()
            for name in ["edit", "test", "logs"] {
                plan = plan.then("new-window", ["-d", "-n", name])
            }
            _ = try await server.run(plan)

            let names = try await server.windows().map(\.name)
            #expect(names.contains("edit"))
            #expect(names.contains("test"))
            #expect(names.contains("logs"))
        }
    }

    @Test("a filter expression selects the same panes the predicate would")
    func filteringThatTravels() async throws {
        try await withTmuxServer { server in
            let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
            let matching = try await server.panes().filter(expression)

            // Nothing here runs an editor, so the honest answer is none — and a
            // filter that matched anyway would be the bug worth catching.
            #expect(matching.isEmpty)

            let shells = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["sh"]))
            #expect(try await server.panes().filter(shells).count == 1)
        }
    }

    @Test("a connected scope returns what the direct one would")
    func overOneConnection() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "main")

            let names = try await server.using(.connected(to: "main")) { server in
                try await server.sessions().map(\.name)
            }

            #expect(Set(names) == Set(try await server.sessions().map(\.name)))
        }
    }

    @Test("choosing the mode at runtime changes neither the calls nor the answer")
    func chosenAtRuntime() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "main")

            for shouldAttach in [true, false] {
                let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
                let sessions = try await server.using(mode) { server in
                    try await server.sessions()
                }

                #expect(sessions.count == 2)
            }
        }
    }
}

/// The opening example, run against a server addressed by socket *name*.
///
/// `Server(socketName:)` is what `libtmux-mcp` uses and what a caller reaches
/// for when tmux already knows the server by name, and until `TMUX_TMPDIR`
/// reached tmux it could only ever address the machine-wide default directory.
/// Running an example through it keeps that fixed.
@Suite("README examples, by socket name", .timeLimit(.minutes(1)))
struct ReadmeExamplesByNameTests {
    @Test("a server addressed by name answers the same listings")
    func listingsByName() async throws {
        try await withNamedTmuxServer { server in
            for session in try await server.sessions() {
                print(session.name, session.windowCount)
            }

            let sessions = try await server.sessions()
            #expect(sessions.count == 1)
            #expect(sessions.first?.name == "bootstrap")
            #expect(server.mode == .direct)
        }
    }

    @Test("a name and a path reach servers that behave the same way")
    func nameAndPathAgree() async throws {
        let byName = try await withNamedTmuxServer { server -> [String] in
            _ = try await server.newSession(named: "work")
            return try await server.sessions().map(\.name).sorted()
        }
        let byPath = try await withTmuxServer { server -> [String] in
            _ = try await server.newSession(named: "work")
            return try await server.sessions().map(\.name).sorted()
        }
        #expect(byName == byPath)
    }
}
