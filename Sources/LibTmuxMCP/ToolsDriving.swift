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
        let statusOption = "@libtmux_mcp_status_\(nonce)"
        let before = try await server.using(.direct) { server in
            try await server.capture(pane, since: nil)
        }

        return RunShellCleanup(
            channel: channel,
            statusOption: statusOption,
            cursor: before.cursor
        )
    }

    private func dispatchRunShell(
        _ command: String,
        with cleanup: RunShellCleanup,
        in pane: Pane
    ) async throws {
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
        try await server.using(.direct) { server in
            try await server.sendKeys(
                [
                    "\(command); \(tmux) set-option -p -t \(pane.id.rawValue) "
                        + "\(cleanup.statusOption) $?; "
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
            let after = try await server.capture(pane, since: cleanup.cursor, limit: .max)
            let produced = after.lines.filter { !$0.isEmpty }
            let kept = produced.suffix(maxLines)
            let status =
                finished
                ? try await server.paneOption(cleanup.statusOption, of: pane).flatMap(Int.init)
                : nil
            if finished {
                try? await server.unsetPaneOption(cleanup.statusOption, of: pane)
                guard status != nil else {
                    throw TmuxError.invocationFailed(
                        reason: "run_shell completed without an exit status"
                    )
                }
            }

            return .init(
                RunShellResult(
                    paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                    pane: pane.id.rawValue,
                    exitStatus: status,
                    timedOut: !finished,
                    output: Array(kept),
                    droppedLines: produced.count - kept.count,
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
                    try await server.unsetPaneOption(cleanup.statusOption, of: pane)
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
        try? await server.unsetPaneOption(cleanup.statusOption, of: pane)
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
        return .init(
            SentKeys(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                keys: keys
            )
        )
    }

    func newSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let session = try await server.newSession(
            named: try arguments.string("name"),
            startDirectory: try arguments.optionalString("start_directory"),
            windowName: try arguments.optionalString("window_name")
        )
        return .init(SessionResult(session))
    }

    func newWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let session = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.sessions(),
            argument: "target",
            refreshWith: "list_sessions"
        )
        let appearance = try await server.newWindow(
            in: session,
            named: try arguments.optionalString("name"),
            startDirectory: try arguments.optionalString("start_directory")
        )
        return .init(WindowOccurrenceResult(window: appearance.window, link: appearance.link))
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
        let created = try await server.split(
            pane,
            direction: direction,
            startDirectory: try arguments.optionalString("start_directory")
        )
        return .init(PaneResult(created))
    }

    func applyWorkspace(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let plan = try arguments.document("plan") else {
            throw ToolError.missingArgument("plan")
        }
        let workspace = try Workspace.decode(json: plan)
        let session = try await WorkspaceBuilder.build(workspace, on: server)
        let snapshot = try await server.snapshot()
        guard session.incarnation == snapshot.incarnation else {
            throw TmuxError.serverRestarted
        }
        let links = snapshot.windowLinks(of: session)
        return .init(
            WorkspaceResult(
                session: SessionResult(session),
                windows: WindowOccurrenceResult.projecting(
                    snapshot.windows(of: session),
                    through: links
                ),
                panes: snapshot.panes(of: session).map { PaneResult($0) }
            )
        )
    }

    func setOption(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let incarnation = try await server.incarnation() else {
            throw ToolError.refusedForSafety("the tmux server is not running")
        }
        let name = try arguments.string("name")
        let value = try arguments.string("value")
        let scope = try arguments.string("scope", or: "server")
        var flags: [String] = []
        switch scope {
        case "server": flags = ["-s"]
        case "global": flags = ["-g"]
        default: flags = []
        }
        let reply = try await server.runIsolated(
            TmuxCommand("set-option", flags + [name, value]),
            expecting: incarnation,
            perStreamOutputLimit: 65_536
        )
        return .init(
            CommandResult(
                serverRef: WireReferenceCodec.processLocal.reference(to: incarnation),
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
        return .init(
            Killed(
                ref: WireReferenceCodec.processLocal.reference(to: pane),
                kind: "pane",
                id: pane.id.rawValue
            )
        )
    }

    func killWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let window = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.windows(),
            argument: "target",
            refreshWith: "list_windows or snapshot"
        )
        try await guardForCaller()
            .checkWindow(
                window.id,
                override: try arguments.bool("confirm_self", or: false)
            )
        try await server.kill(window)
        return .init(
            Killed(
                ref: WireReferenceCodec.processLocal.reference(to: window),
                kind: "window",
                id: window.id.rawValue
            )
        )
    }

    func killSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let snapshot = try await server.snapshot()
        let session = try WireReferenceCodec.processLocal.resolve(
            target,
            among: snapshot.sessions,
            argument: "target",
            refreshWith: "list_sessions"
        )
        try CallerGuard(
            identity: caller,
            isSameServer: caller?.isOn(serverProcessID: snapshot.serverProcessID) ?? false
        )
        .checkSession(
            session.id,
            override: try arguments.bool("confirm_self", or: false)
        )
        try await server.kill(session)
        return .init(
            Killed(
                ref: WireReferenceCodec.processLocal.reference(to: session),
                kind: "session",
                id: session.id.rawValue
            )
        )
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
        let references = WireReferenceCodec.processLocal
        let snapshot = try await server.snapshot()
        switch try references.checkedKind(
            of: target,
            argument: "target",
            refreshWith: "list_sessions, list_windows, or snapshot"
        ) {
        case .window:
            let window = try references.resolve(
                target,
                among: snapshot.windows,
                argument: "target",
                refreshWith: "list_windows or snapshot"
            )
            try await server.rename(window, to: name)
            return .init(
                Renamed(
                    ref: references.reference(to: window),
                    kind: "window",
                    id: window.id.rawValue,
                    name: name
                )
            )
        case .session:
            let session = try references.resolve(
                target,
                among: snapshot.sessions,
                argument: "target",
                refreshWith: "list_sessions"
            )
            try await server.rename(session, to: name)
            return .init(
                Renamed(
                    ref: references.reference(to: session),
                    kind: "session",
                    id: session.id.rawValue,
                    name: name
                )
            )
        default:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "a session ref or global windowRef"
            )
        }
    }

    func select(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let references = WireReferenceCodec.processLocal
        let snapshot = try await server.snapshot()
        switch try references.checkedKind(
            of: target,
            argument: "target",
            refreshWith: "list_panes or list_windows"
        ) {
        case .pane:
            let pane = try references.resolve(
                target,
                among: snapshot.panes,
                argument: "target",
                refreshWith: "list_panes"
            )
            try await server.select(pane)
            return .init(
                Killed(
                    ref: references.reference(to: pane),
                    kind: "pane",
                    id: pane.id.rawValue
                )
            )
        case .windowLink:
            let link = try references.resolve(
                target,
                among: snapshot.windowLinks,
                argument: "target",
                refreshWith: "list_windows"
            )
            try await server.select(link)
            return .init(
                Killed(
                    ref: references.reference(to: link),
                    kind: "window-link",
                    id: link.target
                )
            )
        default:
            throw ToolError.wrongArgumentType(
                "target",
                expected: "a pane ref or exact window linkRef"
            )
        }
    }

    func resizePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let width = try arguments.optionalInteger("width")
        let height = try arguments.optionalInteger("height")
        guard width != nil || height != nil else {
            throw ToolError.missingArgument("width or height")
        }
        try await server.resize(pane, width: width, height: height)
        let after = try WireReferenceCodec.processLocal.resolve(
            WireReferenceCodec.processLocal.reference(to: pane),
            among: try await server.panes(),
            argument: "pane",
            refreshWith: "list_panes"
        )
        return .init(
            Resized(
                paneRef: WireReferenceCodec.processLocal.reference(to: after),
                pane: after.id.rawValue,
                width: after.width,
                height: after.height
            )
        )
    }

    func selectLayout(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let window = try WireReferenceCodec.processLocal.resolve(
            target,
            among: try await server.windows(),
            argument: "target",
            refreshWith: "list_windows or snapshot"
        )
        let layout = try arguments.string("layout")
        try await server.selectLayout(window, layout)
        return .init(
            LaidOut(
                windowRef: WireReferenceCodec.processLocal.reference(to: window),
                window: window.id.rawValue,
                layout: layout
            )
        )
    }

    func respawnPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        try await guardForCaller()
            .checkPane(pane.id, override: try arguments.bool("confirm_self", or: false))
        try await server.respawn(pane, running: try arguments.strings("command"))
        return .init(
            Respawned(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue
            )
        )
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
        return .init(
            Pasted(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                characters: text.count
            )
        )
    }

    func setEnvironment(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let incarnation = try await server.incarnation() else {
            throw ToolError.refusedForSafety("the tmux server is not running")
        }
        let name = try arguments.string("name")
        let value = try arguments.optionalString("value")
        let command = TmuxCommand(
            "set-environment",
            value.map { ["-g", name, $0] } ?? ["-g", "-u", name]
        )
        let reply = try await server.runIsolated(
            command,
            expecting: incarnation,
            perStreamOutputLimit: 65_536
        )
        guard reply.isSuccess else { throw ToolError.tmuxRejected(reply.errorText) }
        return .init(
            EnvironmentSet(
                serverRef: WireReferenceCodec.processLocal.reference(to: incarnation),
                name: name,
                value: value
            )
        )
    }

    func killServer(_ arguments: Arguments) async throws -> ToolOutcome {
        let incarnation = try await serverIncarnation(try arguments.string("server_ref"))
        let reference = WireReferenceCodec.processLocal.reference(to: incarnation)
        try await guardForCaller()
            .checkServer(override: try arguments.bool("confirm_self", or: false))
        try await server.killServer(expecting: incarnation)
        return .init(Killed(ref: reference, kind: "server", id: server.tmuxExecutable))
    }
}
