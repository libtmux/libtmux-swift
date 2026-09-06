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
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let timeoutMs = try arguments.integer("timeoutMs", or: 30_000)
        let (timeout, enforced) = bounded(Double(timeoutMs) / 1_000)
        let isRegex = try arguments.bool("regex", or: false)
        let requested = try arguments.strings("patterns")
        let patterns =
            if isRegex {
                try ToolPattern.compile(requested, argument: "patterns")
            } else {
                try ToolPattern.compileLiteral(requested, argument: "patterns")
            }
        let requestedStops = try arguments.strings("stop")
        let stops =
            if isRegex {
                try ToolPattern.compile(requestedStops, argument: "stop")
            } else {
                try ToolPattern.compileLiteral(requestedStops, argument: "stop")
            }
        let maxLines = try arguments.integer("maxLines", or: 200)
        let cursor: CaptureCursor?
        if let encoded = try arguments.optionalString("cursor") {
            do {
                cursor = try JSONDecoder().decode(CaptureCursor.self, from: Data(encoded.utf8))
            } catch {
                throw ToolError.wrongArgumentType(
                    "cursor", expected: "a cursor returned by capture_since or wait_for_text"
                )
            }
        } else {
            cursor = nil
        }
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
                    requiringFreshOutput: cursor != nil,
                    startingAt: cursor,
                    timeout: timeout,
                    tailLimit: maxLines
                )
            }
        } catch let error as OutputWaitError {
            switch error {
            case let .tmux(error): throw error
            case let .matching(error):
                throw ToolPattern.matchingFailure(error, argument: "patterns")
            }
        }
        return .init(OutputWaitResult(result, pane: pane, effectiveTimeout: enforced))
    }

    func waitForChannel(
        _ arguments: Arguments,
        _ progress: ProgressReporter
    ) async throws -> ToolOutcome {
        let channel = try arguments.string("channel")
        let timeoutMs = try arguments.integer("timeoutMs", or: 30_000)
        let (timeout, enforced) = bounded(Double(timeoutMs) / 1_000)
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
