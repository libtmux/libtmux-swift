import Testing
import TmuxFixture

@testable import LibTmux

@Suite("control mode concurrency", .timeLimit(.minutes(1)))
struct ControlModeConcurrencyTests {
    @Test("concurrent sends each receive their own reply")
    func concurrentSendsAreAttributedCorrectly() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                // Each command prints a distinct marker. If replies are matched
                // by arrival order rather than to their command, some caller
                // gets another's output.
                let replies = try await withThrowingTaskGroup(
                    of: (Int, ControlReply).self
                ) { group in
                    for index in 0..<32 {
                        group.addTask {
                            let reply = try await control.send(
                                TmuxCommand("display-message", ["-p", "marker-\(index)"])
                            )
                            return (index, reply)
                        }
                    }
                    var out: [(Int, ControlReply)] = []
                    for try await pair in group { out.append(pair) }
                    return out
                }
                for (index, reply) in replies {
                    #expect(
                        reply.lines == ["marker-\(index)"],
                        Comment(rawValue: "command \(index) got \(reply.lines)")
                    )
                }
            }
        }
    }

    @Test("hook replies do not answer the next command")
    func hookRepliesAreDrained() async throws {
        try await withTmuxServer { server in
            let started = "control-hook-started"
            let release = "control-hook-release"
            let set = try await server.setHook(
                "after-display-message",
                to: "wait-for -S \(started) ; wait-for \(release) ; "
                    + "display-message -p hook-output"
            )
            #expect(set.isSuccess, Comment(rawValue: set.errorText))

            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let first = Task {
                    try await control.send(
                        TmuxCommand("display-message", ["-p", "first-reply"])
                    )
                }
                _ = try await server.run(TmuxCommand("wait-for", [started]))
                let next = Task {
                    try await control.send(
                        TmuxCommand("display-message", ["-p", "next-reply"])
                    )
                }
                _ = try await server.run(TmuxCommand("wait-for", ["-S", release]))

                #expect(try await first.value.lines == ["first-reply"])
                #expect(try await next.value.lines == ["next-reply"])
            }
        }
    }

    @Test("protocol-looking command output stays in its reply")
    func protocolLookingOutputStaysInItsReply() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.respawn(
                pane,
                running: ["sh", "-c", "printf '%s\\n' '%end literal'; sleep 5"]
            )
            let printed = try await waitUntil {
                try await server.capture(pane).contains("%end literal")
            }
            #expect(printed)

            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let first = try await control.send(
                    TmuxCommand("capture-pane", ["-p", "-t", pane.id.rawValue])
                )
                #expect(first.lines.contains("%end literal"))

                let next = try await control.send(
                    TmuxCommand("display-message", ["-p", "still-open"])
                )
                #expect(next.lines == ["still-open"])
            }
        }
    }
}
