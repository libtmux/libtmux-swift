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
}
