import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("watching a pane without polling", .timeLimit(.minutes(1)))
struct WatchTests {
    /// The bootstrap session's only pane.
    private func bootstrapPane(_ server: Server) async throws -> Pane {
        let panes = try await server.panes()
        return try #require(panes.first)
    }

    /// Runs `wait` while `text` is printed into `pane` over and over.
    ///
    /// A wait only ends on output that arrives after it starts, and opening its
    /// connection takes as long as a loaded machine takes. Printing repeatedly
    /// removes that race, where a longer sleep only makes it rarer — the same
    /// reason `run_shell` exists for callers who cannot tolerate it at all.
    private func printing(
        _ text: String,
        into pane: Pane,
        on server: Server,
        while wait: @Sendable @escaping () async throws -> OutputWait
    ) async throws -> OutputWait {
        try await withThrowingTaskGroup(of: OutputWait?.self) { group in
            group.addTask { try await wait() }
            group.addTask {
                var round = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    round += 1
                    // Numbered so a failed wait's tail says how long the
                    // printer was active.
                    try? await server.run("printf '\\n\(text) \(round)\\n'", in: pane)
                }
                return nil
            }
            var answer: OutputWait?
            while let outcome = try await group.next() {
                if let outcome {
                    answer = outcome
                    break
                }
            }
            group.cancelAll()
            return try #require(answer)
        }
    }

    @Test("a notification failure wakes an output wait")
    func notificationFailureWakesWait() async {
        let failure = TmuxError.notificationBufferOverflow(limit: 1)
        let notifications = ControlNotificationStream { continuation in
            continuation.yield(
                ControlNotification(name: "output", arguments: "%0 ready")
            )
            continuation.finish(throwing: failure)
        }
        let doorbell = WaitDoorbell()

        await OutputWaitSession.pumpWaitNotifications(notifications, for: "%0", into: doorbell)

        #expect(await doorbell.wait() == .output)
        #expect(await doorbell.wait() == .failed(failure))
    }

    @Test("a deadline overtakes queued scan work")
    func deadlineOvertakesQueuedScan() async {
        let doorbell = WaitDoorbell()
        await doorbell.ring(.scan)
        await doorbell.ring(.timedOut)

        #expect(await doorbell.wait() == .timedOut)
        #expect(await doorbell.wait() == .scan)
    }

    @Test("a wait ends on the line the command prints")
    func waitEndsOnAPrintedLine() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing(
                "libtmux-ready",
                into: pane,
                on: server
            ) {
                // Fresh output specifically: this is the event-driven path,
                // and without it the wait can legitimately answer from what
                // the printer already put on screen and never exercise it.
                try await server.waitForOutput(
                    in: pane,
                    matching: [
                        try RegexPattern(
                            "LIBTMUX-READY",
                            options: [.caseInsensitive]
                        )
                    ],
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }
            #expect(result.outcome == .matched)
            #expect(result.matched == "LIBTMUX-READY")
            #expect(result.sawNewOutput)
        }
    }

    @Test("a matcher refusal remains distinct from a timeout")
    func matcherRefusalPropagates() throws {
        let pattern = try RegexPattern("z$")
        let budget = try RegexMatchBudget(maximum: 20)
        #expect(
            try firstOutputPatternMatch(
                in: "aaaa",
                patterns: [pattern],
                budget: budget
            ) == nil
        )

        #expect(
            throws: OutputWaitError.matching(
                .workLimitExceeded(maximum: 20)
            )
        ) {
            try firstOutputPatternMatch(
                in: "aaaa",
                patterns: [pattern],
                budget: budget
            )
        }
    }

    @Test("an entry match wins before catch-up")
    func entryMatchWinsBeforeCatchUp() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            let marker = "entry-match-\(UUID().uuidString)"
            try await fixture.run("printf '\(marker)\\n'", in: pane)
            #expect(
                try await waitUntil {
                    try await fixture.capture(pane).contains(marker)
                }
            )

            // The entry read is one capture, so the next one is the catch-up
            // scan this must not reach.
            let transport = CaptureRecordingTransport()
            await transport.beforeCapture(2) { () async throws in
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    throw TmuxError.cancelled
                }
            }
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("^\(marker)$")],
                timeout: .milliseconds(100)
            )

            #expect(result.outcome == .matched)
            #expect(result.matchedAtEntry)
            #expect(!result.sawNewOutput)
            let requests = await transport.captureRequests
            #expect(requests.count == 1)
        }
    }

    @Test("a zero timeout reads nothing and does not call the pane quiet")
    func zeroTimeoutReportsThatItNeverLooked() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            let result = try await fixture.waitForOutput(
                in: pane,
                matching: [try RegexPattern("^never-printed$")],
                timeout: .zero
            )

            #expect(result.outcome == .expiredWhileReading)
        }
    }

    @Test("a matcher refusal wins an expired scan")
    func matcherRefusalWinsExpiredScan() {
        let refusal = OutputWaitError.matching(
            .workLimitExceeded(maximum: 20)
        )
        let terminal = waitScanTerminal(
            output: nil,
            failure: refusal,
            deadlineReached: true
        )
        #expect(terminal == .failed(refusal))
    }

    @Test("an answer selected before expiry survives a late operation handoff")
    func selectedAnswerSurvivesLateOperationHandoff() async {
        let answer = OutputWait(
            outcome: .matched,
            sawNewOutput: true,
            tail: ["selected-before-expiry"],
            seconds: 0
        )
        let selectedAt = ContinuousClock.now
        let deadline = selectedAt.advanced(by: .milliseconds(100))
        let result = await raceWaitOperation(
            until: deadline,
            classifyingCompletionWith: { _ in .causal(selectedAt: selectedAt) }
        ) {
            try? await Task.sleep(for: .seconds(1))
            return answer
        }

        let completed: OutputWait?
        if case let .completed(value) = result {
            completed = value
        } else {
            completed = nil
        }
        #expect(completed == answer)
    }

    @Test("caller cancellation wins an operation completion")
    func callerCancellationWinsOperationCompletion() async {
        let answer = OutputWait(
            outcome: .matched,
            sawNewOutput: true,
            tail: ["completed-after-cancellation"],
            seconds: 0
        )

        for causal in [false, true] {
            let selectedAt = ContinuousClock.now
            let deadline = selectedAt.advanced(by: .seconds(5))
            let (started, startWitness) = AsyncStream.makeStream(of: Void.self)
            var startIterator = started.makeAsyncIterator()
            let task = Task {
                await raceWaitOperation(
                    until: deadline,
                    classifyingCompletionWith: { _ in
                        causal ? .causal(selectedAt: selectedAt) : .ordinary
                    }
                ) {
                    startWitness.yield()
                    startWitness.finish()
                    while !Task.isCancelled { await Task.yield() }
                    return answer
                }
            }

            _ = await startIterator.next()
            task.cancel()
            let result = await task.value
            guard case .cancelled = result else {
                Issue.record("caller cancellation lost; causal: \(causal)")
                continue
            }
        }
    }

    @Test("caller cancellation wins an operation failure")
    func callerCancellationWinsOperationFailure() async {
        let failure = OutputWaitError.matching(
            .workLimitExceeded(maximum: 20)
        )
        let operationStarted = WaitTestGate()
        let failureReady = WaitTestGate()
        let failureRelease = WaitTestGate()
        let task = Task<WaitDeadlineRace<OutputWait>, Never> {
            await raceWaitOperation(
                until: ContinuousClock.now.advanced(by: .milliseconds(100)),
                classifyingCompletionWith: { _ in .ordinary }
            ) {
                await operationStarted.open()
                while !Task.isCancelled { await Task.yield() }
                await failureReady.open()
                await failureRelease.wait()
                throw failure
            }
        }

        await operationStarted.wait()
        await failureReady.wait()
        task.cancel()
        await failureRelease.open()
        let result = await task.value
        guard case .cancelled = result else {
            Issue.record("caller cancellation lost to an operation failure")
            return
        }
    }

    @Test("a bounded forward scan finds an early line in a large burst")
    func earlyBurstMatchSurvivesBoundedCapture() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            let ready = "wait-scan-ready-\(UUID().uuidString)"
            try await fixture.run(
                "stty -echo; \(fixture.shellInvocation) wait-for -S \(ready)",
                in: pane
            )
            try await fixture.wait(for: ready)

            let marker = "forward-scan-early-\(UUID().uuidString)"
            let burst =
                "awk 'BEGIN { for (i = 0; i < 600; i++) "
                + "print (i == 8 ? \"\(marker)\" : \"burst-\" i) }'"
            let hook = try await fixture.setHook(
                "client-attached",
                to: TmuxCommand(
                    "send-keys",
                    ["-t", pane.id.rawValue, burst, "Enter"]
                ).parsedString
            )
            #expect(hook.isSuccess, Comment(rawValue: hook.errorText))

            let transport = CaptureRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("^\(marker)$")],
                requiringFreshOutput: true,
                timeout: .seconds(3),
                tailLimit: 5
            )

            #expect(result.outcome == .matched)
            #expect(result.matched == "^\(marker)$")
            #expect(!result.tail.contains(marker))
            let requests = await transport.captureRequests
            #expect(!requests.isEmpty)
            #expect(
                requests.allSatisfy {
                    0 < $0.perStreamOutputLimit && $0.perStreamOutputLimit < .max
                }
            )
            let spans = requests.compactMap(\.rowSpan)
            #expect(spans.count == requests.count)
            #expect(spans.allSatisfy { $0 <= 256 })
        }
    }

    @Test("sustained output cannot move a wait past its deadline")
    func sustainedOutputCannotMoveTheDeadline() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            _ = try await fixture.setOption(
                "history-limit",
                to: "100000",
                scope: .globalSession
            )
            let ready = "moving-deadline-ready-\(UUID().uuidString)"
            try await fixture.run(
                "stty -echo; \(fixture.shellInvocation) wait-for -S \(ready)",
                in: pane
            )
            try await fixture.wait(for: ready)

            let attached = "moving-deadline-attached-\(UUID().uuidString)"
            let hook = try await fixture.setHook(
                "client-attached",
                to: TmuxCommand("wait-for", ["-S", attached]).parsedString
            )
            #expect(hook.isSuccess, Comment(rawValue: hook.errorText))

            let transport = CaptureRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let observed = try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    try await server.waitForOutput(
                        in: pane,
                        matching: [try RegexPattern("never-matches")],
                        requiringFreshOutput: true,
                        timeout: .seconds(2)
                    )
                }
                try await fixture.wait(for: attached)
                await transport.afterEveryCapture { () async throws in
                    let moved = "moving-deadline-burst-\(UUID().uuidString)"
                    try await fixture.run(
                        "i=0; while [ \"$i\" -lt 160 ]; do "
                            + "printf 'moving-%s\\n' \"$i\"; i=$((i + 1)); done; "
                            + "\(fixture.shellInvocation) wait-for -S \(moved)",
                        in: pane
                    )
                    try await fixture.wait(for: moved)
                }
                try await fixture.run("printf '\\ndeadline-start\\n'", in: pane)
                group.addTask {
                    try? await Task.sleep(for: .seconds(4))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            let result = try #require(observed, "wait exceeded its two-second deadline")
            #expect(result.outcome == .timedOut)
            #expect(result.seconds < 2.2)
        }
    }

    @Test("bootstrap capture cannot move a wait past its deadline")
    func bootstrapCaptureCannotMoveTheDeadline() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            let transport = CaptureRecordingTransport()
            await transport.afterEveryCapture { () async throws in
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    throw TmuxError.cancelled
                }
            }
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )

            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("never-matches")],
                requiringFreshOutput: true,
                timeout: .milliseconds(100)
            )

            // The deadline still holds, which is this case's point; the wait
            // now says it never finished reading rather than calling the pane
            // quiet on a capture it abandoned.
            #expect(result.outcome == .expiredWhileReading)
            #expect(result.seconds < 0.5)
        }
    }

    @Test("a stop marker ends the wait before the deadline")
    func stopMarkerEndsTheWaitEarly() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing("FAILED", into: pane, on: server) {
                try await server.waitForOutput(
                    in: pane,
                    matching: [try RegexPattern("never-appears-anywhere")],
                    stoppingAt: [try RegexPattern("FAILED")],
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }
            #expect(result.outcome == .stopped)
            #expect(result.matchedIndex == 0)
            // The point of a stop marker is the clock: without it this wait
            // would have held the caller for the whole twenty seconds to
            // report the same failure.
            #expect(result.seconds < 15)
        }
    }

    @Test("no patterns means any new output at all")
    func noPatternsMeansAnyOutput() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing("anything-at-all", into: pane, on: server) {
                try await server.waitForOutput(
                    in: pane,
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }
            #expect(result.outcome == .matched)
            #expect(result.matched == nil)
        }
    }

    @Test("any output before a stop ends an unpatterned wait")
    func anyOutputBeforeAStopWins() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing(
                "ordinary-output\\nFAILED",
                into: pane,
                on: server
            ) {
                try await server.waitForOutput(
                    in: pane,
                    stoppingAt: [try RegexPattern("^FAILED")],
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }

            #expect(result.outcome == .matched)
            #expect(result.matched == nil)
        }
    }

    @Test("output racing the initial cursor is retried")
    func initialCursorRaceIsRetried() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            let transport = CaptureRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let current = try #require(
                try await server.panes().first { $0.id == pane.id }
            )
            let marker = "cursor-race-\(UUID().uuidString)"
            let ready = "cursor-race-ready-\(UUID().uuidString)"
            await transport.beforeNextCapture { () async throws in
                try await fixture.run(
                    "printf '\(marker)\\n'; \(fixture.shellInvocation) wait-for -S \(ready)",
                    in: pane
                )
                try await fixture.wait(for: ready)
            }

            let result = try await server.waitForOutput(
                in: current,
                matching: [try RegexPattern(marker)],
                timeout: .seconds(5)
            )

            #expect(result.outcome == .matched)
            #expect(result.matchedAtEntry)
        }
    }

    @Test("a wait fails when its retained output boundary is lost")
    func outputContinuityLossFailsTheWait() async throws {
        try await withTmuxServer { server in
            let historyLimit = 20
            _ = try await server.setOption(
                "history-limit",
                to: String(historyLimit),
                scope: .globalSession
            )
            let session = try await server.newSession(named: "wait-continuity")
            let pane = try #require(
                try await server.snapshot().panes(of: session).first
            )
            let height = try #require(
                try await server.format("#{pane_height}", addressing: pane.id.rawValue)
                    .flatMap(Int.init)
            )
            let linesToFill = height - 1 + historyLimit
            let linesToEvict = height + historyLimit + 5
            try await server.run(
                "stty -echo; printf '\\033c'; i=0; "
                    + "while [ \"$i\" -lt \(linesToFill) ]; do "
                    + "printf 'SEED%03d\\n' \"$i\"; i=$((i + 1)); done; "
                    + "\(server.shellInvocation) wait-for -S wait-filled",
                in: pane
            )
            try await server.wait(for: "wait-filled")
            let burst =
                "i=0; while [ \"$i\" -lt \(linesToEvict) ]; do "
                + "printf 'FRESH%03d\\n' \"$i\"; i=$((i + 1)); done; "
                + "\(server.shellInvocation) wait-for -S wait-overflow-done"
            let hook = try await server.setHook(
                "client-attached",
                to: TmuxCommand(
                    "send-keys",
                    ["-t", pane.id.rawValue, burst, "Enter"]
                ).parsedString
            )
            #expect(hook.isSuccess)

            await #expect(throws: OutputWaitError.tmux(.outputContinuityLost)) {
                try await server.waitForOutput(
                    in: pane,
                    matching: [try RegexPattern("NEVER")],
                    requiringFreshOutput: true,
                    timeout: .seconds(5)
                )
            }
        }
    }

    @Test("a quiet pane times out saying it stayed quiet")
    func quietPaneReportsNoOutput() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.respawn(pane, running: ["sleep", "30"])
            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("nothing-will-print-this")],
                timeout: .milliseconds(1200)
            )
            #expect(result.outcome == .timedOut)
            // The field that tells a wrong pattern from a command that never
            // ran. Guessing another pattern is wasted work in the second case.
            #expect(!result.sawNewOutput)
        }
    }

    @Test("text already on screen answers at once, or is waited past on request")
    func staleTextDoesNotMatch() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.run("printf 'stale-marker\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            // Checked before it is blocked on: the text is there, so the
            // question is already answered and holding the caller for the
            // timeout would only make the same answer expensive.
            let answered = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("stale-marker")],
                timeout: .seconds(30)
            )
            #expect(answered.outcome == .matched)
            #expect(answered.matchedAtEntry)
            #expect(!answered.sawNewOutput)
            // Well inside the thirty-second timeout: `matchedAtEntry` already
            // proves which path answered, and this proves that path did not
            // wait. Loose enough to stay true on a machine running the rest of
            // this suite beside it.
            #expect(answered.seconds < 10)

            let stopped = try await server.waitForOutput(
                in: pane,
                stoppingAt: [try RegexPattern("stale-marker")],
                timeout: .milliseconds(200)
            )
            #expect(stopped.outcome == .stopped)
            #expect(stopped.matchedAtEntry)
            #expect(!stopped.sawNewOutput)

            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("stale-marker")],
                requiringFreshOutput: true,
                timeout: .milliseconds(1200)
            )
            // Re-running a command whose output looks identical has to work, so
            // asking for a fresh line waits past the one on screen.
            #expect(result.outcome == .timedOut)
            #expect(result.matchedAtEntry)
            #expect(!result.sawNewOutput)
        }
    }

    @Test("a repeated line on a multiply linked pane is fresh output")
    func repeatedIdenticalLineIsFresh() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let source = try #require(
                try await server.windows().first { $0.id == pane.windowID }
            )
            let destination = try await server.newSession(named: "wait-destination")
            _ = try await server.link(source, into: destination)
            _ = try await server.link(source, into: destination)
            let channel = "libtmux-test-echo-off-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; \(server.shellInvocation) wait-for -S \(channel)",
                in: pane
            )
            try await server.wait(for: channel)
            let seeded = "libtmux-test-seeded-\(UUID().uuidString)"
            try await server.run(
                "printf 'same-marker\\n'; \(server.shellInvocation) wait-for -S \(seeded)",
                in: pane
            )
            try await server.wait(for: seeded)

            let result = try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    try await server.waitForOutput(
                        in: pane,
                        matching: [try RegexPattern("^same-marker$")],
                        requiringFreshOutput: true,
                        timeout: .seconds(3)
                    )
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        try? await server.run("printf '\\nsame-marker\\n'", in: pane)
                    }
                    return nil
                }
                var answer: OutputWait?
                while let next = try await group.next() {
                    if let next {
                        answer = next
                        break
                    }
                }
                group.cancelAll()
                return try #require(answer)
            }

            #expect(result.outcome == .matched)
            #expect(result.matched == "^same-marker$")
            #expect(result.sawNewOutput)
        }
    }

    @Test("removing a pane ends its wait")
    func removedPaneEndsItsWait() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            _ = try await server.split(pane)

            let result = try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    try await server.waitForOutput(
                        in: pane,
                        matching: [try RegexPattern("never-appears")],
                        timeout: .seconds(5)
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(500))
                    try await server.kill(pane)
                    return nil
                }
                var answer: OutputWait?
                while let next = try await group.next() {
                    if let next {
                        answer = next
                        break
                    }
                }
                group.cancelAll()
                return try #require(answer)
            }

            #expect(result.outcome == .paneClosed)
            #expect(result.seconds < 4)
        }
    }

    @Test("output from a pane respawn ends an established wait")
    func respawnedPaneOutputIsNotLost() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let command = TmuxCommand(
                "respawn-pane",
                [
                    "-k", "-t", pane.id.rawValue,
                    "printf 'after-respawn\\n'; exec sleep 30",
                ]
            ).parsedString
            let hook = try await server.setHook("client-attached", to: command)
            #expect(hook.isSuccess)

            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("^after-respawn$")],
                requiringFreshOutput: true,
                timeout: .seconds(3)
            )

            #expect(result.outcome == .matched)
            #expect(result.matched == "^after-respawn$")
            #expect(result.sawNewOutput)
        }
    }

    @Test("a subscription reports the foreground command changing")
    func subscriptionReportsCommandChange() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let values = try await server.connected(attachingTo: "bootstrap") {
                server, control in
                try await control.watch(
                    FormatSubscription(
                        name: "cmd",
                        scope: .pane(pane.id),
                        format: "#{pane_current_command}"
                    )
                )
                let changes = control.changes(named: "cmd")
                try await server.run("sleep 3", in: pane)
                var seen: [String] = []
                for try await change in changes {
                    seen.append(change.value)
                    if seen.contains("sleep") { break }
                }
                return seen
            }
            // No capture, no scrollback, no prompt regex: tmux says what the
            // pane is running whenever that changes.
            #expect(values.contains("sleep"))
        }
    }

    @Test("a subscription change is read field by field")
    func subscriptionChangeParses() throws {
        let change = try #require(
            SubscriptionChange(
                ControlNotification(
                    name: "subscription-changed",
                    arguments: "cmd $0 @1 2 %3 : sleep 5"
                )
            )
        )
        #expect(change.name == "cmd")
        #expect(change.sessionID == "$0")
        #expect(change.windowID == "@1")
        #expect(change.windowIndex == 2)
        #expect(change.paneID == "%3")
        // Everything after the lone `:` is the value, spaces included.
        #expect(change.value == "sleep 5")
    }

    @Test("a session-scoped change carries no window or pane")
    func sessionScopedChangeHasNoPane() throws {
        let change = try #require(
            SubscriptionChange(
                ControlNotification(
                    name: "subscription-changed",
                    arguments: "act $0 - - - : main/1"
                )
            )
        )
        #expect(change.windowID == nil)
        #expect(change.windowIndex == nil)
        #expect(change.paneID == nil)
        #expect(change.value == "main/1")
    }

    @Test(
        "malformed subscription fields are refused",
        arguments: [
            "cmd $01 @1 2 %3 : value",
            "cmd $0 @01 2 %3 : value",
            "cmd $0 @1 two %3 : value",
            "cmd $0 @1 2 %03 : value",
        ]
    )
    func malformedSubscriptionFieldsAreRefused(_ arguments: String) {
        #expect(
            SubscriptionChange(
                ControlNotification(name: "subscription-changed", arguments: arguments)
            ) == nil
        )
    }

    @Test("any other notification is not a subscription change")
    func otherNotificationsAreNotChanges() {
        #expect(
            SubscriptionChange(
                ControlNotification(name: "output", arguments: "%0 hello")
            ) == nil
        )
    }
}

private actor WaitTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}
