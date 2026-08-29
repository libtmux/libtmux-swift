import Foundation

/// What a wait on a pane's output ended on.
public struct OutputWait: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        /// One of `patterns` appeared in output that arrived during the wait.
        case matched
        /// One of `stops` appeared first. `matchedIndex` says which.
        case stopped
        /// Nothing matched before the deadline.
        case timedOut
        /// The pane went away, so nothing more can arrive.
        case paneClosed
    }

    public let outcome: Outcome
    /// The pattern that ended the wait, from `patterns` or from `stops`.
    public let matched: String?
    /// Its position in whichever list it came from.
    public let matchedIndex: Int?
    /// Whether anything at all arrived. `false` with
    /// ``Outcome/timedOut`` means the pane was quiet — usually the command
    /// never ran, which no change of pattern will fix.
    public let sawNewOutput: Bool
    /// A match or stop condition was already on screen when the wait began.
    /// It accompanies an immediate match or stop, or the later outcome when
    /// `requireFresh` made the wait look past it.
    public let matchedAtEntry: Bool
    /// The last lines that arrived, newest last, for reading when the pattern
    /// was wrong.
    public let tail: [String]
    public let seconds: Double

    public init(
        outcome: Outcome,
        matched: String? = nil,
        matchedIndex: Int? = nil,
        sawNewOutput: Bool,
        matchedAtEntry: Bool = false,
        tail: [String],
        seconds: Double
    ) {
        self.outcome = outcome
        self.matched = matched
        self.matchedIndex = matchedIndex
        self.sawNewOutput = sawNewOutput
        self.matchedAtEntry = matchedAtEntry
        self.tail = tail
        self.seconds = seconds
    }
}

/// Why waiting for pane output failed before it produced an outcome.
public enum OutputWaitError: Error, Sendable, Hashable {
    case tmux(TmuxError)
    case matching(RegexMatchError)
}

extension Server {
    /// Waits until a pane prints something, driven by tmux output events.
    ///
    /// tmux has no hook that fires on pane output, so a wait that only has
    /// commands to work with must re-read the pane on a timer. A control
    /// connection is told instead: `%output` arrives as the pane writes.
    ///
    /// What arrives there is raw terminal bytes — keystroke echo, escape
    /// sequences, a word split across two notifications — so it is used as a
    /// doorbell rather than as text. Each burst wakes one capture, and the
    /// matching runs against the rendered grid, which is the same text a
    /// person reads. That keeps the accuracy of a capture and pays for it only
    /// when something actually happened. A small liveness probe runs while the
    /// pane is quiet so removing it ends the wait instead of looking like a
    /// timeout.
    ///
    /// The conditions are checked before they are blocked on. A match or stop
    /// already on screen returns at once, with ``OutputWait/matchedAtEntry``
    /// set. Pass `requiringFreshOutput` when only a new occurrence counts.
    ///
    /// - Parameters:
    ///   - pane: the pane to watch.
    ///   - patterns: bounded regular expressions, any of which ends the wait. Empty
    ///     means any new output at all does — the right choice when what the
    ///     pane prints is not known in advance.
    ///   - stops: bounded regular expressions that end the wait as
    ///     ``OutputWait/Outcome/stopped``. A failure marker belongs here: a
    ///     build that fails at five seconds should not hold the wait open for
    ///     the rest of the timeout.
    ///   - requireFresh: only count output that arrives after this call, so a
    ///     match already on screen is waited past rather than returned.
    ///   - timeout: how long to wait before giving up.
    ///   - tailLimit: how many trailing lines to report back.
    public func waitForOutput(
        in pane: Pane,
        matching patterns: [RegexPattern] = [],
        stoppingAt stops: [RegexPattern] = [],
        requiringFreshOutput requireFresh: Bool = false,
        timeout: Duration = .seconds(30),
        tailLimit: Int = 20
    ) async throws(OutputWaitError) -> OutputWait {
        do {
            _ = try expectedIncarnation([pane.incarnation])
        } catch {
            throw .tmux(error)
        }
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        let keptTail = max(0, tailLimit)
        let matchBudget = RegexMatchBudget()

        // Establish an absolute cursor before reading the entry screen. A
        // second cursor read below catches anything that arrived between the
        // two, so opening the event connection cannot create a blind spot.
        let entryRace = await raceWaitOperation(until: deadline) {
            let incremental = try await self.retryingStaleOutputRead(until: deadline) {
                try await withOutputWaitErrorMapping {
                    try await self.capture(pane, since: nil)
                }
            }
            let rows = try await self.retryingStaleOutputRead(until: deadline) {
                try await withOutputWaitErrorMapping {
                    try await self.waitLookbackRows(in: pane)
                }
            }
            return WaitEntryRead(incremental: incremental, rows: rows)
        }
        let entryRead: WaitEntryRead
        switch entryRace {
        case let .completed(value): entryRead = value
        case let .failed(error): throw error
        case .timedOut:
            return OutputWait(
                outcome: .timedOut,
                sawNewOutput: false,
                matchedAtEntry: false,
                tail: [],
                seconds: Self.elapsed(since: started)
            )
        case .cancelled: throw .tmux(.cancelled)
        }
        var incremental = entryRead.incremental
        let entryRows = entryRead.rows
        let entryMatch = try firstEntryOutputMatch(
            in: entryRows,
            patterns: patterns,
            stops: stops,
            budget: matchBudget
        )
        // Answered up front rather than inferred from a timeout: "already on
        // screen" and "never happened" look identical afterwards, and only one
        // of them is fixed by waiting longer.
        if let entryMatch, !requireFresh {
            return OutputWait(
                outcome: entryMatch.outcome,
                matched: entryMatch.matched,
                matchedIndex: entryMatch.matchedIndex,
                sawNewOutput: false,
                matchedAtEntry: true,
                tail: Array(entryRows.suffix(keptTail)),
                seconds: Self.elapsed(since: started)
            )
        }
        let wasAlreadyShowing = entryMatch != nil

        let answer: OutputWaitAnswer = { arrived, tail, outputEvent in
            for line in arrived {
                if let hit = try firstOutputPatternMatch(
                    in: line,
                    patterns: stops,
                    budget: matchBudget
                ) {
                    return OutputWait(
                        outcome: .stopped,
                        matched: stops[hit].source,
                        matchedIndex: hit,
                        sawNewOutput: true,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(tail.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
                guard !patterns.isEmpty else {
                    return OutputWait(
                        outcome: .matched,
                        sawNewOutput: true,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(tail.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
                if let hit = try firstOutputPatternMatch(
                    in: line,
                    patterns: patterns,
                    budget: matchBudget
                ) {
                    return OutputWait(
                        outcome: .matched,
                        matched: patterns[hit].source,
                        matchedIndex: hit,
                        sawNewOutput: true,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(tail.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
            }
            guard outputEvent, patterns.isEmpty else { return nil }
            return OutputWait(
                outcome: .matched,
                sawNewOutput: true,
                matchedAtEntry: wasAlreadyShowing,
                tail: Array(tail.suffix(keptTail)),
                seconds: Self.elapsed(since: started)
            )
        }

        let entryCursor = incremental.cursor
        let caughtAtEntryRace = await raceWaitOperation(
            until: deadline,
            classifyingCompletionWith: { $0.operationCompletion }
        ) {
            try await self.retryingStaleOutputRead(until: deadline) {
                try await self.scanWaitOutput(
                    in: pane,
                    since: entryCursor,
                    newest: [],
                    sawNewOutput: false,
                    tailLimit: keptTail,
                    outputEvent: false,
                    deadline: deadline,
                    answer: answer
                )
            }
        }
        let caughtAtEntry: WaitCaptureScan
        switch caughtAtEntryRace {
        case let .completed(scan): caughtAtEntry = scan
        case let .failed(error): throw error
        case .timedOut:
            return OutputWait(
                outcome: .timedOut,
                sawNewOutput: false,
                matchedAtEntry: wasAlreadyShowing,
                tail: [],
                seconds: Self.elapsed(since: started)
            )
        case .cancelled: throw .tmux(.cancelled)
        }
        incremental = IncrementalCapture(lines: [], cursor: caughtAtEntry.cursor)
        var sawNewOutput = caughtAtEntry.sawNewOutput
        var newest = caughtAtEntry.tail
        if let output = caughtAtEntry.output { return output }

        if caughtAtEntry.deadlineReached {
            return OutputWait(
                outcome: .timedOut,
                sawNewOutput: sawNewOutput,
                matchedAtEntry: wasAlreadyShowing,
                tail: Array(newest.suffix(keptTail)),
                seconds: Self.elapsed(since: started)
            )
        }

        while ContinuousClock.now < deadline {
            let attachmentRace = await raceWaitOperation(until: deadline) {
                try await self.waitAttachment(for: pane)
            }
            let attachment: PaneAttachment
            switch attachmentRace {
            case let .completed(current):
                guard let current else {
                    return OutputWait(
                        outcome: .paneClosed,
                        sawNewOutput: sawNewOutput,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(newest.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
                attachment = current
            case let .failed(error): throw error
            case .timedOut:
                return OutputWait(
                    outcome: .timedOut,
                    sawNewOutput: sawNewOutput,
                    matchedAtEntry: wasAlreadyShowing,
                    tail: Array(newest.suffix(keptTail)),
                    seconds: Self.elapsed(since: started)
                )
            case .cancelled: throw .tmux(.cancelled)
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            let cycle: OutputWaitCycle
            do {
                cycle = try await waitForOutputCycle(
                    pane: pane,
                    attachment: attachment,
                    cursor: incremental.cursor,
                    newest: newest,
                    sawNewOutput: sawNewOutput,
                    tailLimit: keptTail,
                    remaining: remaining,
                    deadline: deadline,
                    answer: answer
                )
            } catch let error {
                if case .matching = error { throw error }
                if case .tmux(.cancelled) = error { throw error }
                if case .tmux(.staleServerValue) = error,
                    ContinuousClock.now >= deadline
                {
                    return OutputWait(
                        outcome: .timedOut,
                        sawNewOutput: sawNewOutput,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(newest.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
                guard ContinuousClock.now < deadline else { throw error }
                let currentRace = await raceWaitOperation(until: deadline) {
                    try await self.waitAttachment(for: pane)
                }
                let current: PaneAttachment
                switch currentRace {
                case let .completed(value):
                    guard let value else {
                        return OutputWait(
                            outcome: .paneClosed,
                            sawNewOutput: sawNewOutput,
                            matchedAtEntry: wasAlreadyShowing,
                            tail: newest,
                            seconds: Self.elapsed(since: started)
                        )
                    }
                    current = value
                case let .failed(readError): throw readError
                case .timedOut:
                    return OutputWait(
                        outcome: .timedOut,
                        sawNewOutput: sawNewOutput,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: newest,
                        seconds: Self.elapsed(since: started)
                    )
                case .cancelled: throw .tmux(.cancelled)
                }
                guard current != attachment else {
                    if case .tmux(.staleServerValue) = error { continue }
                    throw error
                }
                continue
            }
            switch cycle {
            case let .answered(output): return output
            case let .reattach(cursor, lines, sawOutput):
                incremental = IncrementalCapture(lines: [], cursor: cursor)
                newest = lines
                sawNewOutput = sawOutput
            case let .finished(outcome, lines, sawOutput):
                return OutputWait(
                    outcome: outcome,
                    sawNewOutput: sawOutput,
                    matchedAtEntry: wasAlreadyShowing,
                    tail: Array(lines.suffix(keptTail)),
                    seconds: Self.elapsed(since: started)
                )
            }
        }

        return OutputWait(
            outcome: .timedOut,
            sawNewOutput: sawNewOutput,
            matchedAtEntry: wasAlreadyShowing,
            tail: Array(newest.suffix(keptTail)),
            seconds: Self.elapsed(since: started)
        )
    }

    private func waitForOutputCycle(
        pane: Pane,
        attachment: PaneAttachment,
        cursor: CaptureCursor,
        newest: [String],
        sawNewOutput: Bool,
        tailLimit: Int,
        remaining: Duration,
        deadline: ContinuousClock.Instant,
        answer: @escaping OutputWaitAnswer
    ) async throws(OutputWaitError) -> OutputWaitCycle {
        let owner = self
        return try await withOutputWaitErrorMapping {
            try await connectedGuardingIncarnation(
                attachingTo: attachment.sessionID,
                expecting: pane.incarnation
            ) { (server: Server, control: ControlSession) async throws -> OutputWaitCycle in
                let doorbell = WaitDoorbell(primed: true)
                let notifications = control.notifications
                return try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { group.cancelAll() }
                    group.addTask {
                        await Self.pumpWaitNotifications(
                            notifications,
                            for: pane.id,
                            into: doorbell
                        )
                    }
                    group.addTask {
                        try? await Task.sleep(for: remaining)
                        guard !Task.isCancelled else { return }
                        await doorbell.ring(.timedOut)
                    }
                    group.addTask {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled else { return }
                            let currentRace = await raceWaitOperation(until: deadline) {
                                try await server.waitAttachment(for: pane)
                            }
                            switch currentRace {
                            case let .completed(current):
                                guard let current else {
                                    await doorbell.ring(.paneClosed)
                                    return
                                }
                                if current != attachment {
                                    await doorbell.ring(.reattach)
                                    return
                                }
                            case let .failed(error):
                                await doorbell.ring(.failed(waitTmuxError(error)))
                                return
                            case .timedOut:
                                await doorbell.ring(.timedOut)
                                return
                            case .cancelled:
                                return
                            }
                        }
                    }

                    var cursor = cursor
                    var newest = newest
                    var sawNewOutput = sawNewOutput
                    while true {
                        var wake = await doorbell.wait()
                        if wake == .output { try await Task.sleep(for: .milliseconds(25)) }
                        if ContinuousClock.now >= deadline { wake = .timedOut }

                        if wake == .output || wake == .scan || wake == .inspect
                            || wake == .reattach
                        {
                            let scanCursor = cursor
                            let scanTail = newest
                            let scanSawOutput = sawNewOutput
                            let scanOutputEvent = wake == .output
                            let scanRace = await raceWaitOperation(
                                until: deadline,
                                classifyingCompletionWith: { $0.operationCompletion }
                            ) {
                                try await server.scanWaitOutput(
                                    in: pane,
                                    since: scanCursor,
                                    newest: scanTail,
                                    sawNewOutput: scanSawOutput,
                                    tailLimit: tailLimit,
                                    outputEvent: scanOutputEvent,
                                    deadline: deadline,
                                    answer: answer
                                )
                            }
                            switch scanRace {
                            case let .completed(scan):
                                cursor = scan.cursor
                                sawNewOutput = scan.sawNewOutput
                                newest = scan.tail
                                if scan.deadlineReached {
                                    return .finished(.timedOut, newest, sawNewOutput)
                                }
                                if let output = scan.output {
                                    group.cancelAll()
                                    return .answered(output)
                                }
                                if scan.hasMore { await doorbell.ring(.scan) }
                            case let .failed(error):
                                if case .matching = error { throw error }
                                let currentRace = await raceWaitOperation(until: deadline) {
                                    try await owner.waitAttachment(for: pane)
                                }
                                switch currentRace {
                                case .completed(nil):
                                    return .finished(.paneClosed, newest, sawNewOutput)
                                case .completed:
                                    throw error
                                case let .failed(readError):
                                    throw readError
                                case .timedOut:
                                    return .finished(.timedOut, newest, sawNewOutput)
                                case .cancelled:
                                    throw OutputWaitError.tmux(.cancelled)
                                }
                            case .timedOut:
                                return .finished(.timedOut, newest, sawNewOutput)
                            case .cancelled:
                                throw OutputWaitError.tmux(.cancelled)
                            }
                        }

                        switch wake {
                        case .output, .scan: continue
                        case .inspect:
                            let currentRace = await raceWaitOperation(until: deadline) {
                                try await owner.waitAttachment(for: pane)
                            }
                            switch currentRace {
                            case .completed(nil):
                                return .finished(.paneClosed, newest, sawNewOutput)
                            case let .completed(current?):
                                guard current == attachment else {
                                    return .reattach(cursor, newest, sawNewOutput)
                                }
                            case let .failed(error): throw error
                            case .timedOut:
                                return .finished(.timedOut, newest, sawNewOutput)
                            case .cancelled:
                                throw OutputWaitError.tmux(.cancelled)
                            }
                        case .reattach, .connectionClosed:
                            let currentRace = await raceWaitOperation(until: deadline) {
                                try await owner.waitAttachment(for: pane)
                            }
                            switch currentRace {
                            case .completed(nil):
                                return .finished(.paneClosed, newest, sawNewOutput)
                            case .completed:
                                return .reattach(cursor, newest, sawNewOutput)
                            case let .failed(error): throw error
                            case .timedOut:
                                return .finished(.timedOut, newest, sawNewOutput)
                            case .cancelled:
                                throw OutputWaitError.tmux(.cancelled)
                            }
                        case .paneClosed:
                            return .finished(.paneClosed, newest, sawNewOutput)
                        case .timedOut:
                            return .finished(.timedOut, newest, sawNewOutput)
                        case let .failed(error): throw error
                        }
                    }
                }
            }
        }
    }

    private func retryingStaleOutputRead<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws(OutputWaitError) -> Value {
        while true {
            do {
                return try await operation()
            } catch {
                let mapped: OutputWaitError
                if let error = error as? OutputWaitError {
                    mapped = error
                } else {
                    mapped = .tmux(normalizedTmuxError(error))
                }
                guard case .tmux(.staleServerValue) = mapped else { throw mapped }
                guard !Task.isCancelled else { throw .tmux(.cancelled) }
                guard ContinuousClock.now < deadline else { throw mapped }
                await Task.yield()
            }
        }
    }

    private func waitAttachment(for pane: Pane) async throws(TmuxError) -> PaneAttachment? {
        let separator = String(FormatProjection.separator)
        guard
            let value = try await formatGlobal(
                "#{session_id}\(separator)#{window_id}\(separator)#{pane_id}"
                    + "\(separator)#{pane_dead}",
                for: pane
            )
        else { return nil }
        let fields = value.components(separatedBy: separator)
        guard fields.count == 4 else {
            throw .invocationFailed(reason: "tmux returned an incomplete pane attachment")
        }
        if fields[3] == "1" { return nil }
        guard fields[2] == pane.id.rawValue,
            let sessionID = SessionID(rawValue: fields[0]),
            let windowID = WindowID(rawValue: fields[1])
        else {
            throw .invocationFailed(reason: "tmux returned an invalid pane attachment")
        }
        return PaneAttachment(sessionID: sessionID, windowID: windowID)
    }

    private func scanWaitOutput(
        in pane: Pane,
        since cursor: CaptureCursor,
        newest: [String],
        sawNewOutput: Bool,
        tailLimit: Int,
        outputEvent: Bool,
        deadline: ContinuousClock.Instant,
        answer: OutputWaitAnswer
    ) async throws(OutputWaitError) -> WaitCaptureScan {
        var tail = newest
        var sawOutput = sawNewOutput
        var output: OutputWait?
        var answerSelectedAt: ContinuousClock.Instant?
        var answerError: OutputWaitError?
        var deadlineReached = false
        let scan: ForwardCaptureResult
        do {
            scan = try await scanForward(
                pane,
                since: cursor,
                sourceLinesPerChunk: Self.waitCaptureLines,
                maximumChunks: Self.waitCaptureChunksPerTurn,
                perStreamOutputLimit: Self.waitCaptureOutputLimit
            ) { rows in
                guard ContinuousClock.now < deadline else {
                    deadlineReached = true
                    return true
                }
                let arrived = rows
                sawOutput = sawOutput || !arrived.isEmpty
                tail = Array((tail + arrived).suffix(tailLimit))
                do {
                    output = try answer(arrived, tail, false)
                    if output != nil {
                        let selectedAt = ContinuousClock.now
                        if selectedAt < deadline { answerSelectedAt = selectedAt }
                    }
                } catch let error as OutputWaitError {
                    answerError = error
                } catch {
                    answerError = .tmux(normalizedTmuxError(error))
                }
                return output != nil || answerError != nil
            }
        } catch {
            throw .tmux(normalizedTmuxError(error))
        }
        func timedOut() -> WaitCaptureScan {
            WaitCaptureScan(
                cursor: scan.cursor,
                tail: tail,
                sawNewOutput: sawOutput,
                output: nil,
                answerSelectedAt: nil,
                hasMore: false,
                deadlineReached: true
            )
        }
        func terminal(failure: OutputWaitError? = nil) -> WaitScanTerminal {
            waitScanTerminal(
                output: answerSelectedAt == nil ? nil : output,
                failure: failure,
                deadlineReached: deadlineReached || ContinuousClock.now >= deadline
            )
        }
        func answered(_ output: OutputWait) -> WaitCaptureScan {
            WaitCaptureScan(
                cursor: scan.cursor,
                tail: tail,
                sawNewOutput: sawOutput,
                output: output,
                answerSelectedAt: answerSelectedAt,
                hasMore: scan.hasMore,
                deadlineReached: false
            )
        }
        let forwardFailure =
            answerError
            ?? (scan.linesMissed ? .tmux(.outputContinuityLost) : nil)
        switch terminal(failure: forwardFailure) {
        case let .failed(error): throw error
        case let .answered(output): return answered(output)
        case .timedOut: return timedOut()
        case .pending: break
        }
        if scan.restarted {
            let arrived: [String]
            do {
                arrived = try await waitLookbackRows(in: pane).filter { !$0.isEmpty }
            } catch {
                throw .tmux(error)
            }
            guard ContinuousClock.now < deadline else { return timedOut() }
            sawOutput = sawOutput || !arrived.isEmpty
            tail = Array((tail + arrived).suffix(tailLimit))
            do {
                output = try answer(arrived, tail, false)
                if output != nil {
                    let selectedAt = ContinuousClock.now
                    if selectedAt < deadline { answerSelectedAt = selectedAt }
                }
            } catch {
                answerError = error
            }
            switch terminal(failure: answerError) {
            case let .failed(error): throw error
            case let .answered(output): return answered(output)
            case .timedOut: return timedOut()
            case .pending: break
            }
        }
        if outputEvent {
            sawOutput = true
            if output == nil {
                do {
                    output = try answer([], tail, true)
                    if output != nil {
                        let selectedAt = ContinuousClock.now
                        if selectedAt < deadline { answerSelectedAt = selectedAt }
                    }
                } catch {
                    answerError = error
                }
            }
            switch terminal(failure: answerError) {
            case let .failed(error): throw error
            case let .answered(output): return answered(output)
            case .timedOut: return timedOut()
            case .pending: break
            }
        }
        return WaitCaptureScan(
            cursor: scan.cursor,
            tail: tail,
            sawNewOutput: sawOutput,
            output: output,
            answerSelectedAt: answerSelectedAt,
            hasMore: scan.hasMore,
            deadlineReached: false
        )
    }

    private func waitLookbackRows(in pane: Pane) async throws(TmuxError) -> [String] {
        try await captureLookbackThroughCursor(
            pane,
            historyLines: Self.waitHistoryLines,
            perStreamOutputLimit: Self.waitCaptureOutputLimit
        ).lines
    }

    private static let topologyNotifications: Set<String> = [
        "layout-change", "session-window-changed", "unlinked-window-add",
        "unlinked-window-close", "window-add", "window-close", "window-pane-changed",
    ]

    static func pumpWaitNotifications(
        _ notifications: ControlNotificationStream,
        for paneID: PaneID,
        into doorbell: WaitDoorbell
    ) async {
        do {
            for try await notification in notifications {
                if notification.name == "output",
                    notification.arguments.hasPrefix("\(paneID.rawValue) ")
                {
                    await doorbell.ring(.output)
                } else if topologyNotifications.contains(notification.name) {
                    await doorbell.ring(.inspect)
                }
            }
            await doorbell.ring(.connectionClosed)
        } catch {
            await doorbell.ring(.failed(normalizedTmuxError(error)))
        }
    }

    /// How far above the visible region entry and restart checks read.
    /// Forward scans use their cursor; these checks have no usable old anchor,
    /// so they read a bounded lookback rather than the whole scrollback.
    private static let waitHistoryLines = 200
    private static let waitCaptureLines = 128
    private static let waitCaptureChunksPerTurn = 4
    private static let waitCaptureOutputLimit = 1_048_576

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        (ContinuousClock.now - start).secondsValue
    }
}

private struct PaneAttachment: Sendable, Hashable {
    let sessionID: SessionID
    let windowID: WindowID
}

private struct WaitEntryRead: Sendable {
    let incremental: IncrementalCapture
    let rows: [String]
}

private enum OutputWaitCycle: Sendable {
    case answered(OutputWait)
    case reattach(CaptureCursor, [String], Bool)
    case finished(OutputWait.Outcome, [String], Bool)
}

enum WaitDeadlineRace<Value: Sendable>: Sendable {
    case completed(Value)
    case failed(OutputWaitError)
    case timedOut
    case cancelled
}

enum WaitOperationCompletion: Sendable {
    case ordinary
    case causal(selectedAt: ContinuousClock.Instant)
}

func raceWaitOperation<Value: Sendable>(
    until deadline: ContinuousClock.Instant,
    classifyingCompletionWith classify:
        @escaping @Sendable (Value) -> WaitOperationCompletion = { _ in .ordinary },
    _ operation: @escaping @Sendable () async throws -> Value
) async -> WaitDeadlineRace<Value> {
    if Task.isCancelled { return .cancelled }
    let now = ContinuousClock.now
    guard now < deadline else { return .timedOut }
    let remaining = now.duration(to: deadline)
    return await withTaskGroup(of: WaitDeadlineRace<Value>.self) { group in
        group.addTask {
            await completeWaitOperation(
                until: deadline,
                classifyingCompletionWith: classify,
                operation
            )
        }
        group.addTask {
            try? await Task.sleep(for: remaining)
            return Task.isCancelled ? .cancelled : .timedOut
        }
        let first = await group.next() ?? .cancelled
        group.cancelAll()
        if Task.isCancelled { return .cancelled }
        guard case .timedOut = first else { return first }
        while let late = await group.next() {
            if Task.isCancelled { return .cancelled }
            switch late {
            case .completed:
                return late
            case let .failed(error):
                switch error {
                case .tmux(.cancelled), .tmux(.staleServerValue): continue
                default: return late
                }
            case .timedOut, .cancelled:
                continue
            }
        }
        return Task.isCancelled ? .cancelled : first
    }
}

private func completeWaitOperation<Value: Sendable>(
    until deadline: ContinuousClock.Instant,
    classifyingCompletionWith classify: @Sendable (Value) -> WaitOperationCompletion,
    _ operation: @Sendable () async throws -> Value
) async -> WaitDeadlineRace<Value> {
    do {
        let value = try await operation()
        let arrivedBeforeDeadline = waitOperationCompletionArrivedBeforeDeadline(
            classify(value),
            handedOffAt: ContinuousClock.now,
            deadline: deadline
        )
        if arrivedBeforeDeadline { return .completed(value) }
        return Task.isCancelled ? .cancelled : .timedOut
    } catch let error as OutputWaitError {
        if case .tmux(.staleServerValue) = error,
            ContinuousClock.now >= deadline
        {
            return .timedOut
        }
        return .failed(error)
    } catch {
        let mapped = normalizedTmuxError(error)
        if case .staleServerValue = mapped,
            ContinuousClock.now >= deadline
        {
            return .timedOut
        }
        return .failed(.tmux(mapped))
    }
}

private func waitOperationCompletionArrivedBeforeDeadline(
    _ completion: WaitOperationCompletion,
    handedOffAt: ContinuousClock.Instant,
    deadline: ContinuousClock.Instant
) -> Bool {
    switch completion {
    case .ordinary: handedOffAt < deadline
    case let .causal(selectedAt): selectedAt < deadline
    }
}

private struct WaitCaptureScan: Sendable {
    let cursor: CaptureCursor
    let tail: [String]
    let sawNewOutput: Bool
    let output: OutputWait?
    let answerSelectedAt: ContinuousClock.Instant?
    let hasMore: Bool
    let deadlineReached: Bool

    var operationCompletion: WaitOperationCompletion {
        guard let answerSelectedAt else { return .ordinary }
        return .causal(selectedAt: answerSelectedAt)
    }
}

enum WaitScanTerminal: Sendable, Hashable {
    case failed(OutputWaitError)
    case answered(OutputWait)
    case timedOut
    case pending
}

func waitScanTerminal(
    output: OutputWait?,
    failure: OutputWaitError?,
    deadlineReached: Bool
) -> WaitScanTerminal {
    if let failure { return .failed(failure) }
    if let output { return .answered(output) }
    if deadlineReached { return .timedOut }
    return .pending
}

private typealias OutputWaitAnswer =
    @Sendable ([String], [String], Bool) throws(OutputWaitError) -> OutputWait?

private func waitTmuxError(_ error: OutputWaitError) -> TmuxError {
    switch error {
    case let .tmux(error): error
    case let .matching(error): .invocationFailed(reason: String(describing: error))
    }
}

enum WaitWake: Sendable, Hashable {
    case output
    case scan
    case inspect
    case reattach
    case paneClosed
    case timedOut
    case connectionClosed
    case failed(TmuxError)
}

/// Coalesces bursts without discarding terminal or topology events behind them.
actor WaitDoorbell {
    private var pending: [WaitWake]
    private var waiter: CheckedContinuation<WaitWake, Never>?

    init(primed: Bool = false) {
        pending = primed ? [.scan] : []
    }

    func ring(_ event: WaitWake) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else if !pending.contains(event) {
            pending.append(event)
        }
    }

    func wait() async -> WaitWake {
        if let deadline = pending.firstIndex(of: .timedOut) {
            return pending.remove(at: deadline)
        }
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

func firstOutputPatternMatch(
    in text: String,
    patterns: [RegexPattern],
    budget: RegexMatchBudget
) throws(OutputWaitError) -> Int? {
    for (index, pattern) in patterns.enumerated() {
        do {
            if try pattern.containsMatch(in: text, budget: budget) { return index }
        } catch let error {
            throw .matching(error)
        }
    }
    return nil
}

private func firstEntryOutputMatch(
    in rows: [String],
    patterns: [RegexPattern],
    stops: [RegexPattern],
    budget: RegexMatchBudget
) throws(OutputWaitError) -> EntryOutputMatch? {
    for row in rows {
        if let index = try firstOutputPatternMatch(in: row, patterns: stops, budget: budget) {
            return EntryOutputMatch(
                outcome: .stopped,
                matched: stops[index].source,
                matchedIndex: index
            )
        }
        if let index = try firstOutputPatternMatch(in: row, patterns: patterns, budget: budget) {
            return EntryOutputMatch(
                outcome: .matched,
                matched: patterns[index].source,
                matchedIndex: index
            )
        }
    }
    return nil
}

private struct EntryOutputMatch {
    let outcome: OutputWait.Outcome
    let matched: String
    let matchedIndex: Int
}

private func withOutputWaitErrorMapping<Result>(
    _ operation: () async throws -> Result
) async throws(OutputWaitError) -> Result {
    do {
        return try await operation()
    } catch let error as OutputWaitError {
        throw error
    } catch {
        throw .tmux(normalizedTmuxError(error))
    }
}
