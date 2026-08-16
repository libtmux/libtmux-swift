import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("streaming", .timeLimit(.minutes(1)))
struct StreamingTests {
    @Test("the documented stream reports pane output as it happens")
    func theDocumentedStreamReportsOutput() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "work")

            async let watched = beingToldRatherThanAsking(server)

            // `%output` is only reported for a session the connection is
            // attached to, so anything sent before the attach is simply missed.
            // The example attaches inside itself, leaving no moment out here
            // that is known to be after it — so this keeps sending until the
            // watcher has its answer rather than sending once and racing it.
            let poking = Task {
                while !Task.isCancelled {
                    _ = try? await server.run(
                        TmuxCommand("send-keys", ["-t", "work", "echo hello", "Enter"])
                    )
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let seen = try await watched
            poking.cancel()

            // The example answers with the first notification it sees, and
            // which one that is belongs to the shell — an echo of the command
            // can arrive before the command's own output. So this asserts that
            // the connection reported without being asked, not what it said.
            let reported = try #require(seen, "the connection reported no output")
            #expect(!reported.isEmpty)
        }
    }
}
