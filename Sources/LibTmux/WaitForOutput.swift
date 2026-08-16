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
    /// Waits until a pane prints something, without polling for it.
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
    /// when something actually happened.
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
    ) async throws -> OutputWait {
        let matchers = try patterns.map(RegularExpression.init(pattern:))
        let stoppers = try stops.map(RegularExpression.init(pattern:))

        guard let session = try await format("#{session_name}", for: pane) else {
            return OutputWait(
                outcome: .paneClosed,
                sawNewOutput: false,
                tail: [],
                seconds: 0
            )
        }

        let started = ContinuousClock.now
        // What the pane already showed. Matching only against rows that are
        // not in here is what makes re-running a command whose output looks
        // identical work: the wait ends on a fresh line, not on the one still
        // on screen from last time.
        let entryRows = try await capture(pane, startingAt: Self.waitLookback)
        let entry = Set(entryRows)
        // Answered up front rather than inferred from a timeout: "already on
        // screen" and "never happened" look identical afterwards, and only one
        // of them is fixed by waiting longer.
        let alreadyShowing = entryRows.firstIndex { row in
            matchers.contains { $0.matches(row) }
        }
        // The condition is checked before blocking on it, which is what any
        // other wait on a predicate does. "Wait until the server is listening"
        // is answered by a server that is already listening, and holding the
        // caller for the rest of the timeout to say so is the expensive way to
        // return a fact that was true on arrival. `requireFresh` is for the
        // other reading — re-running a command whose output looks identical,
        // where only a new occurrence counts.
        if let alreadyShowing, !requireFresh {
            let row = entryRows[alreadyShowing]
            let hit = matchers.firstIndex { $0.matches(row) }
            return OutputWait(
                outcome: .matched,
                matched: hit.map { patterns[$0] },
                matchedIndex: hit,
                sawNewOutput: false,
                matchedAtEntry: true,
                tail: Array(entryRows.suffix(tailLimit)),
                seconds: Self.elapsed(since: started)
            )
        }
        let wasAlreadyShowing = alreadyShowing != nil

        return try await connected(attachingTo: session) { server, control in
            // Primed, so the first thing the loop does is capture. Opening the
            // connection takes long enough that a caller acting immediately
            // after this call starts can finish before `%output` is being
            // delivered — and that output never arrives again. One capture up
            // front covers the window between the entry snapshot and a live
            // connection; everything after it is event-driven.
            let doorbell = Doorbell(primed: true)
            let paneID = pane.id

            // A pane that dies stops producing %output, so without this the
            // wait would run to the deadline having already lost its subject.
            try? await control.watch(
                FormatSubscription(
                    name: "libtmux-wait-dead",
                    scope: .pane(paneID),
                    format: "#{pane_dead}"
                )
            )

            return try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    for await notification in control.notifications {
                        switch notification.name {
                        case "output"
                        where notification.arguments.hasPrefix("\(paneID) "):
                            await doorbell.ring()
                        case "subscription-changed":
                            guard let change = SubscriptionChange(notification),
                                change.name == "libtmux-wait-dead",
                                change.value == "1"
                            else { continue }
                            await doorbell.close()
                        default:
                            continue
                        }
                    }
                    await doorbell.close()
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await doorbell.close()
                    return nil
                }
                group.addTask {
                    var seen = entry
                    var newest: [String] = []
                    while await doorbell.wait() {
                        // %output arrives per write, which for a typed line is
                        // one notification per character. Coalescing the burst
                        // is what keeps this cheaper than polling rather than
                        // far more expensive.
                        try await Task.sleep(for: .milliseconds(25))
                        let rows = try await server.capture(
                            pane,
                            startingAt: Self.waitLookback
                        )
                        let arrived = rows.filter { !$0.isEmpty && !seen.contains($0) }
                        guard !arrived.isEmpty else { continue }
                        seen.formUnion(arrived)
                        newest.append(contentsOf: arrived)

                        for line in arrived {
                            if let hit = stoppers.firstIndex(where: { $0.matches(line) }) {
                                return OutputWait(
                                    outcome: .stopped,
                                    matched: stops[hit],
                                    matchedIndex: hit,
                                    sawNewOutput: true,
                                    matchedAtEntry: wasAlreadyShowing,
                                    tail: Array(newest.suffix(tailLimit)),
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
                                    tail: Array(newest.suffix(tailLimit)),
                                    seconds: Self.elapsed(since: started)
                                )
                            }
                        }
                        if matchers.isEmpty {
                            return OutputWait(
                                outcome: .matched,
                                sawNewOutput: true,
                                matchedAtEntry: wasAlreadyShowing,
                                tail: Array(newest.suffix(tailLimit)),
                                seconds: Self.elapsed(since: started)
                            )
                        }
                    }
                    let alive = try? await server.format("#{pane_dead}", for: pane)
                    return OutputWait(
                        outcome: alive == "1" ? .paneClosed : .timedOut,
                        sawNewOutput: !newest.isEmpty,
                        matchedAtEntry: wasAlreadyShowing,
                        tail: Array(newest.suffix(tailLimit)),
                        seconds: Self.elapsed(since: started)
                    )
                }

                var answer: OutputWait?
                while let outcome = try await group.next() {
                    if let outcome {
                        answer = outcome
                        break
                    }
                }
                group.cancelAll()
                guard let answer else { throw TmuxError.connectionClosed }
                return answer
            }
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
    static let waitLookback = CaptureStart.rowsAbove(200)

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let interval = ContinuousClock.now - start
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
    }
}

/// Coalesces a burst of notifications into one wakeup.
///
/// A ring while nothing is waiting is remembered, so work that finishes
/// between two waits is not missed. Closing releases the waiter for good,
/// which is how a deadline or a dead pane ends the loop rather than a flag
/// checked between iterations.
actor Doorbell {
    private var isRung: Bool
    private var isClosed = false
    private var waiter: CheckedContinuation<Bool, Never>?

    init(primed: Bool = false) {
        isRung = primed
    }

    func ring() {
        guard !isClosed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: true)
        } else {
            isRung = true
        }
    }

    func close() {
        isClosed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: false)
        }
    }

    /// Suspends until the next ring. `false` means the doorbell closed and no
    /// further ring can arrive.
    func wait() async -> Bool {
        if isRung, !isClosed {
            isRung = false
            return true
        }
        if isClosed { return false }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

/// A compiled pattern, so an unusable one is reported when it is given rather
/// than silently matching nothing on every line.
struct RegularExpression: Sendable {
    private let expression: NSRegularExpression

    init(pattern: String) throws {
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
