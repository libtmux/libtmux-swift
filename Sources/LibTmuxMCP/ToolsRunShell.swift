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
                deadline: deadline,
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
        let markerNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let channel = "libtmux-mcp-done-\(nonce)"
        let releaseChannel = "libtmux-mcp-release-\(nonce)"
        let optionPrefix = "@libtmux_mcp_\(nonce)"
        let (cursor, paneWidth) = try await server.using(.direct) { server in
            let before = try await server.captureBounded(
                pane,
                since: nil,
                maximumLines: 1,
                perStreamOutputLimit: PaneOutputBudget.sourceBytes
            )
            guard let widthValue = try await server.formatGlobal("#{pane_width}", for: pane),
                let paneWidth = Int(widthValue), paneWidth > 0
            else {
                throw TmuxError.invocationFailed(reason: "pane reported an invalid width")
            }
            return (before.cursor, paneWidth)
        }
        // Leave the last column unused so tmux never delays a wrap between chunks.
        let markerWidth = max(1, min(paneWidth - 1, markerNonce.count + 1))

        return RunShellCleanup(
            channel: channel,
            releaseChannel: releaseChannel,
            statusOption: "\(optionPrefix)_status",
            cursor: cursor,
            startMarker: Self.markerRows("S\(markerNonce)", width: markerWidth),
            endMarker: Self.markerRows("E\(markerNonce)", width: markerWidth)
        )
    }

    private func dispatchRunShell(
        _ command: String,
        with cleanup: RunShellCleanup,
        in pane: Pane
    ) async throws {
        // Concealed cells survive capture; shellInvocation keeps bookkeeping on this server.
        let tmux = server.shellInvocation
        let target = shellQuoted(pane.id.rawValue)
        let startMarker = Self.markerCommand(cleanup.startMarker)
        let endMarker = Self.markerCommand(cleanup.endMarker)
        try await server.using(.direct) { server in
            try await server.sendKeys(
                [
                    "printf '\\r\\n'; \(startMarker); eval \(shellQuoted(command)); "
                        + "\(tmux) set-option -p -t \(target) "
                        + "\(cleanup.statusOption) $?; "
                        + "printf '\\r\\n'; \(endMarker); "
                        + "\(tmux) wait-for -S \(cleanup.channel); "
                        + "\(tmux) wait-for \(cleanup.releaseChannel)",
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
        deadline: ContinuousClock.Instant,
        enforcedTimeout: Double,
        maxLines: Int,
        started: ContinuousClock.Instant
    ) async throws -> ToolOutcome {
        try await server.using(.direct) { server in
            let captureLimit = try cleanup.captureLineLimit(for: maxLines)
            let output: RunShellOutput
            while true {
                do {
                    let capture = try await server.captureTailThroughCursor(
                        pane,
                        maximumLines: captureLimit,
                        perStreamOutputLimit: PaneOutputBudget.sourceBytes
                    )
                    if let parsed = try Self.runShellOutput(
                        capture.lines,
                        startMarker: cleanup.startMarker,
                        endMarker: cleanup.endMarker,
                        finished: finished,
                        maximumLines: maxLines
                    ) {
                        output = parsed
                        break
                    }
                } catch let error as TmuxError {
                    guard error == .staleServerValue, ContinuousClock.now < deadline else {
                        throw error
                    }
                }
                guard ContinuousClock.now < deadline else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell completed without an output end"
                    )
                }
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    throw TmuxError.cancelled
                }
            }
            let status =
                finished
                ? try await server.option(cleanup.statusOption, scope: .pane(pane)).flatMap(
                    Int.init)
                : nil
            if finished {
                guard status != nil else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell completed without an exit status"
                    )
                }
            }
            try await server.signal(cleanup.releaseChannel)
            await Self.clearRunShellOptions(cleanup, pane: pane, server: server)

            return .init(
                RunShellResult(
                    paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                    pane: pane.id.rawValue,
                    exitStatus: status,
                    timedOut: !finished,
                    output: output.lines,
                    linesMissed: output.linesMissed,
                    droppedLines: output.droppedLines,
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
                // The pane remains held at the release channel until cleanup
                // lets its shell print the next prompt.
                try? await server.using(.direct) { server in
                    try await server.signal(cleanup.releaseChannel)
                    await Self.clearRunShellOptions(cleanup, pane: pane, server: server)
                }
                await paneRuns.release(pane)
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
        let completed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    do {
                        try await server.wait(for: cleanup.channel)
                        return true
                    } catch {
                        // A failed wait client says nothing about the pane command.
                        guard !Task.isCancelled else { return false }
                        do {
                            try await Task.sleep(for: .milliseconds(100))
                        } catch {
                            return false
                        }
                    }
                }
                return false
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return false }
                    do {
                        guard try await server.incarnation() == pane.incarnation else {
                            return false
                        }
                        guard
                            try await server.formatGlobal("#{pane_dead}", for: pane) != "1"
                        else { return false }
                        let capture = try await server.captureBounded(
                            pane,
                            since: cleanup.cursor,
                            maximumLines: 1,
                            perStreamOutputLimit: PaneOutputBudget.sourceBytes
                        )
                        if capture.restarted { return false }
                    } catch let error as TmuxError {
                        switch error {
                        case .foreignServerValue, .serverRestarted:
                            return false
                        default:
                            continue
                        }
                    } catch {
                        continue
                    }
                }
                return false
            }
            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }
        if completed { try? await server.signal(cleanup.releaseChannel) }
        await clearRunShellOptions(cleanup, pane: pane, server: server)
    }

    private static func clearRunShellOptions(
        _ cleanup: RunShellCleanup,
        pane: Pane,
        server: Server
    ) async {
        _ = try? await server.unsetOption(cleanup.statusOption, scope: .pane(pane))
    }

    private enum RunShellLifetime {
        case preDispatch
        case submitting(RunShellCleanup)
        case started(RunShellCleanup)
        case finishing(RunShellCleanup)
    }

    private struct RunShellCleanup: Sendable {
        let channel: String
        let releaseChannel: String
        let statusOption: String
        let cursor: CaptureCursor
        let startMarker: [String]
        let endMarker: [String]

        func captureLineLimit(for maximumLines: Int) throws -> Int {
            // Separator, cursor row, and one row that proves truncation.
            let markerLines = startMarker.count + endMarker.count
            let (overhead, overheadOverflowed) = markerLines.addingReportingOverflow(3)
            let (limit, limitOverflowed) = maximumLines.addingReportingOverflow(overhead)
            guard maximumLines > 0, !overheadOverflowed, !limitOverflowed else {
                throw TmuxError.invocationFailed(reason: "run_shell capture size overflowed")
            }
            return limit
        }
    }

    private struct RunShellOutput {
        let lines: [String]
        let linesMissed: Bool
        let droppedLines: Int
    }

    private static func markerRows(_ marker: String, width: Int) -> [String] {
        let characters = Array(marker)
        return stride(from: 0, to: characters.count, by: width).map { start in
            String(characters[start..<min(start + width, characters.count)])
        }
    }

    private static func markerCommand(_ rows: [String]) -> String {
        // An echoed command line must not contain the complete marker token.
        let arguments = rows.map { row in
            let middle = row.index(row.startIndex, offsetBy: row.count / 2)
            return "'\(row[..<middle])''\(row[middle...])'"
        }
        return "printf '\\033[8m%s\\033[28m\\r\\n' "
            + arguments.joined(separator: " ")
    }

    private static func runShellOutput(
        _ captured: [String],
        startMarker: [String],
        endMarker: [String],
        finished: Bool,
        maximumLines: Int
    ) throws -> RunShellOutput? {
        let end = firstRange(of: endMarker, in: captured)
        if finished, end == nil { return nil }
        let outputEnd = end?.lowerBound ?? captured.endIndex
        let start = firstRange(of: startMarker, in: captured, before: outputEnd)
        var candidates = Array(captured[(start?.upperBound ?? captured.startIndex)..<outputEnd])
        if end != nil {
            if candidates.last?.isEmpty == true { candidates.removeLast() }
        } else {
            while candidates.last?.isEmpty == true { candidates.removeLast() }
        }

        let keptByLine = Array(candidates.suffix(maximumLines))
        let kept = try PaneOutputBudget.tail(
            keptByLine,
            afterDropping: candidates.count - keptByLine.count
        )
        return RunShellOutput(
            lines: kept.lines,
            linesMissed: start == nil,
            droppedLines: kept.droppedLines
        )
    }

    private static func firstRange(
        of marker: [String],
        in lines: [String],
        before end: Int? = nil
    ) -> Range<Int>? {
        let upperBound = min(end ?? lines.endIndex, lines.endIndex)
        guard !marker.isEmpty, marker.count <= upperBound else { return nil }
        for start in 0...(upperBound - marker.count) {
            let range = start..<(start + marker.count)
            if Array(lines[range]) == marker { return range }
        }
        return nil
    }

}
