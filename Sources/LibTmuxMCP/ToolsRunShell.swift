import Foundation
import LibTmux

// The tools that change something.

extension TmuxTools {
    func runShell(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let command = try arguments.string("command")
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))
        let maxLines = try arguments.integer("max_lines", or: 200)
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)

        if await paneRuns.isHeld(pane),
            try await server.formatGlobal("#{pane_dead}", for: pane) == "1"
        {
            throw ToolError.refusedForSafety("pane \(pane.id.rawValue) has exited")
        }

        let acquired = await progress.whileRunning(
            upTo: timeout,
            describing: "waiting to run in \(pane.id.rawValue)"
        ) {
            await acquirePaneRun(pane, within: timeout)
        }
        guard acquired else {
            if Task.isCancelled { throw TmuxError.cancelled }
            throw ToolError.refusedForSafety(
                "pane \(pane.id.rawValue) is still running an earlier run_shell call"
            )
        }
        var lifetime = RunShellLifetime.preDispatch
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) did not become available before the timeout"
                )
            }
            let cleanup = try await prepareRunShell(in: pane)
            try Task.checkCancellation()
            lifetime = .submitting(cleanup)
            try await dispatchRunShell(command, with: cleanup, in: pane)
            lifetime = .started(cleanup)
            let finished = try await waitForRunShell(
                cleanup,
                in: pane,
                timeout: ContinuousClock.now.duration(to: deadline),
                progress: progress
            )
            if finished {
                lifetime = .finishing(cleanup)
            }
            try Task.checkCancellation()
            let outcome = try await finishRunShell(
                cleanup,
                in: pane,
                finished: finished,
                enforcedTimeout: enforced,
                maxLines: maxLines,
                started: started
            )
            if finished {
                await paneRuns.release(pane)
            } else {
                schedulePaneRunCleanup(cleanup, in: pane, waitForCompletion: true)
            }
            return outcome
        } catch {
            switch lifetime {
            case .preDispatch:
                await paneRuns.release(pane)
            case .submitting(let cleanup):
                if Self.definitelyDidNotDispatch(error) {
                    await paneRuns.release(pane)
                } else {
                    schedulePaneRunCleanup(cleanup, in: pane, waitForCompletion: true)
                }
            case .started(let cleanup):
                schedulePaneRunCleanup(cleanup, in: pane, waitForCompletion: true)
            case .finishing(let cleanup):
                schedulePaneRunCleanup(cleanup, in: pane, waitForCompletion: false)
            }
            throw error
        }
    }

    private func prepareRunShell(in pane: Pane) async throws -> RunShellCleanup {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let channel = "libtmux-mcp-done-\(nonce)"
        let optionPrefix = "@libtmux_mcp_\(nonce)"
        let before = try await server.using(.direct) { server in
            try await server.capture(pane, since: nil)
        }

        return RunShellCleanup(
            channel: channel,
            statusOption: "\(optionPrefix)_status",
            startOption: "\(optionPrefix)_start",
            endOption: "\(optionPrefix)_end",
            cursor: before.cursor
        )
    }

    private func dispatchRunShell(
        _ command: String,
        with cleanup: RunShellCleanup,
        in pane: Pane
    ) async throws {
        // `eval` reads the command as quoted data, so its trailing comments or
        // escapes cannot consume the bookkeeping suffix. The status goes into
        // a pane option rather than onto the screen and is read back exactly.
        //
        // Spelled through `shellInvocation` rather than as a bare `tmux`: that
        // would be whichever tmux is on the pane's PATH, and a client of a
        // different protocol version is refused with `server exited
        // unexpectedly` — which reaches the caller as a command that never
        // finished.
        let tmux = server.shellInvocation
        let target = shellQuoted(pane.id.rawValue)
        let position = shellQuoted("#{history_size}:#{cursor_y}")
        try await server.using(.direct) { server in
            try await server.sendKeys(
                [
                    "\(tmux) set-option -p -F -t \(target) "
                        + "\(cleanup.startOption) \(position); "
                        + "eval \(shellQuoted(command)); "
                        + "\(tmux) set-option -p -t \(target) "
                        + "\(cleanup.statusOption) $?; "
                        + "\(tmux) set-option -p -F -t \(target) "
                        + "\(cleanup.endOption) \(position); "
                        + "printf '\\n'; "
                        + "\(tmux) wait-for -S \(cleanup.channel)",
                    "Enter",
                ],
                to: pane
            )
        }
    }

    private func waitForRunShell(
        _ cleanup: RunShellCleanup,
        in pane: Pane,
        timeout: Duration,
        progress: ProgressReporter
    ) async throws -> Bool {
        let server = server
        do {
            return try await progress.whileRunning(
                upTo: timeout,
                describing: "running in \(pane.id.rawValue)"
            ) {
                try await withThrowingTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try await server.using(.direct) { server in
                            try await server.wait(for: cleanup.channel)
                        }
                        return true
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return false
                    }
                    let first = try await group.next() ?? false
                    group.cancelAll()
                    return first
                }
            }
        } catch {
            if Task.isCancelled { throw TmuxError.cancelled }
            throw error
        }
    }

    private func finishRunShell(
        _ cleanup: RunShellCleanup,
        in pane: Pane,
        finished: Bool,
        enforcedTimeout: Double,
        maxLines: Int,
        started: ContinuousClock.Instant
    ) async throws -> ToolOutcome {
        try await server.using(.direct) { server in
            async let startValue = server.paneOption(cleanup.startOption, of: pane)
            async let endValue = server.paneOption(cleanup.endOption, of: pane)
            async let statusValue = server.paneOption(cleanup.statusOption, of: pane)
            guard let start = try await RunShellPosition(startValue) else {
                throw TmuxError.invocationFailed(
                    reason: "run_shell completed without an output start"
                )
            }
            let end = try await RunShellPosition(endValue)
            let status = finished ? try await statusValue.flatMap(Int.init) : nil
            let after = try await server.captureTail(
                pane,
                fromAbsoluteRow: start.absoluteRow,
                throughAbsoluteRow: end?.absoluteRow,
                maximumLines: maxLines,
                perStreamOutputLimit: PaneOutputBudget.sourceBytes
            )
            let kept = try PaneOutputBudget.tail(
                after.lines,
                afterDropping: after.droppedLines
            )
            if finished {
                guard status != nil else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell completed without an exit status"
                    )
                }
            }
            await Self.clearRunShellOptions(cleanup, pane: pane, server: server)

            return .init(
                RunShellResult(
                    paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                    pane: pane.id.rawValue,
                    exitStatus: status,
                    timedOut: !finished,
                    output: kept.lines,
                    droppedLines: kept.droppedLines,
                    seconds: Self.elapsed(since: started),
                    effectiveTimeout: enforcedTimeout
                ),
            )
        }
    }

    private func schedulePaneRunCleanup(
        _ cleanup: RunShellCleanup,
        in pane: Pane,
        waitForCompletion: Bool
    ) {
        let paneRuns = paneRuns
        let server = server
        Task {
            if waitForCompletion {
                try? await server.using(.direct) { server in
                    await Self.finishTimedOutRun(cleanup, pane: pane, server: server)
                }
                await paneRuns.release(pane)
            } else {
                // The command has completed, so option cleanup cannot justify
                // holding the pane lease through another fallible tmux call.
                await paneRuns.release(pane)
                try? await server.using(.direct) { server in
                    await Self.clearRunShellOptions(cleanup, pane: pane, server: server)
                }
            }
        }
    }

    private static func definitelyDidNotDispatch(_ error: any Error) -> Bool {
        guard let tmuxError = error as? TmuxError else { return false }
        return switch tmuxError {
        case .foreignServerValue, .processLaunchFailed, .requestNotSubmitted,
            .serverRestarted, .staleServerValue:
            true
        default:
            false
        }
    }

    private func acquirePaneRun(_ pane: Pane, within timeout: Duration) async -> Bool {
        let coordinator = paneRuns
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await coordinator.acquire(pane)
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }

            let first = await group.next() ?? false
            if first {
                group.cancelAll()
                return true
            }

            group.cancelAll()
            while let acquired = await group.next() {
                if acquired { await coordinator.release(pane) }
            }
            return false
        }
    }

    private static func finishTimedOutRun(
        _ cleanup: RunShellCleanup,
        pane: Pane,
        server: Server
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await server.wait(for: cleanup.channel) }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    do {
                        guard
                            try await server.formatGlobal("#{pane_dead}", for: pane) != "1"
                        else { return }
                        let capture = try await server.capture(
                            pane,
                            since: cleanup.cursor,
                            limit: 0
                        )
                        if capture.restarted { return }
                    } catch let error as TmuxError {
                        switch error {
                        case .foreignServerValue, .serverRestarted, .staleServerValue:
                            return
                        default:
                            continue
                        }
                    } catch {
                        continue
                    }
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
        await clearRunShellOptions(cleanup, pane: pane, server: server)
    }

    private static func clearRunShellOptions(
        _ cleanup: RunShellCleanup,
        pane: Pane,
        server: Server
    ) async {
        for option in [cleanup.statusOption, cleanup.startOption, cleanup.endOption] {
            try? await server.unsetPaneOption(option, of: pane)
        }
    }

    private enum RunShellLifetime {
        case preDispatch
        case submitting(RunShellCleanup)
        case started(RunShellCleanup)
        case finishing(RunShellCleanup)
    }

    private struct RunShellCleanup: Sendable {
        let channel: String
        let statusOption: String
        let startOption: String
        let endOption: String
        let cursor: CaptureCursor
    }

    private struct RunShellPosition {
        let absoluteRow: Int

        init?(_ value: String?) {
            guard let value else { return nil }
            let fields = value.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2,
                let history = Int(fields[0]), history >= 0,
                let cursor = Int(fields[1]), cursor >= 0
            else { return nil }
            let (absoluteRow, overflowed) = history.addingReportingOverflow(cursor)
            guard !overflowed else { return nil }
            self.absoluteRow = absoluteRow
        }
    }

}

actor PaneRunCoordinator {
    private struct Key: Sendable, Hashable {
        let pane: PaneID
        let incarnation: ServerIncarnation

        init(_ pane: Pane) {
            self.pane = pane.id
            self.incarnation = pane.incarnation
        }
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held: Set<Key> = []
    private var waiters: [Key: [Waiter]] = [:]

    func isHeld(_ pane: Pane) -> Bool {
        held.contains(Key(pane))
    }

    func acquire(_ pane: Pane) async throws {
        let key = Key(pane)
        try Task.checkCancellation()
        if held.insert(key).inserted { return }

        let token = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[key, default: []].append(
                        Waiter(token: token, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(key, token: token) }
        }
        guard granted else { throw TmuxError.cancelled }
        if Task.isCancelled {
            release(key)
            throw TmuxError.cancelled
        }
    }

    func release(_ pane: Pane) {
        release(Key(pane))
    }

    private func release(_ key: Key) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters[key] = nil
            held.remove(key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.continuation.resume(returning: true)
    }

    private func cancel(_ key: Key, token: UUID) {
        guard var queued = waiters[key],
            let index = queued.firstIndex(where: { $0.token == token })
        else { return }
        let waiter = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }
}
