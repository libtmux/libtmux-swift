import Foundation
import LibTmux

// The tools that change something.

extension TmuxTools {
    func runShell(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        let requested = try arguments.string("paneId")
        let force = try arguments.bool("force", or: false)
        let command = try arguments.string("command")
        let timeoutMs = try arguments.integer("timeoutMs", or: 30_000)
        let (timeout, enforced) = bounded(Double(timeoutMs) / 1_000)
        let maxLines = try arguments.integer("maxLines", or: 200)
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        let initial = try await preflightPaneInput(
            requested,
            scope: .singularPOSIXShell,
            force: force,
            operation: "run_shell_command"
        )
        try Self.requireSafeShellRoute(
            executable: server.tmuxExecutable,
            socketPath: initial.source.incarnation.socketPath,
            requiringTrapCapture: Self.capturesInheritedTraps(
                initial.source.currentCommand
            )
        )
        let pane = initial.source
        let reservation = try await Self.reservePaneInput(
            initial,
            operation: "run_shell_command"
        )
        var lifetime = RunShellLifetime.preDispatch
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolError.refusedForSafety(
                    "run_shell_command exceeded its timeout before setup"
                )
            }
            let cleanup = try await prepareRunShell(
                in: pane,
                command: command,
                tmuxInvocation: Self.pinnedTmuxInvocation(
                    executable: server.tmuxExecutable,
                    socketPath: pane.incarnation.socketPath
                )
            )
            try Task.checkCancellation()
            try Self.requireSafeShellRoute(
                executable: server.tmuxExecutable,
                socketPath: pane.incarnation.socketPath,
                requiringTrapCapture: Self.capturesInheritedTraps(
                    pane.currentCommand
                )
            )
            _ = try await preflightPaneInput(
                requested,
                scope: .singularPOSIXShell,
                force: force,
                transitionFrom: initial,
                reservation: reservation,
                operation: "run_shell_command"
            )
            lifetime = .submitting(cleanup)
            try await dispatchRunShell(with: cleanup)
            lifetime = .started(cleanup)
            let finished = try await waitForRunShell(
                cleanup,
                timeout: ContinuousClock.now.duration(to: deadline),
                progress: progress
            )
            if finished {
                lifetime = .finishing(cleanup)
            }
            try Task.checkCancellation()
            let outcome = try await finishRunShell(
                cleanup,
                finished: finished,
                enforcedTimeout: enforced,
                maxLines: maxLines,
                started: started
            )
            if finished {
                await Self.paneRuns.release(reservation)
            } else {
                schedulePaneRunCleanup(
                    cleanup,
                    waitForCompletion: true,
                    releaseWhenReady: false,
                    reservation: reservation
                )
            }
            return outcome
        } catch {
            switch lifetime {
            case .preDispatch:
                await Self.paneRuns.release(reservation)
            case .submitting(let cleanup):
                if Self.definitelyDidNotDispatch(error) {
                    await Self.paneRuns.release(reservation)
                } else {
                    await abandonRunShell(
                        cleanup,
                        waitForCompletion: true,
                        reservation: reservation
                    )
                }
            case .started(let cleanup):
                await abandonRunShell(
                    cleanup,
                    waitForCompletion: true,
                    reservation: reservation
                )
            case .finishing(let cleanup):
                await abandonRunShell(
                    cleanup,
                    waitForCompletion: false,
                    reservation: reservation
                )
            }
            throw error
        }
    }

    private func prepareRunShell(
        in pane: Pane,
        command: String,
        tmuxInvocation: String
    ) async throws -> RunShellCleanup {
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

        let partial = RunShellCleanup(
            pane: pane,
            channel: channel,
            releaseChannel: releaseChannel,
            statusOption: "\(optionPrefix)_status",
            cursor: cursor,
            startMarker: Self.markerRows("S\(markerNonce)", width: markerWidth),
            endMarker: Self.markerRows("E\(markerNonce)", width: markerWidth),
            payload: ""
        )
        return RunShellCleanup(
            pane: partial.pane,
            channel: partial.channel,
            releaseChannel: partial.releaseChannel,
            statusOption: partial.statusOption,
            cursor: partial.cursor,
            startMarker: partial.startMarker,
            endMarker: partial.endMarker,
            payload: Self.runShellPayload(
                command,
                tmuxInvocation: tmuxInvocation,
                nonce: nonce,
                cleanup: partial
            )
        )
    }

    private func dispatchRunShell(with cleanup: RunShellCleanup) async throws {
        try await server.using(.direct) { server in
            try await server.sendKeys([cleanup.payload, "Enter"], to: cleanup.pane)
        }
    }

    private func waitForRunShell(
        _ cleanup: RunShellCleanup,
        timeout: Duration,
        progress: ProgressReporter
    ) async throws -> Bool {
        let server = server
        do {
            return try await progress.whileRunning(
                upTo: timeout,
                describing: "running in \(cleanup.pane.id.rawValue)"
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
        finished: Bool,
        enforcedTimeout: Double,
        maxLines: Int,
        started: ContinuousClock.Instant
    ) async throws -> ToolOutcome {
        try await server.using(.direct) { server in
            let captureLimit = try cleanup.captureLineLimit(for: maxLines)
            let captureDeadline = ContinuousClock.now.advanced(
                by: Self.runShellCaptureSettleTimeout
            )
            let output: RunShellOutput
            var settle = Self.firstSettleDelay
            while true {
                do {
                    let capture = try await server.captureTailThroughCursor(
                        cleanup.pane,
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
                    guard error == .staleServerValue else { throw error }
                    guard ContinuousClock.now < captureDeadline else {
                        if !finished {
                            output = RunShellOutput(
                                lines: [],
                                linesMissed: true,
                                droppedLines: 0
                            )
                            break
                        }
                        throw error
                    }
                }
                guard ContinuousClock.now < captureDeadline else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell_command completed without an output end"
                    )
                }
                do {
                    try await Task.sleep(for: settle)
                    settle = Self.nextSettleDelay(after: settle)
                } catch {
                    throw TmuxError.cancelled
                }
            }
            let status =
                finished
                ? try await server.option(cleanup.statusOption, scope: .pane(cleanup.pane)).flatMap(
                    Int.init)
                : nil
            if finished {
                guard status != nil else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell_command completed without an exit status"
                    )
                }
            }
            try await server.signal(cleanup.releaseChannel)
            await Self.clearRunShellOptions(cleanup, server: server)

            return .init(
                RunShellResult(
                    paneRef: WireReferenceCodec.processLocal.reference(to: cleanup.pane),
                    pane: cleanup.pane.id.rawValue,
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
        waitForCompletion: Bool,
        releaseWhenReady: Bool,
        reservation: PaneInputReservation
    ) {
        let server = server
        Task {
            if waitForCompletion {
                try? await server.using(.direct) { server in
                    await Self.finishTimedOutRun(
                        cleanup,
                        server: server,
                        releaseWhenComplete: releaseWhenReady
                    )
                }
                await Self.paneRuns.release(reservation)
            } else {
                try? await server.using(.direct) { server in
                    if releaseWhenReady { try await server.signal(cleanup.releaseChannel) }
                    await Self.clearRunShellOptions(cleanup, server: server)
                }
                await Self.paneRuns.release(reservation)
            }
        }
    }

    private func abandonRunShell(
        _ cleanup: RunShellCleanup,
        waitForCompletion: Bool,
        reservation: PaneInputReservation
    ) async {
        let released = await releaseRunShellGate(cleanup)
        schedulePaneRunCleanup(
            cleanup,
            waitForCompletion: waitForCompletion,
            releaseWhenReady: !released,
            reservation: reservation
        )
    }

    private func releaseRunShellGate(_ cleanup: RunShellCleanup) async -> Bool {
        let server = server
        let release = Task<Bool, Never> {
            do {
                try await server.using(.direct) { server in
                    try await server.signal(cleanup.releaseChannel)
                }
                return true
            } catch {
                return false
            }
        }
        return await release.value
    }

    private static func definitelyDidNotDispatch(_ error: any Error) -> Bool {
        guard let tmuxError = error as? TmuxError else { return false }
        return switch tmuxError {
        case .commandTooLarge, .foreignServerValue, .processLaunchFailed,
            .requestNotSubmitted, .serverRestarted, .staleServerValue:
            true
        default:
            false
        }
    }

    private static func finishTimedOutRun(
        _ cleanup: RunShellCleanup,
        server: Server,
        releaseWhenComplete: Bool
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
                        guard try await server.incarnation() == cleanup.pane.incarnation else {
                            return false
                        }
                        guard
                            try await server.formatGlobal("#{pane_dead}", for: cleanup.pane) == "0"
                        else { return false }
                        let capture = try await server.captureBounded(
                            cleanup.pane,
                            since: cleanup.cursor,
                            maximumLines: 1,
                            perStreamOutputLimit: PaneOutputBudget.sourceBytes
                        )
                        if capture.restarted { return false }
                    } catch let error as TmuxError {
                        switch error {
                        case .commandFailed, .foreignServerValue, .serverRestarted:
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
        if completed, releaseWhenComplete {
            try? await server.signal(cleanup.releaseChannel)
        }
        await clearRunShellOptions(cleanup, server: server)
    }

    private static func clearRunShellOptions(
        _ cleanup: RunShellCleanup,
        server: Server
    ) async {
        _ = try? await server.unsetOption(cleanup.statusOption, scope: .pane(cleanup.pane))
    }

    private enum RunShellLifetime {
        case preDispatch
        case submitting(RunShellCleanup)
        case started(RunShellCleanup)
        case finishing(RunShellCleanup)
    }

    private struct RunShellCleanup: Sendable {
        let pane: Pane
        let channel: String
        let releaseChannel: String
        let statusOption: String
        let cursor: CaptureCursor
        let startMarker: [String]
        let endMarker: [String]
        let payload: String

        func captureLineLimit(for maximumLines: Int) throws -> Int {
            // Separator, cursor row, and one row that proves truncation.
            let markerLines = startMarker.count + endMarker.count
            let (overhead, overheadOverflowed) = markerLines.addingReportingOverflow(3)
            let (limit, limitOverflowed) = maximumLines.addingReportingOverflow(overhead)
            guard maximumLines > 0, !overheadOverflowed, !limitOverflowed else {
                throw TmuxError.invocationFailed(
                    reason: "run_shell_command capture size overflowed"
                )
            }
            return limit
        }
    }

    private struct RunShellOutput {
        let lines: [String]
        let linesMissed: Bool
        let droppedLines: Int
    }

    private static let runShellCaptureSettleTimeout = Duration.seconds(1)
    static let firstSettleDelay = Duration.milliseconds(10)
    static let longestSettleDelay = Duration.milliseconds(160)

    /// Doubles the wait between looks for the end marker, up to a ceiling.
    ///
    /// tmux parses the pane's bytes in its own event loop, and `wait-for`
    /// arrives on a separate connection, so the marker can be a moment behind
    /// the command that fired it. Nearly every run finds it on the first look;
    /// one that does not was costing a tmux process every ten milliseconds for
    /// as long as it took.
    static func nextSettleDelay(after previous: Duration) -> Duration {
        min(previous * 2, longestSettleDelay)
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
        return "/usr/bin/printf '\\033[8m%s\\033[28m\\r\\n' "
            + arguments.joined(separator: " ")
    }

    private static func pinnedTmuxInvocation(
        executable: String,
        socketPath: String
    ) -> String {
        [executable, "-u", "-S", socketPath].map(shellQuoted).joined(separator: " ")
    }

    private static func capturesInheritedTraps(_ currentCommand: String) -> Bool {
        var name =
            currentCommand.split(separator: "/", omittingEmptySubsequences: false).last
            .map(String.init) ?? currentCommand
        if name.first == "-" { name.removeFirst() }
        return name == "bash" || name == "zsh"
    }

    static func inheritedTrapCapture(
        currentCommand: String,
        nonce: String,
        declarations: String,
        captureStatus: String
    ) -> String {
        guard capturesInheritedTraps(currentCommand) else {
            return "\(declarations)=; \(captureStatus)=0"
        }

        let file = "__libtmux_mcp_trap_file_\(nonce)"
        let readDescriptor = 9
        let writeDescriptor = 8
        let readOwned = "__libtmux_mcp_trap_read_owned_\(nonce)"
        let writeOwned = "__libtmux_mcp_trap_write_owned_\(nonce)"
        let prefix = "/tmp/libtmux-mcp-traps-\(nonce)"
        let template = shellQuoted("\(prefix).XXXXXX")
        // Unlink before writing so every later path owns only open descriptors.
        // The trap builtin's redirection excludes output from the DEBUG action.
        let acquire: String
        let query: String
        if currentCommand.hasSuffix("bash") {
            let files = "__libtmux_mcp_trap_files_\(nonce)"
            let noglob = "__libtmux_mcp_trap_noglob_\(nonce)"
            acquire =
                "\(noglob)=0; case $- in *f*) \(noglob)=1 ;; esac; \\set +f; "
                + "\(files)=(); if /usr/bin/mktemp \(template) >/dev/null; then "
                + "\(files)=(\(shellQuoted(prefix)).??????); "
                + "if [ \"${#\(files)[@]}\" -eq 1 ]; then "
                + "\(file)=\"${\(files)[0]}\"; "
                + "else /bin/rm -f \"${\(files)[@]}\"; fi; fi; "
                + "if [ \"$\(noglob)\" -eq 1 ]; then \\set -f; fi"
            query = "\\trap -p ERR DEBUG"
        } else {
            acquire =
                "if /usr/bin/mktemp \(template) | IFS= \\read -r \(file); "
                + "then :; else \(file)=; fi"
            query = "\\trap"
        }

        let maximumBytes = 64 * 1_024
        return "\(declarations)=; \(captureStatus)=125; \(file)=; "
            + "\(readOwned)=0; \(writeOwned)=0; "
            + "\\umask 077; \(acquire); "
            + "if [ -n \"$\(file)\" ] && [ -f \"$\(file)\" ] "
            + "&& [ -O \"$\(file)\" ] "
            + "&& ! ( : >&\(writeDescriptor) ) 2>/dev/null "
            + "&& ! ( : <&\(writeDescriptor) ) 2>/dev/null "
            + "&& ! ( : >&\(readDescriptor) ) 2>/dev/null "
            + "&& ! ( : <&\(readDescriptor) ) 2>/dev/null "
            + "&& \\exec \(writeDescriptor)<> \"$\(file)\" "
            + "&& \(writeOwned)=1 "
            + "&& \\exec \(readDescriptor)< \"$\(file)\" "
            + "&& \(readOwned)=1 "
            + "&& /bin/rm -f \"$\(file)\"; then "
            + "if \(query) >&\(writeDescriptor); then \(captureStatus)=0; fi; fi; "
            + "\\trap - ERR DEBUG; "
            + "if [ \"$\(writeOwned)\" -eq 1 ]; then "
            + "if ! \\exec \(writeDescriptor)>&-; then \(captureStatus)=125; fi; "
            + "\(writeOwned)=0; fi; "
            + "if [ \"$\(captureStatus)\" -eq 0 ] "
            + "&& [ \"$\(readOwned)\" -eq 1 ]; then LC_ALL=C; "
            + "if \(declarations)=$(/usr/bin/head -c \(maximumBytes + 1) "
            + "<&\(readDescriptor)); then "
            + "if [ \"${#\(declarations)}\" -gt \(maximumBytes) ]; then "
            + "\(declarations)=; \(captureStatus)=125; fi; "
            + "else \(declarations)=; \(captureStatus)=125; fi; fi; "
            + "if [ \"$\(readOwned)\" -eq 1 ]; then "
            + "if ! \\exec \(readDescriptor)<&-; then \(captureStatus)=125; fi; "
            + "\(readOwned)=0; fi; "
            + "if [ -n \"$\(file)\" ]; then /bin/rm -f \"$\(file)\"; fi"
    }

    private static func runShellPayload(
        _ command: String,
        tmuxInvocation: String,
        nonce: String,
        cleanup: RunShellCleanup
    ) -> String {
        let flags = "__libtmux_mcp_flags_\(nonce)"
        let status = "__libtmux_mcp_status_\(nonce)"
        let commandText = "__libtmux_mcp_command_\(nonce)"
        let trapDeclarations = "__libtmux_mcp_traps_\(nonce)"
        let trapCaptureStatus = "__libtmux_mcp_trap_status_\(nonce)"
        let target = shellQuoted(cleanup.pane.id.rawValue)
        let start = markerCommand(cleanup.startMarker)
        let end = markerCommand(cleanup.endMarker)
        let finish =
            "\(status)=$?; "
            + "\(tmuxInvocation) set-option -p -t \(target) "
            + "\(shellQuoted(cleanup.statusOption)) \"$\(status)\"; "
            + "/usr/bin/printf '\\r\\n'; \(end); "
            + "\(tmuxInvocation) wait-for -S \(shellQuoted(cleanup.channel)); "
            + "\(tmuxInvocation) wait-for \(shellQuoted(cleanup.releaseChannel)); "
            + "\(tmuxInvocation) set-option -pu -t \(target) "
            + "\(shellQuoted(cleanup.statusOption)); \\exit 0"
        let remember =
            "case $- in *e*x*|*x*e*) \(flags)=ex ;; *e*) \(flags)=e ;; "
            + "*x*) \(flags)=x ;; *) \(flags)=none ;; esac"
        let restore =
            "case \"$\(flags)\" in ex) \\set -e; \\set -x ;; "
            + "e) \\set -e ;; x) \\set -x ;; esac"
        let captureTraps = inheritedTrapCapture(
            currentCommand: cleanup.pane.currentCommand,
            nonce: nonce,
            declarations: trapDeclarations,
            captureStatus: trapCaptureStatus
        )
        return "( \(remember); \\set +e; \\set +x; "
            + "\(commandText)=\(shellQuoted(command)); \(captureTraps); "
            + "\\trap \(shellQuoted(finish)) 0; "
            + "/usr/bin/printf '\\r\\n'; \(start); "
            + "if [ \"$\(trapCaptureStatus)\" -ne 0 ]; then \\exit 125; fi; "
            + "( \(restore); \\eval \"$\(trapDeclarations)\n$\(commandText)\" ); "
            + "\\exit \"$?\" )"
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
