import Foundation

/// What a wait on a pane's output ended on.
public struct OutputWait: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        /// One of `patterns` appeared in output that arrived during the wait.
        case matched
        /// One of `stops` appeared first. `matchedIndex` says which.
        case stopped
        /// Nothing matched before the deadline, in reads that finished.
        case timedOut
        /// The deadline arrived while a read of the pane was still in flight,
        /// so the wait never finished looking.
        ///
        /// This is not ``timedOut``: it does not say the pattern failed to
        /// appear, only that there was not time to find out. It answers a
        /// timeout shorter than a tmux round-trip — including a zero one —
        /// and a machine loaded enough to make an ordinary read miss an
        /// ordinary deadline. Retrying with a longer timeout is the fix;
        /// changing the pattern is not.
        case expiredWhileReading
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
    /// never ran, which no change of pattern will fix. Under
    /// ``Outcome/expiredWhileReading`` it says nothing: the reads that would
    /// have seen output did not finish.
    public let sawNewOutput: Bool
    /// A match or stop condition was already on screen when the wait began.
    /// It accompanies an immediate match or stop, or the later outcome when
    /// `requireFresh` made the wait look past it. Under
    /// ``Outcome/expiredWhileReading`` it is only meaningful if the entry
    /// screen itself was read.
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
        return try await OutputWaitSession(
            server: self,
            pane: pane,
            patterns: patterns,
            stops: stops,
            requireFresh: requireFresh,
            started: started,
            deadline: started.advanced(by: timeout),
            tailLimit: max(0, tailLimit),
            matchBudget: RegexMatchBudget()
        ).run()
    }
}
