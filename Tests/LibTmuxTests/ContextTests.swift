import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("finding the tmux you are inside", .timeLimit(.minutes(1)))
struct ContextTests {
    @Test(
        "what tmux puts in the environment reads back as where it is",
        arguments: [
            ("/tmp/x/s,123,0", "/tmp/x/s", 123, "$0"),
            ("/tmp/x/s,4,17", "/tmp/x/s", 4, "$17"),
            // Only the path may hold a comma, so it is what the extra one
            // belongs to.
            ("/tmp/od,d/s,9,2", "/tmp/od,d/s", 9, "$2"),
        ]
    )
    func contextParses(_ value: String, _ path: String, _ pid: Int, _ session: String) throws {
        let context = try #require(TmuxContext(parsing: value))
        #expect(context.socketPath == path)
        #expect(context.serverProcessID == pid)
        #expect(context.sessionID == session)
    }

    @Test(
        "anything that is not that shape reports nothing",
        arguments: ["", "/tmp/s", "/tmp/s,1", ",1,2", "/tmp/s,x,2", "/tmp/s,1,$2", "/tmp/s,1,"]
    )
    func nonContextsAreRefused(_ value: String) {
        #expect(TmuxContext(parsing: value) == nil)
    }

    @Test("a process outside tmux has no context")
    func outsideTmuxThereIsNone() {
        #expect(TmuxContext.current(environment: [:]) == nil)
        #expect(TmuxContext.current(environment: ["TMUX": ""]) == nil)
    }

    @Test("the context a pane is given leads back to the server that started it")
    func contextLeadsBackToItsServer() async throws {
        try await withTmuxServer { server in
            // The pane runs the question as its own command rather than being
            // typed into. A pane's shell is whichever one the machine gives it,
            // and keys sent before that shell has drawn a prompt are swallowed
            // — so typing races the shell's startup, and loses on a busy
            // machine. What tmux starts a pane with runs the moment the pane
            // exists. `sleep` only keeps the pane alive long enough to read.
            let created = try await server.run(
                TmuxCommand(
                    "new-session",
                    ["-d", "-s", "inside", #"printf '[%s]\n' "$TMUX"; sleep 300"#]
                )
            )
            #expect(created.isSuccess, Comment(rawValue: created.errorText))
            let session = try #require(
                try await server.sessions().first { $0.name == "inside" }
            )
            let pane = try #require(
                try await server.snapshot().panes(of: session).first
            )

            var reported = ""
            let arrived = try await waitUntil {
                let lines = try await server.capture(pane)
                if let line = lines.last(where: { $0.contains("[") && $0.contains(",") }),
                    let start = line.firstIndex(of: "["),
                    let end = line.lastIndex(of: "]")
                {
                    reported = String(line[line.index(after: start)..<end])
                    return !reported.isEmpty
                }
                return false
            }
            #expect(arrived)

            let context = try #require(TmuxContext(parsing: reported))
            // It names this server, not merely a plausible one.
            #expect(context.serverProcessID == (try await server.serverProcessID()))
            #expect(context.sessionID == session.id)

            // And the socket it names is reachable, answering as the same
            // server this test has been talking to.
            let reached = try context.server(tmuxExecutable: tmuxExecutablePath())
            #expect(try await reached.sessions().contains { $0.id == session.id })
        }
    }
}
