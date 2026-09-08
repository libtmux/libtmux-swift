import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("paste_text cleanup", .timeLimit(.minutes(5)))
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

    @Test(
        "cleanup failure does not replace the primary paste operation failure",
        arguments: PrimaryPasteFailure.allCases
    )
    func primaryFailureWinsCleanupFailure(_ primary: PrimaryPasteFailure) async throws {
        try await withTmuxServer { fixture in
            let transport = FailingPasteCleanupTransport(primaryFailure: primary)
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )

            do {
                _ = try await tools.call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "paneId": .string(pane.id.rawValue),
                            "text": .string("primary failure"),
                        ])
                    )
                )
                Issue.record("paste failure was reported as success")
            } catch let error as ToolError {
                #expect(error.description.contains(primary.reason))
                #expect(error.description.contains("cleanup rejected"))
            }

            if let failedBuffer = await transport.failedBuffer {
                try? await fixture.deleteBuffer(named: failedBuffer)
            }
        }
    }

    @Test("cancellation cannot cancel private-buffer cleanup")
    func cancellationStillCleansBuffer() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let transport = ControlledPasteCleanupTransport(cleanup: .normal)
            let tools = TmuxTools(
                server: Server(
                    endpoint: fixture.endpoint,
                    tmuxExecutable: fixture.tmuxExecutable,
                    transport: transport
                ),
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )
            let submission = Task {
                try await tools.call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "paneId": .string(pane.id.rawValue),
                            "text": .string("cancelled paste"),
                        ])
                    )
                )
            }
            #expect(try await waitUntil { await transport.finalPreflightBlocked })
            submission.cancel()
            await transport.releasePreflight()

            await #expect(throws: ToolError.self) { try await submission.value }
            #expect(try await waitUntil { await transport.cleanupStarted })
            #expect(!(await transport.cleanupObservedCancellation))
            #expect(
                try await fixture.buffers().contains { $0.name.hasPrefix("libtmux-mcp-") }
                    == false)
        }
    }

    @Test("private-buffer cleanup has a wall-clock bound")
    func cleanupIsBounded() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let transport = ControlledPasteCleanupTransport(cleanup: .waitForCancellation)
            let completion = CompletionFlag()
            let tools = TmuxTools(
                server: Server(
                    endpoint: fixture.endpoint,
                    tmuxExecutable: fixture.tmuxExecutable,
                    transport: transport
                ),
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )
            let submission = Task {
                do {
                    let outcome = try await tools.call(
                        ToolCall(
                            name: "paste_text",
                            arguments: .object([
                                "paneId": .string(pane.id.rawValue),
                                "text": .string("bounded cleanup"),
                            ])
                        )
                    )
                    await completion.finish()
                    return Result<ToolOutcome, ToolError>.success(outcome)
                } catch let error as ToolError {
                    await completion.finish()
                    return Result<ToolOutcome, ToolError>.failure(error)
                } catch {
                    await completion.finish()
                    return Result<ToolOutcome, ToolError>.failure(
                        .internalFailure(String(describing: error))
                    )
                }
            }
            #expect(try await waitUntil { await transport.finalPreflightBlocked })
            await transport.releasePreflight()
            #expect(try await waitUntil { await transport.cleanupStarted })
            try await Task.sleep(for: .milliseconds(1_500))
            let finishedWithinBound = await completion.finished
            if !finishedWithinBound { await transport.releaseCleanup() }
            let result = await submission.value

            #expect(finishedWithinBound)
            if case .failure(let error) = result {
                #expect(error.description.contains("paste buffer cleanup timed out"))
            } else {
                Issue.record("hung cleanup was reported as success")
            }
            if let buffer = await transport.stagedBuffer {
                try? await fixture.deleteBuffer(named: buffer)
            }
        }
    }
}

private actor CompletionFlag {
    private(set) var finished = false

    func finish() { finished = true }
}

private enum ControlledCleanupBehavior: Sendable {
    case normal
    case waitForCancellation
}

private actor ControlledPasteCleanupTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let cleanup: ControlledCleanupBehavior
    private var listPaneCount = 0
    private var preflightReleased = false
    private var cleanupReleased = false
    private(set) var finalPreflightBlocked = false
    private(set) var cleanupStarted = false
    private(set) var cleanupObservedCancellation = false
    private(set) var stagedBuffer: String?

    init(cleanup: ControlledCleanupBehavior) {
        self.cleanup = cleanup
    }

    func releasePreflight() { preflightReleased = true }
    func releaseCleanup() { cleanupReleased = true }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains("set-buffer"),
            let nameIndex = arguments.firstIndex(of: "-b"),
            arguments.indices.contains(nameIndex + 1)
        {
            stagedBuffer = arguments[nameIndex + 1]
        }
        if arguments.contains("list-panes") {
            listPaneCount += 1
            if listPaneCount == 2 {
                finalPreflightBlocked = true
                while !preflightReleased { try? await Task.sleep(for: .milliseconds(5)) }
                if Task.isCancelled { throw .cancelled }
            }
        }
        if arguments.contains("delete-buffer") {
            cleanupStarted = true
            if cleanup == .waitForCancellation {
                while !Task.isCancelled && !cleanupReleased {
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            cleanupObservedCancellation = Task.isCancelled
            if Task.isCancelled { throw .cancelled }
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}

enum PrimaryPasteFailure: String, CaseIterable, Sendable {
    case setBuffer = "set-buffer"
    case paste = "paste-buffer"

    var reason: String { "\(rawValue) rejected" }
}

private actor FailingPasteCleanupTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let primaryFailure: PrimaryPasteFailure?
    private(set) var failedBuffer: String?
    private(set) var listPaneCount = 0
    private(set) var bufferMutationCount = 0
    private(set) var pasteCount = 0

    init(primaryFailure: PrimaryPasteFailure? = nil) {
        self.primaryFailure = primaryFailure
    }

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
        if let primaryFailure,
            arguments.contains(where: { $0.contains(primaryFailure.rawValue) })
        {
            throw .invocationFailed(reason: primaryFailure.reason)
        }
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
