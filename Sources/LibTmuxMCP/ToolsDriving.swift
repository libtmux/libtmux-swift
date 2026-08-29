import Foundation
import LibTmux
import TmuxWorkspace

// The tools that change something.

extension TmuxTools {
    func runShell(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let command = try arguments.string("command")
        let (timeout, enforced) = bounded(try arguments.seconds("timeout", or: 30))
        let maxLines = max(1, try arguments.integer("max_lines", or: 200))
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
        do {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ToolError.refusedForSafety(
                    "pane \(pane.id.rawValue) did not become available before the timeout"
                )
            }
            let execution = try await runShell(
                command,
                in: pane,
                timeout: ContinuousClock.now.duration(to: deadline),
                enforcedTimeout: enforced,
                maxLines: maxLines,
                started: started,
                progress: progress
            )
            if let cleanup = execution.cleanup {
                let paneRuns = paneRuns
                Task {
                    await Self.finishTimedOutRun(
                        cleanup,
                        pane: pane,
                        server: server
                    )
                    await paneRuns.release(pane)
                }
            } else {
                await paneRuns.release(pane)
            }
            return execution.outcome
        } catch {
            await paneRuns.release(pane)
            throw error
        }
    }

    private func runShell(
        _ command: String,
        in pane: Pane,
        timeout: Duration,
        enforcedTimeout: Double,
        maxLines: Int,
        started: ContinuousClock.Instant,
        progress: ProgressReporter
    ) async throws -> RunShellExecution {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let channel = "libtmux-mcp-done-\(nonce)"
        let statusOption = "@libtmux_mcp_status_\(nonce)"
        let before = try await server.capture(pane, since: nil)
        // The status goes into a unique pane option rather than onto the screen: it is
        // read back exactly, and the pane the user is looking at gains no line
        // of bookkeeping. The `;` separators fire whether the command passed or
        // failed, so a failing command cannot leave the wait deadlocked.
        //
        // Spelled through `shellInvocation` rather than as a bare `tmux`: that
        // would be whichever tmux is on the pane's PATH, and a client of a
        // different protocol version is refused with `server exited
        // unexpectedly` — which reaches the caller as a command that never
        // finished.
        let tmux = server.shellInvocation
        try await server.sendKeys(
            [
                "\(command); \(tmux) set-option -p -t \(pane.id.rawValue) "
                    + "\(statusOption) $?; "
                    + "\(tmux) wait-for -S \(channel)",
                "Enter",
            ],
            to: pane
        )

        let server = server
        let finished = await progress.whileRunning(
            upTo: timeout,
            describing: "running in \(pane.id.rawValue)"
        ) {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { (try? await server.wait(for: channel)) != nil }
                group.addTask {
                    try? await Task.sleep(for: timeout)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
        }

        let after = try? await server.capture(pane, since: before.cursor, limit: .max)
        let produced = after?.lines.filter { !$0.isEmpty } ?? []
        let kept = produced.suffix(maxLines)
        let status =
            finished
            ? try await server.paneOption(statusOption, of: pane).flatMap(Int.init)
            : nil
        if finished {
            try? await server.unsetPaneOption(statusOption, of: pane)
            guard status != nil else {
                throw TmuxError.invocationFailed(
                    reason: "run_shell completed without an exit status"
                )
            }
        }

        return RunShellExecution(
            outcome: .init(
                RunShellResult(
                    pane: pane.id.rawValue,
                    exitStatus: status,
                    timedOut: !finished,
                    output: Array(kept),
                    droppedLines: produced.count - kept.count,
                    seconds: Self.elapsed(since: started),
                    effectiveTimeout: enforcedTimeout
                )
            ),
            cleanup: finished
                ? nil
                : RunShellCleanup(
                    channel: channel,
                    statusOption: statusOption,
                    cursor: before.cursor
                )
        )
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
        try? await server.unsetPaneOption(cleanup.statusOption, of: pane)
    }

    private struct RunShellExecution: Sendable {
        let outcome: ToolOutcome
        let cleanup: RunShellCleanup?
    }

    private struct RunShellCleanup: Sendable {
        let channel: String
        let statusOption: String
        let cursor: CaptureCursor
    }

    func sendKeys(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let keys = try arguments.strings("keys")
        guard !keys.isEmpty else { throw ToolError.missingArgument("keys") }
        try await server.sendKeys(
            keys,
            to: pane,
            literally: try arguments.bool("literal", or: false)
        )
        return .init(SentKeys(pane: pane.id.rawValue, keys: keys))
    }

    func newSession(_ arguments: Arguments) async throws -> ToolOutcome {
        .init(
            try await server.newSession(
                named: try arguments.string("name"),
                startDirectory: try arguments.optionalString("start_directory"),
                windowName: try arguments.optionalString("window_name")
            )
        )
    }

    func newWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        guard
            let session = try await server.sessions().first(where: {
                $0.id.rawValue == target || $0.name == target
            })
        else {
            throw ToolError.refusedForSafety(
                "no session \(target) on this server. Call list_sessions for what is there."
            )
        }
        return .init(
            try await server.newWindow(
                in: session,
                named: try arguments.optionalString("name"),
                startDirectory: try arguments.optionalString("start_directory")
            )
        )
    }

    func splitPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let direction: PaneDirection =
            switch try arguments.string("direction", or: "below") {
            case "right": .right
            case "above": .above
            case "left": .left
            default: .below
            }
        return .init(
            try await server.split(
                pane,
                direction: direction,
                startDirectory: try arguments.optionalString("start_directory")
            )
        )
    }

    func applyWorkspace(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let plan = try arguments.document("plan") else {
            throw ToolError.missingArgument("plan")
        }
        let workspace = try Workspace.decode(json: plan)
        let session = try await WorkspaceBuilder.build(workspace, on: server)
        let snapshot = try await server.snapshot()
        return .init(
            WorkspaceResult(
                session: session,
                windows: snapshot.windows(of: session),
                panes: snapshot.panes(of: session)
            )
        )
    }

    func setOption(_ arguments: Arguments) async throws -> ToolOutcome {
        let name = try arguments.string("name")
        let value = try arguments.string("value")
        let scope = try arguments.string("scope", or: "session")
        var flags: [String] = []
        switch scope {
        case "server": flags = ["-s"]
        case "global": flags = ["-g"]
        case "window": flags = ["-w"]
        case "pane": flags = ["-p"]
        default: flags = []
        }
        if let target = try arguments.optionalString("target") {
            flags += ["-t", target]
        }
        let reply = try await server.run(TmuxCommand("set-option", flags + [name, value]))
        return .init(
            CommandResult(
                exitCode: reply.exitCode,
                standardOutput: reply.text,
                standardError: reply.errorText
            )
        )
    }

    func killPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("pane")
        let pane = try await pane(target)
        try await guardForCaller()
            .checkPane(pane.id, override: try arguments.bool("confirm_self", or: false))
        try await server.kill(pane)
        return .init(Killed(kind: "pane", id: pane.id.rawValue))
    }

    func killWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        guard let window = try await server.windows().first(where: { $0.id.rawValue == target })
        else {
            throw ToolError.refusedForSafety("no window \(target) on this server")
        }
        try await guardForCaller()
            .checkWindow(
                window.id,
                panes: try await server.panes(),
                override: try arguments.bool("confirm_self", or: false)
            )
        try await server.kill(window)
        return .init(Killed(kind: "window", id: window.id.rawValue))
    }

    func killSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let snapshot = try await server.snapshot()
        guard
            let session = snapshot.sessions.first(where: {
                $0.id.rawValue == target || $0.name == target
            })
        else {
            throw ToolError.refusedForSafety("no session \(target) on this server")
        }
        try CallerGuard(
            identity: caller,
            isSameServer: caller?.isOn(serverProcessID: snapshot.serverProcessID) ?? false
        )
        .checkSession(
            session,
            in: snapshot,
            override: try arguments.bool("confirm_self", or: false)
        )
        try await server.kill(session)
        return .init(Killed(kind: "session", id: session.id.rawValue))
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

extension TmuxTools {
    func rename(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let name = try arguments.string("name")
        if let window = try await server.windows().first(where: { $0.id.rawValue == target }) {
            try await server.rename(window, to: name)
            return .init(Renamed(kind: "window", id: window.id.rawValue, name: name))
        }
        guard
            let session = try await server.sessions().first(where: {
                $0.id.rawValue == target || $0.name == target
            })
        else {
            throw ToolError.refusedForSafety(
                "no session or window \(target) on this server"
            )
        }
        try await server.rename(session, to: name)
        return .init(Renamed(kind: "session", id: session.id.rawValue, name: name))
    }

    func select(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        if let pane = try await server.panes().first(where: { $0.id.rawValue == target }) {
            try await server.select(pane)
            return .init(Killed(kind: "pane", id: pane.id.rawValue))
        }
        let links = try await server.windowLinks()
        let candidates = links.filter {
            $0.target == target || $0.windowID.rawValue == target
        }
        guard candidates.count == 1, let link = candidates.first else {
            if candidates.count > 1 {
                throw ToolError.refusedForSafety(
                    "window \(target) has several links; target one as $session:index"
                )
            }
            throw ToolError.refusedForSafety("no pane or window \(target) on this server")
        }
        try await server.select(link)
        return .init(Killed(kind: "window", id: link.windowID.rawValue))
    }

    func resizePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let width = try arguments.optionalInteger("width")
        let height = try arguments.optionalInteger("height")
        guard width != nil || height != nil else {
            throw ToolError.missingArgument("width or height")
        }
        try await server.resize(pane, width: width, height: height)
        let after = try await self.pane(pane.id.rawValue)
        return .init(
            Resized(pane: after.id.rawValue, width: after.width, height: after.height)
        )
    }

    func selectLayout(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        guard let window = try await server.windows().first(where: { $0.id.rawValue == target })
        else {
            throw ToolError.refusedForSafety("no window \(target) on this server")
        }
        let layout = try arguments.string("layout")
        try await server.selectLayout(window, layout)
        return .init(LaidOut(window: window.id.rawValue, layout: layout))
    }

    func respawnPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        try await server.respawn(pane, running: try arguments.strings("command"))
        return .init(Respawned(pane: pane.id.rawValue))
    }

    func pasteText(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let text = try arguments.string("text")
        // Named per call and deleted after: tmux's paste buffers are shared
        // with the user's own, and leaving one behind puts this text into a
        // history they will page through later.
        let buffer = "libtmux-mcp-\(UUID().uuidString.prefix(8))"
        try await server.setBuffer(text, named: buffer)
        defer { Task { try? await server.deleteBuffer(named: buffer) } }
        try await server.paste(buffer: buffer, into: pane)
        return .init(Pasted(pane: pane.id.rawValue, characters: text.count))
    }

    func setEnvironment(_ arguments: Arguments) async throws -> ToolOutcome {
        let scope = try environmentScope(arguments)
        let name = try arguments.string("name")
        guard let value = try arguments.optionalString("value") else {
            try await server.unsetEnvironment(name, in: scope)
            return .init(EnvironmentSet(name: name, value: nil))
        }
        _ = try await server.setEnvironment(name, to: value, in: scope)
        return .init(EnvironmentSet(name: name, value: value))
    }

    func killServer(_ arguments: Arguments) async throws -> ToolOutcome {
        try await guardForCaller()
            .checkServer(override: try arguments.bool("confirm_self", or: false))
        try await server.killServer()
        return .init(Killed(kind: "server", id: server.tmuxExecutable))
    }
}
