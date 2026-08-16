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

        // Unique per call: a channel is server-wide, and a name two calls
        // shared would let one call's completion release the other's wait.
        let channel = "libtmux-mcp-\(UUID().uuidString.prefix(8))"
        let statusOption = "@libtmux_mcp_status"
        let before = Set(try await server.capture(pane))
        let started = ContinuousClock.now

        // The status goes into a pane option rather than onto the screen: it is
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
                "\(command); \(tmux) set-option -p \(statusOption) $?; "
                    + "\(tmux) wait-for -S \(channel)",
                "Enter",
            ],
            to: pane
        )

        let server = server
        let finished = await progress.whileRunning(
            upTo: timeout,
            describing: "running in \(pane.id)"
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

        // Best effort: a command can end the pane it ran in — `exit` is the
        // ordinary way — and the status and timing are still worth reporting
        // when there is no longer a pane to read.
        let after = (try? await server.capture(pane)) ?? []
        let produced = after.filter { !$0.isEmpty && !before.contains($0) }
        let kept = produced.suffix(maxLines)
        let status =
            finished
            ? (try? await server.format("#{\(statusOption)}", for: pane))?
                .flatMap(Int.init)
            : nil
        if finished {
            _ = try? await server.run(
                TmuxCommand("set-option", ["-p", "-t", pane.id, "-u", statusOption])
            )
        }

        return .init(
            RunShellResult(
                pane: pane.id,
                exitStatus: status,
                timedOut: !finished,
                output: Array(kept),
                droppedLines: produced.count - kept.count,
                seconds: Self.elapsed(since: started),
                effectiveTimeout: enforced
            )
        )
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
        return .init(SentKeys(pane: pane.id, keys: keys))
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
                $0.id == target || $0.name == target
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
        return .init(Killed(kind: "pane", id: pane.id))
    }

    func killWindow(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        guard let window = try await server.windows().first(where: { $0.id == target })
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
        return .init(Killed(kind: "window", id: window.id))
    }

    func killSession(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        guard
            let session = try await server.sessions().first(where: {
                $0.id == target || $0.name == target
            })
        else {
            throw ToolError.refusedForSafety("no session \(target) on this server")
        }
        try await guardForCaller()
            .checkSession(
                session.id,
                panes: try await server.panes(),
                override: try arguments.bool("confirm_self", or: false)
            )
        try await server.kill(session)
        return .init(Killed(kind: "session", id: session.id))
    }
}

extension TmuxTools {
    func rename(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        let name = try arguments.string("name")
        if let window = try await server.windows().first(where: { $0.id == target }) {
            try await server.rename(window, to: name)
            return .init(Renamed(kind: "window", id: window.id, name: name))
        }
        guard
            let session = try await server.sessions().first(where: {
                $0.id == target || $0.name == target
            })
        else {
            throw ToolError.refusedForSafety(
                "no session or window \(target) on this server"
            )
        }
        try await server.rename(session, to: name)
        return .init(Renamed(kind: "session", id: session.id, name: name))
    }

    func select(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        if let pane = try await server.panes().first(where: { $0.id == target }) {
            try await server.select(pane)
            return .init(Killed(kind: "pane", id: pane.id))
        }
        guard let window = try await server.windows().first(where: { $0.id == target })
        else {
            throw ToolError.refusedForSafety("no pane or window \(target) on this server")
        }
        try await server.select(window)
        return .init(Killed(kind: "window", id: window.id))
    }

    func resizePane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        let width = try arguments.optionalInteger("width")
        let height = try arguments.optionalInteger("height")
        guard width != nil || height != nil else {
            throw ToolError.missingArgument("width or height")
        }
        try await server.resize(pane, width: width, height: height)
        let after = try await self.pane(pane.id)
        return .init(Resized(pane: after.id, width: after.width, height: after.height))
    }

    func selectLayout(_ arguments: Arguments) async throws -> ToolOutcome {
        let target = try arguments.string("target")
        guard let window = try await server.windows().first(where: { $0.id == target })
        else {
            throw ToolError.refusedForSafety("no window \(target) on this server")
        }
        let layout = try arguments.string("layout")
        try await server.selectLayout(window, layout)
        return .init(LaidOut(window: window.id, layout: layout))
    }

    func respawnPane(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await pane(try arguments.string("pane"))
        try await server.respawn(pane, running: try arguments.strings("command"))
        return .init(Respawned(pane: pane.id))
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
        return .init(Pasted(pane: pane.id, characters: text.count))
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
