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
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        let keptTail = max(0, tailLimit)
        let matchBudget = RegexMatchBudget()

        // Establish an absolute cursor before reading the entry screen. A
        // second cursor read below catches anything that arrived between the
        // two, so opening the event connection cannot create a blind spot.
        var incremental = try await retryingStaleOutputRead(until: deadline) {
            () async throws(OutputWaitError) -> IncrementalCapture in
            try await outputWaitTmux {
                try await capture(pane, since: nil)
            }
        }
        let entryRows = try await retryingStaleOutputRead(until: deadline) {
            () async throws(OutputWaitError) -> [String] in
            try await outputWaitTmux { try await waitLookbackRows(in: pane) }
        }
        let entryMatch = try firstEntryOutputMatch(
            in: entryRows,
            patterns: patterns,
            stops: stops,
            budget: matchBudget
        )
        let wasAlreadyShowing = entryMatch != nil

        let answer: @Sendable ([String], [String]) throws(OutputWaitError) -> OutputWait? = {
            arrived, tail in
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
            return nil
        }

        let caughtAtEntry = try await retryingStaleOutputRead(until: deadline) {
            () async throws(OutputWaitError) -> WaitCaptureScan in
            try await scanWaitOutput(
                in: pane,
                since: incremental.cursor,
                newest: [],
                sawNewOutput: false,
                tailLimit: keptTail,
                answer: answer
            )
        }
        incremental = IncrementalCapture(lines: [], cursor: caughtAtEntry.cursor)
        var sawNewOutput = caughtAtEntry.sawNewOutput
        var newest = caughtAtEntry.tail
        if let output = caughtAtEntry.output { return output }

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

        while ContinuousClock.now < deadline {
            guard
                let attachment = try await outputWaitTmux({
                    try await waitAttachment(for: pane)
                })
            else {
                return OutputWait(
                    outcome: .paneClosed,
                    sawNewOutput: sawNewOutput,
                    matchedAtEntry: wasAlreadyShowing,
                    tail: Array(newest.suffix(keptTail)),
                    seconds: Self.elapsed(since: started)
                )
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
                    answer: answer
                )
            } catch let error {
                if case .matching = error { throw error }
                if case .tmux(.cancelled) = error { throw error }
                guard ContinuousClock.now < deadline else { throw error }
                guard
                    let current = try await outputWaitTmux({
                        try await waitAttachment(for: pane)
                    })
                else {
                    return OutputWait(
                        outcome: .paneClosed,
                        sawNewOutput: sawNewOutput,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: newest,
                        seconds: Self.elapsed(since: started)
                    )
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

        let closed = try await outputWaitTmux { try await waitAttachment(for: pane) } == nil
        return OutputWait(
            outcome: closed ? .paneClosed : .timedOut,
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
        answer: @escaping @Sendable ([String], [String]) throws(OutputWaitError) -> OutputWait?
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
                            do {
                                guard let current = try await server.waitAttachment(for: pane)
                                else {
                                    await doorbell.ring(.paneClosed)
                                    return
                                }
                                if current != attachment {
                                    await doorbell.ring(.reattach)
                                    return
                                }
                            } catch {
                                await doorbell.ring(.failed(normalizedTmuxError(error)))
                                return
                            }
                        }
                    }

                    var cursor = cursor
                    var newest = newest
                    var sawNewOutput = sawNewOutput
                    while true {
                        let wake = await doorbell.wait()
                        if wake == .output { try await Task.sleep(for: .milliseconds(25)) }

                        if wake == .output || wake == .inspect || wake == .reattach {
                            do {
                                let scan = try await server.scanWaitOutput(
                                    in: pane,
                                    since: cursor,
                                    newest: newest,
                                    sawNewOutput: sawNewOutput,
                                    tailLimit: tailLimit,
                                    answer: answer
                                )
                                cursor = scan.cursor
                                sawNewOutput = scan.sawNewOutput
                                newest = scan.tail
                                if let output = scan.output {
                                    group.cancelAll()
                                    return .answered(output)
                                }
                            } catch let error {
                                guard try await owner.waitAttachment(for: pane) != nil else {
                                    return .finished(.paneClosed, newest, sawNewOutput)
                                }
                                throw error
                            }
                        }

                        switch wake {
                        case .output: continue
                        case .inspect:
                            guard let current = try await owner.waitAttachment(for: pane) else {
                                return .finished(.paneClosed, newest, sawNewOutput)
                            }
                            guard current == attachment else {
                                return .reattach(cursor, newest, sawNewOutput)
                            }
                        case .reattach, .connectionClosed:
                            guard try await owner.waitAttachment(for: pane) != nil else {
                                return .finished(.paneClosed, newest, sawNewOutput)
                            }
                            return .reattach(cursor, newest, sawNewOutput)
                        case .paneClosed:
                            return .finished(.paneClosed, newest, sawNewOutput)
                        case .timedOut:
                            let closed = try await owner.waitAttachment(for: pane) == nil
                            return .finished(
                                closed ? .paneClosed : .timedOut,
                                newest,
                                sawNewOutput
                            )
                        case let .failed(error): throw error
                        }
                    }
                }
            }
        }
    }

    private func retryingStaleOutputRead<Result>(
        until deadline: ContinuousClock.Instant,
        _ operation: () async throws(OutputWaitError) -> Result
    ) async throws(OutputWaitError) -> Result {
        while true {
            do {
                return try await operation()
            } catch let error {
                guard case .tmux(.staleServerValue) = error else { throw error }
                guard !Task.isCancelled else { throw .tmux(.cancelled) }
                guard ContinuousClock.now < deadline else { throw error }
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
        answer: ([String], [String]) throws(OutputWaitError) -> OutputWait?
    ) async throws(OutputWaitError) -> WaitCaptureScan {
        var tail = newest
        var sawOutput = sawNewOutput
        var output: OutputWait?
        var answerError: OutputWaitError?
        let scan: ForwardCaptureResult
        do {
            scan = try await scanForward(
                pane,
                since: cursor,
                sourceLinesPerChunk: Self.waitCaptureLines,
                perStreamOutputLimit: Self.waitCaptureOutputLimit
            ) { rows in
                let arrived = rows.filter { !$0.isEmpty }
                sawOutput = sawOutput || !arrived.isEmpty
                tail = Array((tail + arrived).suffix(tailLimit))
                do {
                    output = try answer(arrived, tail)
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
        if let answerError { throw answerError }
        if scan.linesMissed { throw .tmux(.outputContinuityLost) }
        if scan.restarted {
            let arrived: [String]
            do {
                arrived = try await waitLookbackRows(in: pane).filter { !$0.isEmpty }
            } catch {
                throw .tmux(error)
            }
            sawOutput = sawOutput || !arrived.isEmpty
            tail = Array((tail + arrived).suffix(tailLimit))
            output = try answer(arrived, tail)
        }
        return WaitCaptureScan(
            cursor: scan.cursor,
            tail: tail,
            sawNewOutput: sawOutput,
            output: output
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
    private static let waitCaptureOutputLimit = 1_048_576

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        (ContinuousClock.now - start).secondsValue
    }
}

private struct PaneAttachment: Sendable, Hashable {
    let sessionID: SessionID
    let windowID: WindowID
}

private enum OutputWaitCycle: Sendable {
    case answered(OutputWait)
    case reattach(CaptureCursor, [String], Bool)
    case finished(OutputWait.Outcome, [String], Bool)
}

private struct WaitCaptureScan: Sendable {
    let cursor: CaptureCursor
    let tail: [String]
    let sawNewOutput: Bool
    let output: OutputWait?
}

enum WaitWake: Sendable, Hashable {
    case output
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
        pending = primed ? [.output] : []
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

private func outputWaitTmux<Result>(
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
