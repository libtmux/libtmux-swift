import Foundation

struct OutputWaitSession: Sendable {
    let server: Server
    let pane: Pane
    let patterns: [RegexPattern]
    let stops: [RegexPattern]
    let requireFresh: Bool
    let startingCursor: CaptureCursor?
    let started: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let tailLimit: Int

    func run() async throws(OutputWaitError) -> OutputWait {
        let keptTail = tailLimit

        // One read establishes the cursor and the entry screen together, so
        // they describe the same instant. The catch-up scan below still covers
        // anything that arrives while the event connection opens.
        let entryRace: WaitDeadlineRace<EntryCapture>
        if let startingCursor {
            entryRace = .completed(
                EntryCapture(rows: [], cursor: startingCursor, alternateScreen: false)
            )
        } else {
            entryRace = await raceOrdinaryWaitOperation(until: deadline) {
                try await self.retryingStaleOutputRead(until: deadline) {
                    try await withOutputWaitErrorMapping {
                        try await self.server.captureEntry(
                            pane,
                            historyLines: Self.waitHistoryLines,
                            perStreamOutputLimit: Self.waitCaptureOutputLimit
                        )
                    }
                }
            }
        }
        // Nothing was read, so nothing here is a finding: reporting `timedOut`
        // would claim the pattern was absent and the pane quiet on the strength
        // of never having looked.
        guard let entryRead = try settled(entryRace) else {
            return OutputWait(
                outcome: .expiredWhileReading,
                sawNewOutput: false,
                matchedAtEntry: false,
                tail: [],
                seconds: Self.elapsed(since: started)
            )
        }
        let entryRows = entryRead.rows
        var progress = WaitProgress(
            cursor: entryRead.cursor,
            tail: [],
            sawNewOutput: false,
            alternateScreen: entryRead.alternateScreen
        )
        let entryHit =
            entryRead.alternateScreen
            ? nil
            : try firstOutputWaitHit(
                in: entryRows,
                patterns: patterns,
                stops: stops,
                countingAnyRow: false
            )
        let wasAlreadyShowing = entryHit != nil

        // A deadline that spent any of itself on the alternate screen says
        // nothing about the pattern, because matching was suppressed while it
        // did. Reporting `timedOut` would send a caller to change the pattern.
        func expired() -> OutputWait.Outcome {
            progress.alternateScreen ? .alternateScreen : .timedOut
        }

        // Every answer past this point shares these three fields, which the
        // entry read has now fixed for the rest of the wait.
        @Sendable func ending(
            _ outcome: OutputWait.Outcome,
            matched: String? = nil,
            matchedIndex: Int? = nil,
            sawNewOutput: Bool = false,
            tail: [String] = [],
            cursor: CaptureCursor? = nil
        ) -> OutputWait {
            OutputWait(
                outcome: outcome,
                matched: matched,
                matchedIndex: matchedIndex,
                sawNewOutput: sawNewOutput,
                matchedAtEntry: wasAlreadyShowing,
                tail: Array(tail.suffix(keptTail)),
                cursor: cursor,
                seconds: Self.elapsed(since: started)
            )
        }

        // Answered up front rather than inferred from a timeout: "already on
        // screen" and "never happened" look identical afterwards, and only one
        // of them is fixed by waiting longer.
        if let entryHit, !requireFresh {
            return ending(
                entryHit.outcome,
                matched: entryHit.matched,
                matchedIndex: entryHit.matchedIndex,
                tail: entryRows,
                cursor: entryRead.cursor
            )
        }

        let answer: OutputWaitAnswer = { arrived, tail, outputEvent in
            var hit = try firstOutputWaitHit(
                in: arrived,
                patterns: patterns,
                stops: stops,
                countingAnyRow: true
            )
            // An event with no rows still counts when nothing was asked for:
            // the pane moved, which is all an unpatterned wait was told to see.
            if hit == nil, outputEvent, patterns.isEmpty {
                hit = OutputWaitHit(outcome: .matched)
            }
            guard let hit else { return nil }
            return ending(
                hit.outcome,
                matched: hit.matched,
                matchedIndex: hit.matchedIndex,
                sawNewOutput: true,
                tail: tail
            )
        }

        let entryCursor = progress.cursor
        let caughtAtEntryRace = await raceWaitOperation(
            until: deadline,
            classifyingCompletionWith: { $0.operationCompletion }
        ) {
            try await self.retryingStaleOutputRead(until: deadline) {
                try await self.scanWaitOutput(
                    using: self.server,
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
        // The entry screen was read, so `matchedAtEntry` stands; the scan that
        // would have seen new output was cut short, so the outcome must not
        // present its silence as a quiet pane.
        guard let caughtAtEntry = try settled(caughtAtEntryRace) else {
            return ending(.expiredWhileReading, cursor: entryCursor)
        }
        progress.cursor = caughtAtEntry.cursor
        progress.sawNewOutput = caughtAtEntry.sawNewOutput
        progress.tail = caughtAtEntry.tail
        progress.alternateScreen = progress.alternateScreen || caughtAtEntry.alternateScreen
        if let output = caughtAtEntry.output { return output }

        if caughtAtEntry.deadlineReached {
            return ending(
                expired(),
                sawNewOutput: progress.sawNewOutput,
                tail: progress.tail,
                cursor: progress.cursor
            )
        }

        while ContinuousClock.now < deadline {
            let attachmentRace = await raceOrdinaryWaitOperation(until: deadline) {
                try await self.waitAttachment(using: self.server, for: pane)
            }
            guard let living = try settled(attachmentRace) else {
                return ending(
                    expired(),
                    sawNewOutput: progress.sawNewOutput,
                    tail: progress.tail,
                    cursor: progress.cursor
                )
            }
            guard let attachment = living else {
                return ending(
                    .paneClosed,
                    sawNewOutput: progress.sawNewOutput,
                    tail: progress.tail,
                    cursor: progress.cursor
                )
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            let cycle: OutputWaitCycle
            do {
                cycle = try await waitForOutputCycle(
                    pane: pane,
                    attachment: attachment,
                    progress: progress,
                    tailLimit: keptTail,
                    remaining: remaining,
                    deadline: deadline,
                    answer: answer
                )
            } catch let error {
                switch try await survivable(error, having: attachment, for: pane) {
                case .reattach: continue
                case .paneClosed:
                    return ending(
                        .paneClosed,
                        sawNewOutput: progress.sawNewOutput,
                        tail: progress.tail,
                        cursor: progress.cursor
                    )
                case .expired:
                    return ending(
                        expired(),
                        sawNewOutput: progress.sawNewOutput,
                        tail: progress.tail,
                        cursor: progress.cursor
                    )
                }
            }
            switch cycle {
            case let .answered(output): return output
            case let .reattach(next): progress = next
            case let .finished(outcome, reached):
                progress = reached
                return ending(
                    outcome == .timedOut ? expired() : outcome,
                    sawNewOutput: reached.sawNewOutput,
                    tail: reached.tail,
                    cursor: reached.cursor
                )
            }
        }

        return ending(
            expired(),
            sawNewOutput: progress.sawNewOutput,
            tail: progress.tail,
            cursor: progress.cursor
        )
    }

    /// Whether a failed cycle is the wait's answer or something it can carry on
    /// from.
    ///
    /// A connection breaks when the pane moves to another session, which is not
    /// a failure of the wait but of the client it was holding. Telling the two
    /// apart costs one read of where the pane is now, so the error is rethrown
    /// unless the pane has in fact moved.
    private func survivable(
        _ error: OutputWaitError,
        having attachment: PaneAttachment,
        for pane: Pane
    ) async throws(OutputWaitError) -> SurvivedCycle {
        if case .matching = error { throw error }
        if case .tmux(.cancelled) = error { throw error }
        let stale: Bool
        if case .tmux(.staleServerValue) = error { stale = true } else { stale = false }
        if stale, ContinuousClock.now >= deadline { return .expired }
        guard ContinuousClock.now < deadline else { throw error }
        let race = await raceOrdinaryWaitOperation(until: deadline) {
            try await self.waitAttachment(using: self.server, for: pane)
        }
        guard let living = try settled(race) else { return .expired }
        guard let current = living else { return .paneClosed }
        guard current != attachment else {
            if stale { return .reattach }
            throw error
        }
        return .reattach
    }

    /// The value a race produced, or `nil` when the deadline won — which every
    /// caller answers differently, so it stays at the call site.
    private func settled<Value: Sendable>(
        _ race: WaitDeadlineRace<Value>
    ) throws(OutputWaitError) -> Value? {
        switch race {
        case let .completed(value): return value
        case let .failed(error): throw error
        case .timedOut: return nil
        case .cancelled: throw .tmux(.cancelled)
        }
    }
    private func waitForOutputCycle(
        pane: Pane,
        attachment: PaneAttachment,
        progress: WaitProgress,
        tailLimit: Int,
        remaining: Duration,
        deadline: ContinuousClock.Instant,
        answer: @escaping OutputWaitAnswer
    ) async throws(OutputWaitError) -> OutputWaitCycle {
        let owner = server
        return try await withOutputWaitErrorMapping {
            try await server.connectedGuardingIncarnation(
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
                            let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                try await waitAttachment(using: server, for: pane)
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

                    var progress = progress
                    while true {
                        // No settling delay before the scan: tmux queues
                        // `%output` and parses those same bytes into the grid
                        // inside one callback, and cannot flush the
                        // notification until it returns to its event loop, so
                        // the capture that follows is already reading them.
                        var wake = await doorbell.wait()
                        // A cancelled wait reports cancellation even past its
                        // deadline: the caller asked it to stop, and a timeout
                        // would say the pane stayed quiet instead.
                        if wake != .cancelled, ContinuousClock.now >= deadline {
                            wake = .timedOut
                        }

                        if wake == .output || wake == .scan || wake == .inspect
                            || wake == .reattach
                        {
                            let scanCursor = progress.cursor
                            let scanTail = progress.tail
                            let scanSawOutput = progress.sawNewOutput
                            let scanOutputEvent = wake == .output
                            let scanRace = await raceWaitOperation(
                                until: deadline,
                                classifyingCompletionWith: { $0.operationCompletion }
                            ) {
                                try await scanWaitOutput(
                                    using: server,
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
                                progress.cursor = scan.cursor
                                progress.sawNewOutput = scan.sawNewOutput
                                progress.tail = scan.tail
                                progress.alternateScreen =
                                    progress.alternateScreen || scan.alternateScreen
                                if scan.deadlineReached {
                                    return .finished(.timedOut, progress)
                                }
                                if let output = scan.output {
                                    group.cancelAll()
                                    return .answered(output)
                                }
                                if scan.hasMore { await doorbell.ring(.scan) }
                            case let .failed(error):
                                if case .matching = error { throw error }
                                let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                    try await waitAttachment(using: owner, for: pane)
                                }
                                switch currentRace {
                                case .completed(nil):
                                    return .finished(.paneClosed, progress)
                                case .completed:
                                    throw error
                                case let .failed(readError):
                                    throw readError
                                case .timedOut:
                                    return .finished(.timedOut, progress)
                                case .cancelled:
                                    throw OutputWaitError.tmux(.cancelled)
                                }
                            case .timedOut:
                                return .finished(.timedOut, progress)
                            case .cancelled:
                                throw OutputWaitError.tmux(.cancelled)
                            }
                        }

                        switch wake {
                        case .output, .scan: continue
                        case .inspect:
                            let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                try await waitAttachment(using: owner, for: pane)
                            }
                            switch currentRace {
                            case .completed(nil):
                                return .finished(.paneClosed, progress)
                            case let .completed(current?):
                                guard current == attachment else {
                                    return .reattach(progress)
                                }
                            case let .failed(error): throw error
                            case .timedOut:
                                return .finished(.timedOut, progress)
                            case .cancelled:
                                throw OutputWaitError.tmux(.cancelled)
                            }
                        case .reattach, .connectionClosed:
                            let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                try await waitAttachment(using: owner, for: pane)
                            }
                            switch currentRace {
                            case .completed(nil):
                                return .finished(.paneClosed, progress)
                            case .completed:
                                return .reattach(progress)
                            case let .failed(error): throw error
                            case .timedOut:
                                return .finished(.timedOut, progress)
                            case .cancelled:
                                throw OutputWaitError.tmux(.cancelled)
                            }
                        case .paneClosed:
                            return .finished(.paneClosed, progress)
                        case .timedOut:
                            return .finished(.timedOut, progress)
                        case .cancelled:
                            throw OutputWaitError.tmux(.cancelled)
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

    private func waitAttachment(
        using server: Server,
        for pane: Pane
    ) async throws(TmuxError) -> PaneAttachment? {
        let separator = String(FormatProjection.separator)
        guard
            let value = try await server.formatGlobal(
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

    private func raceOrdinaryWaitOperation<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> WaitDeadlineRace<Value> {
        await raceWaitOperation(
            until: deadline,
            classifyingCompletionWith: { _ in .ordinary },
            operation
        )
    }

    private func scanWaitOutput(
        using server: Server,
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
            scan = try await server.scanForward(
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
                deadlineReached: true,
                alternateScreen: scan.alternateScreen
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
                output: output.resuming(at: scan.cursor),
                answerSelectedAt: answerSelectedAt,
                hasMore: scan.hasMore,
                deadlineReached: false,
                alternateScreen: scan.alternateScreen
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
        if offersArrivedRows(scan.reanchor), !scan.alternateScreen {
            let arrived: [String]
            do {
                arrived = try await waitLookbackRows(using: server, in: pane).filter { !$0.isEmpty }
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
            } catch let error {
                answerError = error
            }
            switch terminal(failure: answerError) {
            case let .failed(error): throw error
            case let .answered(output): return answered(output)
            case .timedOut: return timedOut()
            case .pending: break
            }
        }
        if outputEvent, !scan.alternateScreen {
            sawOutput = true
            if output == nil {
                do {
                    output = try answer([], tail, true)
                    if output != nil {
                        let selectedAt = ContinuousClock.now
                        if selectedAt < deadline { answerSelectedAt = selectedAt }
                    }
                } catch let error {
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
            deadlineReached: false,
            alternateScreen: scan.alternateScreen
        )
    }

    /// Whether the rows a reanchor exposes count as output this wait can match.
    ///
    /// A respawn puts a new process's output on screen. A program handing the
    /// grid back puts back what was there before it took over, which a wait
    /// told to count only new output must not match.
    private func offersArrivedRows(_ reanchor: CursorReanchor) -> Bool {
        switch reanchor {
        case .none: false
        case .respawn: true
        case .gridHandback: !requireFresh
        }
    }

    private func waitLookbackRows(
        using server: Server,
        in pane: Pane
    ) async throws(TmuxError) -> [String] {
        try await server.captureLookbackThroughCursor(
            pane,
            historyLines: Self.waitHistoryLines,
            perStreamOutputLimit: Self.waitCaptureOutputLimit
        ).lines
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

/// What one turn of a wait carries forward: where reading stopped, what it has
/// seen, and whether a full-screen program owned the pane while it looked.
private struct WaitProgress: Sendable {
    var cursor: CaptureCursor
    var tail: [String]
    var sawNewOutput: Bool
    var alternateScreen: Bool
}

private enum SurvivedCycle: Sendable {
    case reattach
    case paneClosed
    case expired
}

private enum OutputWaitCycle: Sendable {
    case answered(OutputWait)
    case reattach(WaitProgress)
    case finished(OutputWait.Outcome, WaitProgress)
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
        @escaping @Sendable (Value) ->
        WaitOperationCompletion,
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
    let alternateScreen: Bool

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

func firstOutputPatternMatch(
    in text: String,
    patterns: [RegexPattern],
    maximumWork: Int = RegexPattern.defaultMaximumWork
) throws(OutputWaitError) -> Int? {
    for (index, pattern) in patterns.enumerated() {
        do {
            if try pattern.containsMatch(in: text, maximumWork: maximumWork) { return index }
        } catch let error {
            throw .matching(error)
        }
    }
    return nil
}

/// The first row that settles the wait, and what it settles it as.
///
/// A stop wins over a match on the same row. `countingAnyRow` is what an empty
/// `patterns` means once the wait is running — anything at all ends it — and it
/// is off at entry, where every row is something that was already there.
private func firstOutputWaitHit(
    in rows: [String],
    patterns: [RegexPattern],
    stops: [RegexPattern],
    countingAnyRow: Bool,
    maximumWork: Int = RegexPattern.defaultMaximumWork
) throws(OutputWaitError) -> OutputWaitHit? {
    for row in rows {
        if let index = try firstOutputPatternMatch(
            in: row, patterns: stops, maximumWork: maximumWork)
        {
            return OutputWaitHit(
                outcome: .stopped,
                matched: stops[index].source,
                matchedIndex: index
            )
        }
        guard !patterns.isEmpty else {
            if countingAnyRow { return OutputWaitHit(outcome: .matched) }
            continue
        }
        if let index = try firstOutputPatternMatch(
            in: row, patterns: patterns, maximumWork: maximumWork)
        {
            return OutputWaitHit(
                outcome: .matched,
                matched: patterns[index].source,
                matchedIndex: index
            )
        }
    }
    return nil
}

private struct OutputWaitHit {
    let outcome: OutputWait.Outcome
    var matched: String? = nil
    var matchedIndex: Int? = nil
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
