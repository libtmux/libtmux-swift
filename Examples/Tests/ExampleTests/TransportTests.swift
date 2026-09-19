import ExampleCode
import LibTmux
import Testing

@Suite("standing in for tmux", .timeLimit(.minutes(1)))
struct TransportTests {
    @Test("a consumer's own transport answers without a tmux on the machine")
    func aStubTransportAnswers() async throws {
        // No fixture, no socket, no tmux: this suite reaches the library the
        // way a consumer does, so it also proves the seam is public.
        let names = try await withoutATmuxOnTheMachine()

        #expect(names == ["work"])
    }
}
