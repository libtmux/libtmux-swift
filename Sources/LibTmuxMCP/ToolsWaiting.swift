import Foundation
import LibTmux

// The tools that block. Every one of them is bounded, cancellable, and says
// what it actually waited for — a wait that cannot be interrupted and cannot
// report why it ended is how an agent's turn gets spent on nothing.

extension TmuxTools {
    func waitForOutput(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))
        let patterns = try arguments.optionalStrings("patterns") ?? []
        let stops = try arguments.strings("stops")
        let fresh = try arguments.bool("require_fresh", or: false)
        let server = server
        let result = try await progress.whileRunning(
            upTo: timeout,
            describing: "waiting on \(pane.id)"
        ) {
            try await server.waitForOutput(
                in: pane,
                matching: patterns,
                stoppingAt: stops,
                requiringFreshOutput: fresh,
                timeout: timeout
            )
        }
        return .init(OutputWaitResult(result, effectiveTimeout: enforced))
    }

    func watchFormat(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        let paneID = try arguments.string("pane")
        let pane = try await pane(paneID)
        let format = try arguments.string("format")
        let matching = try arguments.optionalString("matching").map(MatchExpression.init)
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))

        guard let session = try await server.format("#{session_name}", for: pane) else {
            throw ToolError.refusedForSafety("pane \(paneID) has gone")
        }

        let started = ContinuousClock.now
        let outcome = try await progress.whileRunning(
            upTo: timeout,
            describing: "watching \(format) on \(paneID)"
        ) {
            try await server.connected(attachingTo: session) { _, control in
                try await control.watch(
                    FormatSubscription(
                        name: "libtmux-mcp-watch",
                        scope: .pane(paneID),
                        format: format
                    )
                )
                let changes = control.changes(named: "libtmux-mcp-watch")
                return try await withThrowingTaskGroup(of: (String, Bool)?.self) { group in
                    group.addTask {
                        // tmux sends the current value once when the subscription
                        // is made, so the first change is the starting point rather
                        // than a change — it is only reported when nothing was
                        // asked for.
                        var isFirst = true
                        for await change in changes {
                            guard let matching else {
                                if isFirst {
                                    isFirst = false
                                    continue
                                }
                                return (change.value, true)
                            }
                            isFirst = false
                            if matching.matches(change.value) { return (change.value, true) }
                        }
                        return nil
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return ("", false)
                    }
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first
                }
            }
        }

        let seconds = Self.elapsed(since: started)
        guard let outcome, outcome.1 else {
            return .init(
                FormatWatchResult(
                    outcome: "timedOut",
                    value: try await server.format(format, for: pane),
                    seconds: seconds,
                    effectiveTimeout: enforced
                )
            )
        }
        return .init(
            FormatWatchResult(
                outcome: "changed",
                value: outcome.0,
                seconds: seconds,
                effectiveTimeout: enforced
            )
        )
    }

    func waitForChannel(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        let channel = try arguments.string("channel")
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))
        let started = ContinuousClock.now
        let server = server
        let released = await progress.whileRunning(
            upTo: timeout,
            describing: "blocked on channel \(channel)"
        ) {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    (try? await server.wait(for: channel)) != nil
                }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let first = await group.next() ?? false
                // Cancelling the wait is what keeps a timeout from leaving a
                // tmux process blocked on a channel nobody will ever signal.
                group.cancelAll()
                return first
            }
        }
        return .init(
            ChannelWaitResult(
                channel: channel,
                released: released,
                seconds: Self.elapsed(since: started),
                effectiveTimeout: enforced
            )
        )
    }

    func signalChannel(_ arguments: Arguments) async throws -> ToolOutcome {
        let channel = try arguments.string("channel")
        try await server.signal(channel)
        return .init(ChannelSignalResult(channel: channel, signalled: true))
    }

    static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let interval = ContinuousClock.now - start
        return Double(interval.components.seconds)
            + Double(interval.components.attoseconds) / 1e18
    }
}
