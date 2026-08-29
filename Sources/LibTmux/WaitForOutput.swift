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
    /// The pattern was already on screen when the wait began.
    ///
    /// Set alongside ``Outcome/matched`` when the condition held on arrival and
    /// nothing was waited for, and alongside ``Outcome/timedOut`` when
    /// `requireFresh` made the wait look past it. Either way it separates "it
    /// happened before you asked" from "it never happened" — opposite problems
    /// that a bare timeout reports identically.
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
    /// The condition is checked before it is blocked on. A pattern already on
    /// screen returns at once, with ``OutputWait/matchedAtEntry`` set, because
    /// "wait until the server is listening" is answered by a server that is
    /// already listening. Pass `requiringFreshOutput` for the other reading:
    /// re-running a command whose output looks identical, where only a new
    /// occurrence counts.
    ///
    /// - Parameters:
    ///   - pane: the pane to watch.
    ///   - patterns: regular expressions, any of which ends the wait. Empty
    ///     means any new output at all does — the right choice when what the
    ///     pane prints is not known in advance.
    ///   - stops: regular expressions that end the wait as
    ///     ``OutputWait/Outcome/stopped``. A failure marker belongs here: a
    ///     build that fails at five seconds should not hold the wait open for
    ///     the rest of the timeout.
    ///   - requireFresh: only count output that arrives after this call, so a
    ///     match already on screen is waited past rather than returned.
    ///   - timeout: how long to wait before giving up.
    ///   - tailLimit: how many trailing lines to report back.
    public func waitForOutput(
        in pane: Pane,
        matching patterns: [String] = [],
        stoppingAt stops: [String] = [],
        requiringFreshOutput requireFresh: Bool = false,
        timeout: Duration = .seconds(30),
        tailLimit: Int = 20
    ) async throws(TmuxError) -> OutputWait {
        let matchers = try patterns.map(RegularExpression.init(pattern:))
        let stoppers = try stops.map(RegularExpression.init(pattern:))
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        let keptTail = max(0, tailLimit)

        // Establish an absolute cursor before reading the entry screen. A
        // second cursor read below catches anything that arrived between the
        // two, so opening the event connection cannot create a blind spot.
        var incremental = try await capture(pane, since: nil)
        let entryRows = try await capture(pane, startingAt: Self.waitLookback)
        let alreadyShowing = entryRows.firstIndex { row in
            matchers.contains { $0.matches(row) }
        }
        let wasAlreadyShowing = alreadyShowing != nil

        let answer: @Sendable ([String], [String]) -> OutputWait? = { arrived, tail in
            for line in arrived {
                if let hit = stoppers.firstIndex(where: { $0.matches(line) }) {
                    return OutputWait(
                        outcome: .stopped,
                        matched: stops[hit],
                        matchedIndex: hit,
                        sawNewOutput: true,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(tail.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
                guard !matchers.isEmpty else { continue }
                if let hit = matchers.firstIndex(where: { $0.matches(line) }) {
                    return OutputWait(
                        outcome: .matched,
                        matched: patterns[hit],
                        matchedIndex: hit,
                        sawNewOutput: true,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(tail.suffix(keptTail)),
                        seconds: Self.elapsed(since: started)
                    )
                }
            }
            guard matchers.isEmpty, !arrived.isEmpty else { return nil }
            return OutputWait(
                outcome: .matched,
                sawNewOutput: true,
                matchedAtEntry: wasAlreadyShowing,
                tail: Array(tail.suffix(keptTail)),
                seconds: Self.elapsed(since: started)
            )
        }

        let caughtAtEntry = try await capture(pane, since: incremental.cursor, limit: .max)
        incremental = caughtAtEntry
        let arrivedAtEntry = try await outputRows(after: caughtAtEntry, in: pane)
        var sawNewOutput = !arrivedAtEntry.isEmpty
        var newest = Array(arrivedAtEntry.suffix(keptTail))
        if let answer = answer(arrivedAtEntry, newest) { return answer }

        // Answered up front rather than inferred from a timeout: "already on
        // screen" and "never happened" look identical afterwards, and only one
        // of them is fixed by waiting longer.
        if let alreadyShowing, !requireFresh {
            let row = entryRows[alreadyShowing]
            let hit = matchers.firstIndex { $0.matches(row) }
            return OutputWait(
                outcome: .matched,
                matched: hit.map { patterns[$0] },
                matchedIndex: hit,
                sawNewOutput: false,
                matchedAtEntry: true,
                tail: Array(entryRows.suffix(keptTail)),
                seconds: Self.elapsed(since: started)
            )
        }

        while ContinuousClock.now < deadline {
            guard let attachment = try await waitAttachment(for: pane) else {
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
                guard ContinuousClock.now < deadline else { throw error }
                guard let current = try await waitAttachment(for: pane) else {
                    return OutputWait(
                        outcome: .paneClosed,
                        sawNewOutput: sawNewOutput,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: newest,
                        seconds: Self.elapsed(since: started)
                    )
                }
                guard current != attachment else { throw error }
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

        let closed = try await waitAttachment(for: pane) == nil
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
        answer: @escaping @Sendable ([String], [String]) -> OutputWait?
    ) async throws(TmuxError) -> OutputWaitCycle {
        let owner = self
        return try await connected(
            attachingTo: attachment.sessionID,
            expecting: pane.incarnation
        ) { (server: Server, control: ControlSession) async throws(TmuxError) -> OutputWaitCycle in
            let doorbell = WaitDoorbell(primed: true)
            let notifications = control.notifications
            return try await withTmuxErrorMapping {
                try await withThrowingTaskGroup(of: Void.self) { group in
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
                                let delta = try await server.capture(
                                    pane,
                                    since: cursor,
                                    limit: .max
                                )
                                cursor = delta.cursor
                                let arrived = try await server.outputRows(after: delta, in: pane)
                                sawNewOutput = sawNewOutput || !arrived.isEmpty
                                newest = Array((newest + arrived).suffix(tailLimit))
                                if let output = answer(arrived, newest) {
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

    private func outputRows(
        after capture: IncrementalCapture,
        in pane: Pane
    ) async throws(TmuxError) -> [String] {
        let rows =
            capture.restarted
            ? try await self.capture(pane, startingAt: Self.waitLookback)
            : capture.lines
        return rows.filter { !$0.isEmpty }
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

    /// How far above the visible region a wait reads.
    ///
    /// A pane producing output quickly scrolls it past the visible rows between
    /// one capture and the next, and a reader that only took those rows would
    /// miss whatever went by — the more output, the more it misses. Reading a
    /// bounded lookback each time makes that independent of how fast the reader
    /// was scheduled. Bounded rather than the whole history because this runs
    /// once per burst, and a scrollback is as long as the user configured it.
    static let waitLookback = CaptureStart.line(-200)

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

/// A compiled pattern, so an unusable one is reported when it is given rather
/// than silently matching nothing on every line.
struct RegularExpression: Sendable {
    private let expression: NSRegularExpression

    init(pattern: String) throws(TmuxError) {
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            throw TmuxError.invocationFailed(
                reason: "not a usable regular expression: \(pattern)"
            )
        }
    }

    func matches(_ line: String) -> Bool {
        expression.firstMatch(
            in: line,
            range: NSRange(line.startIndex..., in: line)
        ) != nil
    }
}
