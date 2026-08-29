import Foundation

struct OutputWaitSession: Sendable {
    let server: Server
    let pane: Pane
    let patterns: [RegexPattern]
    let stops: [RegexPattern]
    let requireFresh: Bool
    let started: ContinuousClock.Instant
    let deadline: ContinuousClock.Instant
    let tailLimit: Int
    let matchBudget: RegexMatchBudget

    func run() async throws(OutputWaitError) -> OutputWait {
        let keptTail = tailLimit

        // Establish an absolute cursor before reading the entry screen. A
        // second cursor read below catches anything that arrived between the
        // two, so opening the event connection cannot create a blind spot.
        let entryRace = await raceOrdinaryWaitOperation(until: deadline) {
            let incremental = try await self.retryingStaleOutputRead(until: deadline) {
                try await withOutputWaitErrorMapping {
                    try await self.server.capture(pane, since: nil)
                }
            }
            let rows = try await self.retryingStaleOutputRead(until: deadline) {
                try await withOutputWaitErrorMapping {
                    try await self.waitLookbackRows(using: self.server, in: pane)
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
        let wasAlreadyShowing = entryMatch != nil

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
            let attachmentRace = await raceOrdinaryWaitOperation(until: deadline) {
                try await self.waitAttachment(using: self.server, for: pane)
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
                let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                    try await self.waitAttachment(using: self.server, for: pane)
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
                                let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                    try await waitAttachment(using: owner, for: pane)
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
                            let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                try await waitAttachment(using: owner, for: pane)
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
                            let currentRace = await raceOrdinaryWaitOperation(until: deadline) {
                                try await waitAttachment(using: owner, for: pane)
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
        if outputEvent {
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
            deadlineReached: false
        )
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
