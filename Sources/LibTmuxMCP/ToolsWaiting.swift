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
        let pane = try WireReferenceCodec.processLocal.resolve(
            try arguments.string("pane"),
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))
        let caseInsensitive = try arguments.bool("case_insensitive", or: false)
        let patterns = try ToolPattern.compile(
            arguments.optionalStrings("patterns") ?? [],
            argument: "patterns",
            caseInsensitive: caseInsensitive
        )
        let stops = try ToolPattern.compile(
            arguments.strings("stops"),
            argument: "stops",
            caseInsensitive: caseInsensitive
        )
        let fresh = try arguments.bool("require_fresh", or: false)
        let server = server
        let result: OutputWait
        do {
            result = try await progress.whileRunning(
                upTo: timeout,
                describing: "waiting on \(pane.id.rawValue)"
            ) {
                try await server.waitForOutput(
                    in: pane,
                    matching: patterns,
                    stoppingAt: stops,
                    requiringFreshOutput: fresh,
                    timeout: timeout
                )
            }
        } catch let error as OutputWaitError {
            switch error {
            case let .tmux(error): throw error
            case let .matching(error):
                throw ToolPattern.matchingFailure(error, argument: "patterns or stops")
            }
        }
        return .init(OutputWaitResult(result, pane: pane, effectiveTimeout: enforced))
    }

    func watchFormat(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        let paneID = try arguments.string("pane")
        let pane = try WireReferenceCodec.processLocal.resolve(
            paneID,
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
        let link = try await windowLink(
            for: pane, matching: try arguments.optionalString("window_link"))
        let format = try arguments.string("format")
        let caseInsensitive = try arguments.bool("case_insensitive", or: false)
        let matching = try arguments.optionalString("matching").map {
            try ToolPattern.compile(
                $0,
                argument: "matching",
                caseInsensitive: caseInsensitive
            )
        }
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))

        let started = ContinuousClock.now
        let outcome = try await progress.whileRunning(
            upTo: timeout,
            describing: "watching \(format) on \(paneID)"
        ) {
            try await server.connected(attachingTo: link.sessionID.rawValue) { _, control in
                try await control.watch(
                    FormatSubscription(
                        name: "libtmux-mcp-watch",
                        scope: .pane(pane.id),
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
                        for try await change in changes {
                            guard change.sessionID == link.sessionID,
                                change.windowID == link.windowID,
                                change.windowIndex == link.index,
                                change.paneID == pane.id
                            else { continue }
                            guard let matching else {
                                if isFirst {
                                    isFirst = false
                                    continue
                                }
                                return (change.value, true)
                            }
                            isFirst = false
                            if try ToolPattern.matches(
                                matching,
                                in: change.value,
                                argument: "matching"
                            ) {
                                return (change.value, true)
                            }
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
                    paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                    linkRef: WireReferenceCodec.processLocal.reference(to: link),
                    outcome: "timedOut",
                    value: try await server.format(format, for: pane, through: link),
                    seconds: seconds,
                    effectiveTimeout: enforced
                )
            )
        }
        return .init(
            FormatWatchResult(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                linkRef: WireReferenceCodec.processLocal.reference(to: link),
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
        let released: Bool
        do {
            released = try await progress.whileRunning(
                upTo: timeout,
                describing: "blocked on channel \(channel)"
            ) {
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try await server.wait(for: channel)
                        return true
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return false
                    }
                    let first = try await group.next() ?? false
                    // Cancelling the wait is what keeps a timeout from leaving a
                    // tmux process blocked on a channel nobody will ever signal.
                    group.cancelAll()
                    return first
                }
            }
        } catch {
            if Task.isCancelled { throw TmuxError.cancelled }
            throw error
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
        (ContinuousClock.now - start).secondsValue
    }
}
