import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("paste_text cleanup", .timeLimit(.minutes(1)))
struct PasteTextCleanupTests {
    @Test("empty text without Enter is a guarded buffer-free no-op")
    func emptyPasteIsBufferFree() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let transport = FailingPasteCleanupTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )

            let outcome = try await tools.call(
                ToolCall(
                    name: "paste_text",
                    arguments: .object([
                        "enter": .bool(false),
                        "paneId": .string(pane.id.rawValue),
                        "text": .string(""),
                    ])
                )
            )

            #expect(outcome.structured["characters"]?.intValue == 0)
            #expect(await transport.listPaneCount == 1)
            #expect(await transport.bufferMutationCount == 0)
            #expect(await transport.pasteCount == 0)

            let reservation = try #require(await TmuxTools.paneRuns.reserve([pane]))
            let refused: Bool
            do {
                _ = try await tools.call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "paneId": .string(pane.id.rawValue), "text": .string(""),
                        ])
                    )
                )
                refused = false
            } catch is ToolError {
                refused = true
            }
            await TmuxTools.paneRuns.release(reservation)
            #expect(refused)
            #expect(await transport.listPaneCount == 2)
            #expect(await transport.bufferMutationCount == 0)
            #expect(await transport.pasteCount == 0)
        }
    }

    @Test("a private staging-buffer cleanup failure is reported")
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
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )

            await #expect(
                throws: ToolError.tmux(.invocationFailed(reason: "cleanup rejected"))
            ) {
                try await tools.call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "paneId": .string(pane.id.rawValue),
                            "text": .string(text),
                        ])
                    )
                )
            }

            #expect(try await waitUntil { await transport.failedBuffer != nil })
            let failedBuffer = try #require(await transport.failedBuffer)
            #expect(try await fixture.buffer(named: failedBuffer) == text)
            try await fixture.deleteBuffer(named: failedBuffer)
        }
    }
}

private actor FailingPasteCleanupTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private(set) var failedBuffer: String?
    private(set) var listPaneCount = 0
    private(set) var bufferMutationCount = 0
    private(set) var pasteCount = 0

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains("list-panes") { listPaneCount += 1 }
        if arguments.contains("set-buffer") || arguments.contains("delete-buffer") {
            bufferMutationCount += 1
        }
        if arguments.contains(where: { $0.contains("paste-buffer") }) { pasteCount += 1 }
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
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}
