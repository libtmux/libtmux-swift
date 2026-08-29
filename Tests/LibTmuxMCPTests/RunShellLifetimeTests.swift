import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("run_shell lifetime", .timeLimit(.minutes(2)))
struct RunShellLifetimeTests {
    @Test("a command rejected before dispatch releases the pane lease")
    func preDispatchRejectionReleasesPaneLease() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let tools = TmuxTools(server: server, tier: .mutating)

            do {
                _ = try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string(String(repeating: "x", count: 20_000)),
                        ])
                    )
                )
                Issue.record("oversized command was accepted")
            } catch let ToolError.tmux(.commandTooLarge(actualBytes, maximumBytes)) {
                #expect(actualBytes > maximumBytes)
            } catch {
                Issue.record("unexpected error: \(error)")
            }

            let next = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(paneRef),
                        "command": .string("printf 'lease-released\\n'"),
                        "timeout": .number(2),
                    ])
                )
            ).decode(RunShellResult.self)
            #expect(next.output == ["lease-released"])
        }
    }

    @Test("a launch failure releases the pane lease")
    func launchFailureReleasesPaneLease() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingRunShellLaunchTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)

            await #expect(
                throws: ToolError.tmux(.processLaunchFailed(reason: "did not spawn"))
            ) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                            "command": .string("printf 'must-not-run\\n'"),
                        ])
                    )
                )
            }
            #expect(!(await tools.paneRuns.isHeld(pane)))
        }
    }

    @Test("a wait transport failure is not reported as a timeout")
    func waitFailureIsPropagated() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingRunShellWaitTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)

            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "wait failed"))) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                            "command": .string("printf 'wait-error\\n'"),
                            "timeout": .number(20),
                        ])
                    )
                )
            }
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
        }
    }

    @Test("cleanup wait failures cannot release a pane that is still running")
    func cleanupWaitFailuresKeepPaneLease() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingRunShellWaitTransport(failures: 3)
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let tools = TmuxTools(server: server, tier: .mutating)
            let nonce = UUID().uuidString
            let started = "libtmux-test-run-shell-started-\(nonce)"
            let release = "libtmux-test-run-shell-release-\(nonce)"
            let first = Task {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string(
                                "\(server.shellInvocation) wait-for -S \(started); "
                                    + "\(server.shellInvocation) wait-for \(release)"
                            ),
                            "timeout": .number(20),
                        ])
                    )
                )
            }

            try await fixture.wait(for: started)
            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "wait failed"))) {
                _ = try await first.value
            }
            #expect(
                try await waitUntil(within: .seconds(1)) {
                    await transport.waitFailureCount >= 2
                }
            )
            #expect(await tools.paneRuns.isHeld(pane))
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string("printf 'must-not-overlap\\n'"),
                            "timeout": .number(0.1),
                        ])
                    )
                )
            }

            try await fixture.signal(release)
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
        }
    }

    @Test("stale cleanup captures cannot release a pane that is still running")
    func staleCleanupCapturesKeepPaneLease() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingRunShellWaitTransport(
                failures: 1,
                staleCaptureFailures: 3
            )
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)
            let release = "libtmux-test-run-shell-release-\(UUID().uuidString)"

            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "wait failed"))) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(
                                WireReferenceCodec.processLocal.reference(to: pane)
                            ),
                            "command": .string(
                                "\(server.shellInvocation) wait-for \(release)"
                            ),
                            "timeout": .number(20),
                        ])
                    )
                )
            }
            #expect(
                try await waitUntil(within: .seconds(2)) {
                    await transport.staleCaptureFailureCount == 3
                }
            )

            let releasedWhileRunning = try await waitUntil(within: .seconds(1)) {
                !(await tools.paneRuns.isHeld(pane))
            }
            #expect(!releasedWhileRunning)

            try await fixture.signal(release)
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
        }
    }

    @Test("removing a pane ends its pending cleanup")
    func paneRemovalEndsPendingCleanup() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingRunShellWaitTransport(failures: 1)
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            _ = try await fixture.split(pane)
            let tools = TmuxTools(server: server, tier: .mutating)

            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "wait failed"))) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(
                                WireReferenceCodec.processLocal.reference(to: pane)
                            ),
                            "command": .string("\(server.shellInvocation) wait-for never"),
                        ])
                    )
                )
            }
            #expect(await tools.paneRuns.isHeld(pane))

            try await fixture.kill(pane)
            #expect(
                try await waitUntil(within: .seconds(2)) {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
        }
    }

    @Test("server departure ends pending cleanup")
    func serverDepartureEndsPendingCleanup() async throws {
        try await withTmuxServer { fixture in
            let transport = FailingRunShellWaitTransport(failures: .max)
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)
            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "wait failed"))) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                            "command": .string(
                                "\(server.shellInvocation) wait-for never"
                            ),
                        ])
                    )
                )
            }

            #expect(
                try await waitUntil(within: .seconds(1)) {
                    await transport.waitFailureCount >= 2
                }
            )
            #expect(await tools.paneRuns.isHeld(pane))
            await transport.departEndpoint()
            #expect(
                try await waitUntil(within: .seconds(5)) {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
            try await fixture.signal("never")
        }
    }

    @Test("a completed run does not erase a capture failure")
    func finalCaptureFailureIsPropagated() async throws {
        try await withTmuxServer { fixture in
            let transport = RunShellCaptureTransport(failingCapture: 2)
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)

            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "capture failed"))) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                            "command": .string("printf 'capture-error\\n'"),
                            "timeout": .number(5),
                        ])
                    )
                )
            }
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
        }
    }

    @Test("a completed run is captured before the next prompt")
    func completedRunIsCapturedBeforePrompt() async throws {
        try await withTmuxServer { fixture in
            let transport = GatedRunShellWaitTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let ready = "libtmux-test-run-shell-prompt-\(UUID().uuidString)"
            let promptEnd = "run-shell-prompt-end"
            let prompt = String(repeating: "p", count: 1_024) + promptEnd
            try await server.run(
                "stty -echo; PS1='\(prompt)'; export PS1; "
                    + "\(server.shellInvocation) wait-for -S \(ready)",
                in: pane
            )
            try await fixture.wait(for: ready)
            #expect(
                try await waitUntil {
                    try await server.capture(pane).contains { $0.contains(promptEnd) }
                }
            )

            let tool = Task {
                try await TmuxTools(server: server, tier: .mutating).call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                            "command": .string("printf 'prompt-safe\\n'"),
                            "max_lines": .number(1),
                            "timeout": .number(5),
                        ])
                    )
                ).decode(RunShellResult.self)
            }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                tool.cancel()
                await transport.finish()
            }

            do {
                await transport.waitUntilHoldingDoneReply()
                #expect(
                    try await waitUntil {
                        try await server.capture(pane).contains { $0.contains("prompt-safe") }
                    }
                )
                await transport.releaseDoneReply()

                let toolResult = await tool.result

                var boundaryIterator = await transport.boundaryEvents().makeAsyncIterator()
                var boundaryEvents: [RunShellBoundaryEvent] = []
                while let event = await boundaryIterator.next() {
                    boundaryEvents.append(event)
                    if event == .releaseSignal { break }
                }
                #expect(boundaryEvents.first == .capture)
                #expect(boundaryEvents.contains(.releaseSignal))

                let result = try toolResult.get()
                #expect(result.output == ["prompt-safe"])
                #expect(!result.linesMissed)
            } catch {
                tool.cancel()
                await transport.finish()
                watchdog.cancel()
                await watchdog.value
                _ = await tool.result
                throw error
            }

            watchdog.cancel()
            await transport.finish()
            await watchdog.value
        }
    }

    @Test("prepare and timeout cleanup bound every pane capture")
    func prepareAndTimeoutCleanupBoundPaneCaptures() async throws {
        try await withTmuxServer { fixture in
            let transport = RunShellCaptureTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)
            let nonce = UUID().uuidString
            let release = "libtmux-test-run-shell-release-\(nonce)"
            let result = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                        "command": .string(
                            "\(server.shellInvocation) wait-for \(release)"
                        ),
                        "timeout": .number(0.1),
                    ])
                )
            ).decode(RunShellResult.self)
            #expect(result.timedOut)

            let cleanupCaptured = try await waitUntil {
                await transport.captureCount >= 3
            }
            let captureLimits = await transport.captureLimits
            try await fixture.signal(release)
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )

            #expect(cleanupCaptured)
            #expect(captureLimits.count >= 3)
            #expect(captureLimits.allSatisfy { $0 == 262_144 })
        }
    }

    @Test("a moving timeout snapshot still reports the timeout")
    func movingTimeoutSnapshotStillReportsTimeout() async throws {
        try await withTmuxServer { fixture in
            let transport = RunShellCaptureTransport(staleCaptureFailures: .max)
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let release = "libtmux-test-run-shell-release-\(UUID().uuidString)"
            let result = try await TmuxTools(server: server, tier: .mutating).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                        "command": .string("\(server.shellInvocation) wait-for \(release)"),
                        "timeout": .number(0.1),
                    ])
                )
            ).decode(RunShellResult.self)

            #expect(result.timedOut)
            #expect(result.output.isEmpty)
            #expect(result.linesMissed)
            try await fixture.signal(release)
        }
    }

    @Test("cancelling after dispatch retains the pane lease until cleanup")
    func cancellationAfterDispatchRetainsPaneLease() async throws {
        try await withTmuxServer { fixture in
            let transport = WithheldRunShellReplyTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let tools = TmuxTools(server: server, tier: .mutating)
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let started = "libtmux-test-run-shell-submitted-\(nonce)"
            let release = "libtmux-test-run-shell-release-\(nonce)"
            let tmux = server.shellInvocation
            let first = Task {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string(
                                "\(tmux) wait-for -S \(started); "
                                    + "\(tmux) wait-for \(release); "
                                    + "printf 'submitted-run-finished\\n'"
                            ),
                            "timeout": .number(20),
                        ])
                    )
                )
            }

            #expect(
                try await waitUntil {
                    await transport.isWithholdingReply
                }
            )
            try await fixture.wait(for: started)
            first.cancel()
            await #expect(throws: ToolError.tmux(.cancelled)) {
                _ = try await first.value
            }

            #expect(await tools.paneRuns.isHeld(pane))
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string("printf 'must-wait-for-submitted-run\\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            }

            try await fixture.signal(release)
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )
        }
    }

    @Test("cancelling a started run retains its pane lease until cleanup")
    func cancellationRetainsPaneLease() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
            let tools = TmuxTools(server: server, tier: .mutating)
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let started = "libtmux-test-run-shell-started-\(nonce)"
            let release = "libtmux-test-run-shell-release-\(nonce)"
            let tmux = server.shellInvocation
            let first = Task {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string(
                                "\(tmux) wait-for -S \(started); "
                                    + "\(tmux) wait-for \(release); "
                                    + "printf 'cancelled-run-finished\\n'"
                            ),
                            "timeout": .number(20),
                        ])
                    )
                )
            }

            try await server.wait(for: started)
            first.cancel()
            await #expect(throws: ToolError.tmux(.cancelled)) {
                _ = try await first.value
            }

            #expect(await tools.paneRuns.isHeld(pane))
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(paneRef),
                            "command": .string("printf 'must-wait-for-cleanup\\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            }

            try await server.signal(release)
            #expect(
                try await waitUntil {
                    !(await tools.paneRuns.isHeld(pane))
                }
            )

            let after = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(paneRef),
                        "command": .string("printf 'after-cleanup\\n'"),
                        "timeout": .number(5),
                    ])
                )
            )
            let result = try after.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(result.output.contains { $0.hasSuffix("after-cleanup") })
            #expect(!result.output.contains { $0.hasSuffix("cancelled-run-finished") })
        }
    }
}

private actor FailingRunShellLaunchTransport: ProcessTransport {
    private let underlying = SubprocessTransport()

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains(where: {
            $0.contains("send-keys") && $0.contains("libtmux-mcp-done-")
        }) {
            throw .processLaunchFailed(reason: "did not spawn")
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }
}

private actor RunShellCaptureTransport: OutputLimitedProcessTransport {
    private let underlying = SubprocessTransport()
    private let failingCapture: Int?
    private var staleCaptureFailures: Int
    private(set) var captureLimits: [Int] = []

    init(failingCapture: Int? = nil, staleCaptureFailures: Int = 0) {
        self.failingCapture = failingCapture
        self.staleCaptureFailures = staleCaptureFailures
    }

    var captureCount: Int { captureLimits.count }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: .max
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains(where: { $0.contains("capture-pane") }) {
            captureLimits.append(perStreamOutputLimit)
            if let failingCapture, captureLimits.count == failingCapture {
                throw .invocationFailed(reason: "capture failed")
            }
            if captureLimits.count > 1, staleCaptureFailures > 0 {
                staleCaptureFailures -= 1
                throw .staleServerValue
            }
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}

private actor FailingRunShellWaitTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let failureLimit: Int
    private let staleCaptureFailureLimit: Int
    private(set) var waitFailureCount = 0
    private(set) var staleCaptureFailureCount = 0
    private var endpointDeparted = false

    init(failures: Int = 1, staleCaptureFailures: Int = 0) {
        self.failureLimit = failures
        self.staleCaptureFailureLimit = staleCaptureFailures
    }

    func departEndpoint() {
        endpointDeparted = true
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        if endpointDeparted {
            if arguments.contains("display-message") {
                return TmuxReply(standardOutput: [], standardError: [], exitCode: 1)
            }
            throw .invocationFailed(reason: "endpoint unavailable")
        }
        let isRunShellWait =
            arguments.contains("wait-for")
            && arguments.contains(where: { $0.contains("libtmux-mcp-done-") })
        if waitFailureCount < failureLimit, isRunShellWait {
            waitFailureCount += 1
            throw .invocationFailed(reason: "wait failed")
        }
        if waitFailureCount > 0,
            staleCaptureFailureCount < staleCaptureFailureLimit,
            arguments.contains(where: { $0.contains("capture-pane") })
        {
            staleCaptureFailureCount += 1
            throw .staleServerValue
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }
}

private enum RunShellBoundaryEvent: Sendable, Equatable {
    case capture
    case releaseSignal
}

private actor GatedRunShellWaitTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let held: AsyncStream<Void>
    private let heldWitness: AsyncStream<Void>.Continuation
    private let releases: AsyncStream<Void>
    private let releaseWitness: AsyncStream<Void>.Continuation
    private let boundaries: AsyncStream<RunShellBoundaryEvent>
    private let boundaryWitness: AsyncStream<RunShellBoundaryEvent>.Continuation
    private var doneReplyReleased = false

    init() {
        let (held, heldWitness) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let (releases, releaseWitness) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingOldest(1)
        )
        let (boundaries, boundaryWitness) = AsyncStream.makeStream(
            of: RunShellBoundaryEvent.self,
            bufferingPolicy: .unbounded
        )
        self.held = held
        self.heldWitness = heldWitness
        self.releases = releases
        self.releaseWitness = releaseWitness
        self.boundaries = boundaries
        self.boundaryWitness = boundaryWitness
    }

    func waitUntilHoldingDoneReply() async {
        var iterator = held.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseDoneReply() {
        releaseWitness.yield()
        releaseWitness.finish()
    }

    func boundaryEvents() -> AsyncStream<RunShellBoundaryEvent> {
        boundaries
    }

    func finish() {
        heldWitness.finish()
        releaseWitness.finish()
        boundaryWitness.finish()
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        let isDoneWait =
            arguments.contains("wait-for")
            && arguments.contains { $0.contains("libtmux-mcp-done-") }
        if doneReplyReleased,
            arguments.contains(where: { $0.contains("capture-pane") })
        {
            boundaryWitness.yield(.capture)
        }
        if doneReplyReleased,
            arguments.contains("wait-for"),
            arguments.contains("-S"),
            arguments.contains(where: { $0.contains("libtmux-mcp-release-") })
        {
            boundaryWitness.yield(.releaseSignal)
        }
        let reply = try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard isDoneWait else { return reply }
        heldWitness.yield()
        heldWitness.finish()
        var releaseIterator = releases.makeAsyncIterator()
        guard await releaseIterator.next() != nil, !Task.isCancelled else {
            throw .cancelled
        }
        doneReplyReleased = true
        return reply
    }
}

private actor WithheldRunShellReplyTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private var hasWithheldReply = false
    private(set) var isWithholdingReply = false

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        let reply = try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard !hasWithheldReply, isRunShellDispatch(arguments) else {
            return reply
        }

        hasWithheldReply = true
        isWithholdingReply = true
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw .cancelled
    }

    private func isRunShellDispatch(_ arguments: [String]) -> Bool {
        arguments.contains {
            $0.contains("send-keys") && $0.contains("libtmux-mcp-done-")
        }
    }
}
