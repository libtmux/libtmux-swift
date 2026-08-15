import Testing
import TmuxFixture

@testable import LibTmux

@Suite("command lists")
struct CommandListTests {
    @Test("the separator is its own argument, so a semicolon in a value is data")
    func separatorIsItsOwnArgument() {
        let list = TmuxCommandList()
            .then("new-session", ["-d", "-s", "a;b"])
            .then("list-sessions")
        #expect(
            list.argumentVector
                == ["new-session", "-d", "-s", "a;b", ";", "list-sessions"]
        )
    }

    @Test("chaining builds a value and leaves the original alone")
    func chainingBuildsAValue() {
        let base = TmuxCommandList([TmuxCommand("list-sessions")])
        let extended = base.then("list-windows")
        #expect(base.commands.count == 1)
        #expect(extended.commands.count == 2)
    }

    @Test("an empty list is a no-op that never invokes tmux")
    func emptyListIsANoOp() async throws {
        // A deliberately unusable executable: reaching it would throw.
        let server = try Server(socketPath: "/tmp/lt-empty", tmuxExecutable: "/nonexistent")
        let reply = try await server.run(TmuxCommandList())
        #expect(reply.isSuccess)
        #expect(reply.standardOutput.isEmpty)
    }

    @Test("a list runs every command in one invocation")
    func listRunsEveryCommandInOneInvocation() async throws {
        try await withTmuxServer { server in
            let reply = try await server.run(
                TmuxCommandList()
                    .then("new-window", ["-d", "-t", "bootstrap"])
                    .then("new-window", ["-d", "-t", "bootstrap"])
                    .then("new-session", ["-d", "-s", "second"])
            )
            #expect(reply.isSuccess, Comment(rawValue: reply.errorText))

            let snapshot = try await server.snapshot()
            #expect(snapshot.sessions.count == 2)
            #expect(snapshot.windows.count == 4)
        }
    }

    @Test("a failing command stops the list and reports why")
    func failingCommandStopsTheList() async throws {
        try await withTmuxServer { server in
            let reply = try await server.run(
                TmuxCommandList()
                    .then("new-window", ["-d", "-t", "bootstrap"])
                    .then("kill-session", ["-t", "no-such-session"])
                    .then("new-session", ["-d", "-s", "never"])
            )
            #expect(!reply.isSuccess)
            #expect(!reply.errorText.isEmpty)

            // The prefix before the failure ran; the suffix did not.
            let snapshot = try await server.snapshot()
            #expect(snapshot.windows.count == 2)
            #expect(!snapshot.sessions.contains { $0.name == "never" })
        }
    }

    @Test("a list answers the same over a connection as it does in a process")
    func listAnswersTheSameInEitherMode() async throws {
        try await withTmuxServer { server in
            // tmux answers a `;` list with one block per command, where a
            // process concatenates the lot onto one stream. A mode is supposed
            // to change how work travels and nothing else, so the two spellings
            // have to hand back the same bytes.
            let list = TmuxCommandList()
                .then("display-message", ["-p", "one"])
                .then("display-message", ["-p", "two"])
                .then("display-message", ["-p", "three"])

            let direct = try await server.run(list)
            let connected = try await server.using(.connected(to: "bootstrap")) {
                server in
                try await server.run(list)
            }

            #expect(direct.isSuccess, Comment(rawValue: direct.errorText))
            #expect(connected.isSuccess, Comment(rawValue: connected.errorText))
            #expect(
                direct.text == connected.text,
                Comment(
                    rawValue: "direct=\(direct.text.debugDescription) "
                        + "connected=\(connected.text.debugDescription)"
                )
            )
        }
    }

    @Test("a failing list is a failure over a connection too")
    func failingListIsAFailureOverAConnection() async throws {
        try await withTmuxServer { server in
            let list = TmuxCommandList()
                .then("display-message", ["-p", "ran"])
                .then("kill-session", ["-t", "no-such-session"])
                .then("display-message", ["-p", "never"])

            let reply = try await server.using(.connected(to: "bootstrap")) { server in
                try await server.run(list)
            }

            // The first command succeeded; the reply is about the whole list.
            #expect(!reply.isSuccess)
            #expect(!reply.errorText.isEmpty)
        }
    }

    @Test("a list leaves nothing behind for the next command to collect")
    func listLeavesNothingForTheNextCommand() async throws {
        try await withTmuxServer { server in
            try await server.using(.connected(to: "bootstrap")) { server in
                var list = TmuxCommandList()
                for index in 0..<20 {
                    list = list.then("display-message", ["-p", "\(index)"])
                }
                _ = try await server.run(list)

                // Nineteen unclaimed replies would be waiting here, and the
                // first of them would answer this call instead of tmux's own
                // reply to it.
                let sessions = try await server.sessions()
                #expect(
                    sessions.contains { $0.name == "bootstrap" },
                    "\(sessions.map(\.name))"
                )
            }
        }
    }
}
