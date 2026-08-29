import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("paste_text cleanup", .timeLimit(.minutes(1)))
struct PasteTextCleanupTests {
    @Test("a staging-buffer cleanup failure is reported")
    func cleanupFailureIsReported() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingPasteCleanupTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let text = "must not remain in paste history"

            await #expect(
                throws: ToolError.tmux(.invocationFailed(reason: "cleanup rejected"))
            ) {
                try await TmuxTools(server: server, tier: .mutating).call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                            "text": .string(text),
                        ])
                    )
                )
            }

            #expect(
                try await waitUntil {
                    await transport.failedBuffer != nil
                }
            )
            let failedBuffer = try #require(await transport.failedBuffer)
            #expect(try await fixture.buffer(named: failedBuffer) == text)
            try await fixture.deleteBuffer(named: failedBuffer)
        }
    }
}

private actor FailingPasteCleanupTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private(set) var failedBuffer: String?

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        if let command = arguments.firstIndex(of: "delete-buffer"),
            arguments.indices.contains(command + 2),
            arguments[command + 1] == "-b"
        {
            failedBuffer = arguments[command + 2]
            return TmuxReply(
                standardOutput: [],
                standardError: Array("cleanup rejected".utf8),
                exitCode: 1
            )
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }
}
