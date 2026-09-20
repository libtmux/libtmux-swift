import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// The tools that change something.

extension TmuxTools {
    func runShell(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent,
        stagingAt scriptPath: String? = nil
    ) async throws -> ToolOutcome {
        let requested = try arguments.string("paneId")
        let force = try arguments.bool("force", or: false)
        let command = try arguments.string("command")
        let timeoutMs = try arguments.integer("timeoutMs", or: 30_000)
        let (timeout, enforced) = bounded(Double(timeoutMs) / 1_000)
        let maxLines = try arguments.integer("maxLines", or: 200)
        let started = ContinuousClock.now
        let deadline = started.advanced(by: timeout)
        let resolved = try await withCommandDeadline(
            max(.zero, ContinuousClock.now.duration(to: deadline))
        ) { () async -> Result<PaneInputResolution, any Error> in
            do {
                return .success(
                    try await preflightPaneInput(
                        requested,
                        scope: .singularPOSIXShell,
                        force: force,
                        operation: "run_shell_command"
                    ))
            } catch { return .failure(error) }
        }
        let initial = try resolved.get()
        try Self.requireSafeShellRoute(
            executable: server.tmuxExecutable,
            socketPath: initial.source.incarnation.socketPath,
            requiringTrapCapture: Self.capturesInheritedTraps(
                initial.source.currentCommand
            )
        )
        let pane = initial.source
        // The caller owns reservations; deadline tasks may outlive it.
        let reservation = try await Self.reservePaneInput(
            initial,
            operation: "run_shell_command"
        )
        var lifetime = RunShellLifetime.preDispatch
        var stagedFile: RunShellFile?
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolError.refusedForSafety(
                    "run_shell_command exceeded its timeout before setup"
                )
            }
            let preparation = try await withCommandDeadline(
                max(.zero, ContinuousClock.now.duration(to: deadline))
            ) { () async -> Result<RunShellCleanup, any Error> in
                do {
                    let prepared = try await prepareRunShell(
                        in: pane,
                        command: command,
                        tmuxInvocation: Self.pinnedTmuxInvocation(
                            executable: server.tmuxExecutable,
                            socketPath: pane.incarnation.socketPath
                        ),
                        scriptPath: scriptPath
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
                    return .success(prepared)
                } catch { return .failure(error) }
            }
            let prepared = try preparation.get()
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolError.refusedForSafety(
                    "run_shell_command exceeded its timeout before staging"
                )
            }
            let (cleanup, dispatch) = try stageRunShell(with: prepared)
            stagedFile = cleanup.stagedFile
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolError.refusedForSafety(
                    "run_shell_command exceeded its timeout before input"
                )
            }
            lifetime = .submitting(cleanup)
            let echoTargets = [
                PaneEchoes.Key(incarnation: cleanup.pane.incarnation, pane: cleanup.pane.id)
            ]
            // The sourced dispatch line echoes; the script body does not.
            let echoUpdate = await Self.paneEchoes.apply(
                .keys([dispatch, "Enter"]), to: echoTargets)
            do {
                try await server.using(.direct) { server in
                    let target = cleanup.pane.id.rawValue
                    // `action` is a tmux command line if-shell will re-parse, not
                    // an argument handed to a POSIX shell, so it is quoted for
                    // tmux's own parser.
                    let action =
                        "set-option -p -t \(target) \(cleanup.statusOption) pending ; "
                        + ["send-keys", "-t", target, "--", dispatch, "Enter"]
                        .map(tmuxQuoted).joined(separator: " ")
                    let command = TmuxCommand("if-shell", ["-F", "1", action])
                    let reply = try await server.runIsolated(
                        command, guardingProcessOf: cleanup.pane, perStreamOutputLimit: 4_096)
                    guard reply.isSuccess else {
                        throw TmuxError.commandFailed(
                            command: "send-keys", exitCode: reply.exitCode, reason: reply.errorText)
                    }
                }
            } catch {
                if Self.definitelyDidNotDispatch(error) {
                    await Self.paneEchoes.abandon(echoUpdate)
                } else {
                    await Self.paneEchoes.commit(echoUpdate)
                }
                throw error
            }
            await Self.paneEchoes.commit(echoUpdate)
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
            let result = try await finishRunShell(
                cleanup,
                finished: finished,
                enforcedTimeout: enforced,
                maxLines: maxLines,
                started: started
            )
            if let status = result.exitStatus {
                // The command already ran, and `result` already carries its
                // exit status and output. A cleanup hiccup from here on must
                // not turn a completed call into a thrown error that discards
                // it, so a failure here falls back to the same background
                // retry the timeout path already relies on instead of
                // propagating and losing `result`.
                var releaseObserved = false
                do {
                    try await server.using(.direct) { server in
                        try await Self.releaseRunShell(cleanup, status: status, server: server)
                        try await Self.waitForRunShellRelease(cleanup, server: server)
                    }
                    releaseObserved = true
                    try await server.using(.direct) { server in
                        try await Self.clearRunShellStatus(cleanup, server: server)
                    }
                    Self.releaseRunShellFile(cleanup.stagedFile)
                    await Self.paneRuns.release(reservation)
                } catch {
                    let message =
                        "libtmux-mcp: run_shell_command completed but cleanup failed "
                        + "(\(error)); retrying in the background\n"
                    FileHandle.standardError.write(Data(message.utf8))
                    schedulePaneRunCleanup(
                        cleanup, reservation: reservation, releaseObserved: releaseObserved)
                }
            } else {
                schedulePaneRunCleanup(cleanup, reservation: reservation)
            }
            return .init(result)
        } catch {
            switch lifetime {
            case .preDispatch:
                Self.releaseRunShellFile(stagedFile)
                await Self.paneRuns.release(reservation)
            case .submitting(let cleanup):
                if Self.definitelyDidNotDispatch(error) {
                    Self.releaseRunShellFile(cleanup.stagedFile)
                    await Self.paneRuns.release(reservation)
                } else {
                    abandonRunShell(
                        cleanup,
                        reservation: reservation
                    )
                }
            case .started(let cleanup):
                abandonRunShell(
                    cleanup,
                    reservation: reservation
                )
            case .finishing(let cleanup):
                abandonRunShell(
                    cleanup,
                    reservation: reservation
                )
            }
            throw error
        }
    }

    private func prepareRunShell(
        in pane: Pane,
        command: String,
        tmuxInvocation: String,
        scriptPath: String?
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
            payload: "",
            scriptPath: scriptPath ?? "/tmp/libtmux-mcp-run-\(nonce)"
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
            ),
            scriptPath: partial.scriptPath
        )
    }

    /// Stages the frame so dispatch fits a canonical terminal's input limit.
    private func stageRunShell(with cleanup: RunShellCleanup) throws -> (RunShellCleanup, String) {
        let script = "\(cleanup.payload)\n"
        let descriptor = cleanup.scriptPath.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw TmuxError.invocationFailed(
                reason: "run_shell_command could not stage its command"
            )
        }
        defer { close(descriptor) }
        let stagedFile: RunShellFile
        do {
            stagedFile = try RunShellFile(path: cleanup.scriptPath, descriptor: descriptor)
        } catch {
            // The descriptor above is closed by `defer`, but nothing else
            // unlinks a path opened with O_CREAT|O_EXCL, and the path is
            // nonce-derived, so nothing will ever reuse or clean it up.
            _ = cleanup.scriptPath.withCString { unlink($0) }
            throw error
        }
        let bytes = Array(script.utf8)
        let wrote = bytes.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    // A signal-interrupted write is not a failure: the tests
                    // deliberately push payloads large enough to make EINTR
                    // more likely, and retrying is the standard POSIX response.
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                offset += written
            }
            return true
        }
        guard wrote else {
            Self.releaseRunShellFile(stagedFile)
            throw TmuxError.invocationFailed(
                reason: "run_shell_command could not stage its command"
            )
        }
        // Sourcing hides inherited Bash DEBUG declarations. Evaluating the file
        // read preserves them without capturing trap output from a cat command.
        let path = shellQuoted(cleanup.scriptPath)
        let dispatch =
            Self.capturesInheritedTraps(cleanup.pane.currentCommand)
            ? "\\eval \"$(<\(path))\"" : ". \(path)"
        var staged = cleanup
        staged.stagedFile = stagedFile
        return (staged, dispatch)
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
    ) async throws -> RunShellResult {
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
                    Self.runShellStatus)
                : nil
            if finished {
                guard status != nil else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell_command completed without an exit status"
                    )
                }
            }
            return RunShellResult(
                paneRef: WireReferenceCodec.processLocal.reference(to: cleanup.pane),
                pane: cleanup.pane.id.rawValue,
                exitStatus: status,
                timedOut: !finished,
                output: output.lines,
                linesMissed: output.linesMissed,
                droppedLines: output.droppedLines,
                seconds: Self.elapsed(since: started),
                effectiveTimeout: enforcedTimeout
            )
        }
    }

    private func schedulePaneRunCleanup(
        _ cleanup: RunShellCleanup,
        reservation: PaneInputReservation,
        releaseObserved: Bool = false
    ) {
        let server = server
        Task {
            try? await server.using(.direct) { server in
                await Self.finishTimedOutRun(
                    cleanup,
                    server: server,
                    reservation: reservation,
                    releaseObserved: releaseObserved
                )
            }
        }
    }

    private func abandonRunShell(
        _ cleanup: RunShellCleanup,
        reservation: PaneInputReservation
    ) {
        schedulePaneRunCleanup(cleanup, reservation: reservation)
    }

    static func definitelyDidNotDispatch(_ error: any Error) -> Bool {
        guard let tmuxError = error as? TmuxError else { return false }
        return switch tmuxError {
        case .commandTooLarge, .foreignServerValue, .processLaunchFailed,
            .rejectedLocally, .requestNotSubmitted, .serverRestarted, .staleServerValue:
            true
        default:
            false
        }
    }

    static func finishTimedOutRun(
        _ cleanup: RunShellCleanup,
        server: Server,
        reservation: PaneInputReservation,
        releaseObserved: Bool,
        proofTimeout: Duration = retainedRunProofTimeout
    ) async {
        let (proofs, continuation) = AsyncStream<RetainedRunProof>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        let completion = Task {
            var releaseObserved = releaseObserved
            while !Task.isCancelled {
                if !releaseObserved {
                    switch await retainedRunState(cleanup, server: server) {
                    case .completed(let status):
                        try? await releaseRunShell(cleanup, status: status, server: server)
                    case .released:
                        releaseObserved = true
                    case .releasing, nil:
                        break
                    }
                }
                if releaseObserved {
                    do {
                        try await clearRunShellStatus(cleanup, server: server)
                        continuation.yield(.released)
                        return
                    } catch {}
                }
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
        let presence = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                if await retainedRunEnded(cleanup.pane, server: server) {
                    continuation.yield(.ended)
                    return
                }
            }
        }
        // Bounded so a proof that never arrives cannot strand the reservation
        // and staged file forever: `completion` and `presence` otherwise
        // retry with no overall deadline, and `paneRuns` is process-wide, so
        // a stuck permit blocks every later run_shell_command on the pane
        // rather than just this one.
        let proof: RetainedRunProof? = await withTaskGroup(of: RetainedRunProof?.self) { group in
            group.addTask {
                var iterator = proofs.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: proofTimeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        continuation.finish()
        completion.cancel()
        presence.cancel()
        await paneRuns.release(reservation)
        releaseRunShellFile(cleanup.stagedFile)
        if proof == nil {
            let message =
                "libtmux-mcp: run_shell_command retained cleanup gave up confirming "
                + "release after \(proofTimeout); releasing the pane anyway\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        if proof == .ended {
            _ = try? await server.unsetOption(cleanup.statusOption, scope: .pane(cleanup.pane))
        }
    }

    /// How long retained cleanup waits for confirmation that a run released
    /// or its pane ended before giving up and releasing anyway. Matches
    /// `retryRunShellFileRemoval`'s default budget for the same reason: an
    /// unbounded wait here would hold a process-wide permit forever.
    private static let retainedRunProofTimeout = Duration.seconds(30)

    private static func retainedRunState(
        _ cleanup: RunShellCleanup,
        server: Server
    ) async -> RunShellState? {
        do {
            let before = try await server.incarnation()
            guard before == cleanup.pane.incarnation else { return nil }
            let status = try await server.option(
                cleanup.statusOption,
                scope: .pane(cleanup.pane)
            )
            let after = try await server.incarnation()
            guard after == cleanup.pane.incarnation else { return nil }
            if status == "releasing" { return .releasing }
            if status == "released" { return .released }
            return status.flatMap(runShellStatus).map(RunShellState.completed)
        } catch {
            return nil
        }
    }

    private static func releaseRunShell(
        _ cleanup: RunShellCleanup,
        status: Int,
        server: Server
    ) async throws {
        let target = cleanup.pane.id.rawValue
        // tmux toggles unmatched signals. Record release in the same command
        // queue so a lost reply cannot make a retry consume the pending signal.
        let action =
            "set-option -p -t \(target) \(cleanup.statusOption) releasing ; "
            + "wait-for -S -- \(cleanup.releaseChannel)"
        let command = TmuxCommand(
            "if-shell",
            [
                "-F", "-t", target,
                "#{==:#{\(cleanup.statusOption)},\(status)}", action,
            ]
        )
        let reply = try await server.runIsolated(
            command,
            expecting: cleanup.pane.incarnation,
            perStreamOutputLimit: 4_096
        )
        guard reply.isSuccess else {
            throw TmuxError.commandFailed(
                command: command.name, exitCode: reply.exitCode, reason: reply.errorText)
        }
    }

    private static func waitForRunShellRelease(
        _ cleanup: RunShellCleanup,
        server: Server
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: runShellCaptureSettleTimeout)
        var settle = firstSettleDelay
        while true {
            try Task.checkCancellation()
            if await retainedRunState(cleanup, server: server) == .released { return }
            guard ContinuousClock.now < deadline else {
                throw TmuxError.invocationFailed(
                    reason: "run_shell_command release was not acknowledged")
            }
            try await Task.sleep(for: settle)
            settle = nextSettleDelay(after: settle)
        }
    }

    private static func runShellStatus(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
            let status = Int(value), (0...255).contains(status), String(status) == value
        else {
            return nil
        }
        return status
    }

    private static func retainedRunEnded(_ pane: Pane, server: Server) async -> Bool {
        do {
            let before = try await server.incarnation()
            guard before == pane.incarnation else { return true }
            let reply = try await server.run(
                TmuxCommand("list-panes", ["-a", "-F", retainedPaneFormat])
            )
            let after = try await server.incarnation()
            guard after == pane.incarnation else { return true }
            guard reply.isSuccess else { return false }
            return retainedPaneEnded(pane, listing: reply.text)
        } catch {
            return retainedProcessEnded(pane.incarnation.processID)
        }
    }

    static func retainedPaneEnded(_ pane: Pane, listing: String) -> Bool {
        if listing.isEmpty { return true }
        var lines = listing.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty, lines.allSatisfy({ !$0.isEmpty }) else { return false }
        var panes: [PaneID: RetainedPaneState] = [:]
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return false }
            let paneID = String(fields[0])
            let windowID = String(fields[1])
            guard let id = PaneID(rawValue: paneID), UInt32(paneID.dropFirst()) != nil,
                let window = WindowID(rawValue: windowID), UInt32(windowID.dropFirst()) != nil,
                fields[2] == "0" || fields[2] == "1"
            else { return false }
            let row = RetainedPaneState(id: id, windowID: window, isDead: fields[2] == "1")
            if let existing = panes[row.id], existing != row { return false }
            panes[row.id] = row
        }
        guard let observed = panes[pane.id] else { return true }
        return observed.windowID == pane.windowID && observed.isDead
    }

    private static func retainedProcessEnded(_ processID: Int) -> Bool {
        guard processID > 0, processID <= Int(Int32.max) else { return false }
        errno = 0
        return kill(pid_t(processID), 0) == -1 && errno == ESRCH
    }

    private static func clearRunShellStatus(
        _ cleanup: RunShellCleanup,
        server: Server
    ) async throws {
        try await server.unsetOption(cleanup.statusOption, scope: .pane(cleanup.pane))
    }

    private static func releaseRunShellFile(_ file: RunShellFile?) {
        guard let file, file.remove() != .removed else { return }
        Task { await retryRunShellFileRemoval(file) }
    }

    /// Retries only local removal; pane or daemon lifetime cannot cancel ownership.
    static func retryRunShellFileRemoval(
        _ file: RunShellFile,
        within timeout: Duration = .seconds(30),
        reporting report: @Sendable (String) async -> Void = { message in
            FileHandle.standardError.write(Data("libtmux-mcp: \(message)\n".utf8))
        }
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var delay = Duration.milliseconds(100)
        while true {
            switch file.remove() {
            case .removed:
                return
            case .replaced:
                await report(
                    "run_shell_command cleanup stopped; preserved a replacement at \(file.path)")
                return
            case .failed(let code):
                guard ContinuousClock.now < deadline else {
                    await report(
                        "run_shell_command cleanup stopped for \(file.path) (errno \(code)); "
                            + "automatic retry budget expired; manual removal is required")
                    return
                }
            }
            do {
                try await Task.sleep(for: min(delay, ContinuousClock.now.duration(to: deadline)))
            } catch {
                await report(
                    "run_shell_command cleanup cancelled for \(file.path); manual removal is required"
                )
                return
            }
            delay = min(delay * 2, .seconds(1))
        }
    }

    struct RunShellFile: Sendable {
        let path: String
        private let device: UInt64
        private let inode: UInt64

        init(path: String, descriptor: Int32) throws(TmuxError) {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw .invocationFailed(
                    reason: "run_shell_command could not identify its staged command at \(path); "
                        + "manual removal is required")
            }
            self.path = path
            device = fileIdentityComponent(metadata.st_dev)
            inode = fileIdentityComponent(metadata.st_ino)
        }

        enum Removal: Equatable {
            case removed
            case replaced
            case failed(Int32)
        }

        func remove() -> Removal {
            var metadata = stat()
            // errno is captured inside each closure, immediately after the
            // call that set it: `withCString` bridges the Swift `String` to a
            // temporary C string and tears that buffer down once the closure
            // returns, and that teardown is free to touch errno before a
            // caller reading it afterward ever gets to.
            let (lstatResult, lstatErrno) = path.withCString { pointer -> (Int32, Int32) in
                let result = lstat(pointer, &metadata)
                return (result, errno)
            }
            guard lstatResult == 0 else {
                return lstatErrno == ENOENT ? .removed : .failed(lstatErrno)
            }
            guard fileIdentityComponent(metadata.st_dev) == device,
                fileIdentityComponent(metadata.st_ino) == inode
            else {
                return .replaced
            }
            let (unlinkResult, unlinkErrno) = path.withCString { pointer -> (Int32, Int32) in
                let result = unlink(pointer)
                return (result, errno)
            }
            if unlinkResult == 0 || unlinkErrno == ENOENT { return .removed }
            return .failed(unlinkErrno)
        }
    }

    private enum RunShellLifetime {
        case preDispatch
        case submitting(RunShellCleanup)
        case started(RunShellCleanup)
        case finishing(RunShellCleanup)
    }

    private enum RetainedRunProof {
        case released
        case ended
    }

    private enum RunShellState: Equatable {
        case completed(Int)
        case releasing
        case released
    }

    private struct RetainedPaneState: Equatable {
        let id: PaneID
        let windowID: WindowID
        let isDead: Bool
    }

    struct RunShellCleanup: Sendable {
        let pane: Pane
        let channel: String
        let releaseChannel: String
        let statusOption: String
        let cursor: CaptureCursor
        let startMarker: [String]
        let endMarker: [String]
        let payload: String
        let scriptPath: String
        var stagedFile: RunShellFile?

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
    private static let retainedPaneFormat = "#{pane_id}\t#{window_id}\t#{pane_dead}"
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
        let originalDaemon =
            "#{&&:#{==:#{pid},\(cleanup.pane.incarnation.processID)},"
            + "#{==:#{start_time},\(cleanup.pane.incarnation.startedAt)}}"
        let originalPane =
            "#{&&:\(originalDaemon),#{&&:#{==:#{pane_id},\(cleanup.pane.id.rawValue)},"
            + "#{==:#{pane_dead},0}}}"
        // A lost acknowledgment reply may be retried after cleanup removed it.
        // The guard prevents that retry from recreating the completed state.
        let acknowledge =
            "\(tmuxInvocation) if-shell -F -t \(target) "
            + "\(shellQuoted("#{&&:\(originalPane),#{==:#{\(cleanup.statusOption)},releasing}}")) "
            + shellQuoted(
                "set-option -p -t \(cleanup.pane.id.rawValue) \(cleanup.statusOption) released")
        let publish =
            "\(tmuxInvocation) if-shell -F -t \(target) "
            + "\(shellQuoted("#{&&:\(originalPane),#{==:#{\(cleanup.statusOption)},pending}}")) "
            + "\"set-option -p -t \(cleanup.pane.id.rawValue) "
            + "\(cleanup.statusOption) $\(status)\""
        let retry =
            "/bin/kill -0 \(cleanup.pane.incarnation.processID) 2>/dev/null || \\exit 0; "
            + "/bin/sleep 0.1"
        let completion =
            "\(tmuxInvocation) if-shell -F -t \(target) \(shellQuoted(originalPane)) "
            + shellQuoted("wait-for -S \(cleanup.channel)")
        let release =
            "\(tmuxInvocation) if-shell -F -t \(target) \(shellQuoted(originalPane)) "
            + shellQuoted("wait-for \(cleanup.releaseChannel)")
        let finish =
            "\(status)=$?; "
            + "until \(publish); do \(retry); done; "
            + "/usr/bin/printf '\\r\\n'; \(end); "
            + "until \(completion); do \(retry); done; "
            + "until \(release); do \(retry); done; "
            + "until \(acknowledge); do \(retry); done; \\exit 0"
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
