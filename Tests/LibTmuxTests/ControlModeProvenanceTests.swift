import Testing
import TmuxFixture

@testable import LibTmux

@Suite("control connection provenance", .timeLimit(.minutes(1)))
struct ControlModeProvenanceTests {
    @Test("a stale attachment never enters the connection body")
    func staleAttachmentNeverEntersBody() async throws {
        try await withTmuxServer { server in
            let stale = try #require(try await server.sessions().first)
            _ = try await server.run(TmuxCommand("kill-server"))
            _ = try await server.run(
                TmuxCommand("new-session", ["-d", "-s", "replacement"])
            )

            let entered = EnteredBody()
            await #expect(throws: TmuxError.serverRestarted) {
                try await server.connected(
                    attachingTo: stale.id,
                    expecting: stale.incarnation
                ) { _, _ in
                    await entered.mark()
                }
            }
            #expect(await !entered.value)
        }
    }
}

private actor EnteredBody {
    private(set) var value = false

    func mark() { value = true }
}
