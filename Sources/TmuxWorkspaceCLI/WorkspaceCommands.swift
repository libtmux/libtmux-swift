import Foundation
import LibTmux
import TmuxWorkspace

enum WorkspaceCommands {
    static func server(
        _ socket: SocketOptions, configuration: String? = nil, colors256: Bool = false,
        context: CLIContext
    ) throws -> Server {
        let endpoint: Endpoint
        if let path = socket.path {
            endpoint = try Endpoint(socketPath: DocumentStore(context: context).path(path).path)
        } else if let name = socket.name {
            endpoint = try Endpoint(socketName: name)
        } else if let inherited = context.environment["TMUX"] {
            guard let tmux = TmuxContext(parsing: inherited) else {
                throw CLIError(
                    "usage", "TMUX does not contain a valid socket, PID and session index.",
                    status: 2)
            }
            endpoint = try Endpoint(socketPath: tmux.socketPath)
        } else {
            throw CLIError("usage", "Select a tmux endpoint with -S or -L outside tmux.", status: 2)
        }
        return Server(
            endpoint: endpoint, tmuxExecutable: context.environment["LIBTMUX_TMUX_BIN"] ?? "tmux",
            configurationFile: configuration, force256Colors: colors256)
    }

    /// Mirrors tmuxp's `TMUXP_DETECT_TERMINAL_SIZE`: the size passed to
    /// `new-session -x/-y` so the session's first window — and, since no
    /// client exists yet to force an early rescale, every window built after
    /// it — is laid out at the size the attaching client will actually show,
    /// not tmux's `default-size`. `nil` means detection is off: no -x/-y.
    static func sessionDimensions(context: CLIContext) throws -> (width: Int, height: Int)? {
        func named(_ names: [String], fallback: Int) throws -> Int {
            for name in names {
                guard let raw = context.environment[name], !raw.isEmpty else { continue }
                guard let value = Int(raw), (1...65535).contains(value) else {
                    throw CLIError("usage", "\(name) must be 1..65535", status: 2)
                }
                return value
            }
            return fallback
        }
        var width = try named(["TMUXP_DEFAULT_COLUMNS", "COLUMNS"], fallback: 80)
        var height = try named(["TMUXP_DEFAULT_ROWS", "ROWS"], fallback: 24)
        if let detect = context.environment["TMUXP_DETECT_TERMINAL_SIZE"], detect != "1" {
            return nil
        }
        if let size = context.stdoutSize {
            width = size.columns
            height = size.rows
        }
        width = try named(["COLUMNS"], fallback: width)
        height = try named(["LINES"], fallback: height)
        return (width, height)
    }

    static func load(_ command: Load, context: CLIContext, output: Presenter) async throws {
        guard !command.colors88 else {
            throw CLIError(
                "unsupported_color_mode",
                "tmux 3.2a and newer do not support 88-color mode (-8); use -2 or automatic detection.",
                status: 2)
        }
        guard !command.output.machine || command.detached || command.append else {
            throw CLIError("usage", "Machine load requires -d or --append.", status: 2)
        }
        // Inside tmux an attached load ends in switch-client, which needs no
        // terminal of its own; only outside tmux does attaching require one.
        guard
            command.detached || command.append
                || !(context.environment["TMUX"] ?? "").isEmpty
                || (context.terminal && context.inputTTY != nil)
        else {
            throw CLIError(
                "usage",
                "Attached load requires a foreground terminal. Use -d to load detached.",
                status: 2)
        }
        // Validated up front so a bad COLUMNS/LINES/TMUXP_DEFAULT_* fails the
        // same way whether or not this load ends up creating a session.
        let dimensions = try sessionDimensions(context: context)
        try await output.prepareProgress(command)
        let store = DocumentStore(context: context)
        if let file = command.logFile { try await output.openLog(store.path(file)) }
        let plans = try command.files.enumerated().map { index, input in
            let file = try store.resolve(input)
            return try normalize(
                store.read(file), file: file,
                override: index == command.files.count - 1 ? command.sessionName : nil, store: store
            )
        }
        let server = try server(
            command.socket, configuration: command.configurationFile, colors256: command.colors256,
            context: context)
        // Context is resolved — and a cross-server load refused — before
        // anything touches the selected server, including layout validation.
        let target = try await loadTarget(
            command, plans: plans, server: server, context: context, output: output)
        try await WorkspaceLayout.validate(plans.map(\.workspace), on: server)
        let borrowed: Session?
        if case let .append(session) = target { borrowed = session } else { borrowed = nil }
        let retained = AppendState()
        let failureCode = FailureCode()
        var results: [Value] = []
        var completedCount = 0
        var lastSession: Session?
        var currentInputIndex = 0
        try await output.event(
            "started", command: "load", data: .object(["inputs": .integer(Int64(plans.count))]))
        do {
            for (inputIndex, plan) in plans.enumerated() {
                currentInputIndex = inputIndex
                await retained.reset()
                try Task.checkCancellation()
                try await output.event(
                    "workspace-started", command: "load",
                    data: .object([
                        "session_name": .string(borrowed?.name ?? plan.workspace.sessionName),
                        "input": .string(plan.source),
                        "input_index": .integer(Int64(inputIndex)),
                        "window_total": .integer(Int64(plan.workspace.windows.count)),
                        "session_pane_total": .integer(
                            Int64(plan.workspace.windows.reduce(0) { $0 + $1.panes.count })),
                    ]))
                let existing: Session?
                if let borrowed {
                    existing = borrowed
                } else if try await server.isRunning() {
                    existing = try await server.sessions().first {
                        $0.name == plan.workspace.sessionName
                    }
                } else {
                    existing = nil
                }
                let session: Session
                if let existing, borrowed == nil {
                    session = existing
                } else {
                    session = try await WorkspaceBuilder.build(
                        plan.workspace, on: server, environment: plan.environment,
                        width: dimensions?.width, height: dimensions?.height,
                        configureSession: { session in
                            if borrowed != nil { await retained.begin() }
                            if let script = plan.beforeScript {
                                var processContext = context
                                processContext.directory = URL(
                                    fileURLWithPath: plan.workspace.startDirectory!)
                                try await output.event(
                                    "script-started", command: "load",
                                    data: .object(["input_index": .integer(Int64(inputIndex))]))
                                let result: ProcessCommands.Result
                                do {
                                    result = try await ProcessCommands.run(
                                        script, context: processContext
                                    ) { text, stream in
                                        try await output.event(
                                            "script-output", command: "load",
                                            data: .object([
                                                "input_index": .integer(Int64(inputIndex)),
                                                "stream": .string(stream), "text": .string(text),
                                            ]))
                                        try await output.bootstrap(text, stream: stream)
                                    }
                                } catch {
                                    // A script that cannot even start (missing,
                                    // not executable, ...) is a before_script
                                    // failure the same as a nonzero exit,
                                    // matching tmuxp's BeforeLoadScriptNotExists.
                                    if error is CancellationError { throw error }
                                    try await output.event(
                                        "script-completed", command: "load",
                                        data: .object([
                                            "input_index": .integer(Int64(inputIndex)),
                                            "child_status": .integer(0), "truncated": .bool(false),
                                        ]))
                                    await failureCode.set("script_failed")
                                    await failureCode.record(session)
                                    throw CLIError(
                                        "script_failed", WorkspaceCLI.message(for: error))
                                }
                                try await output.event(
                                    "script-completed", command: "load",
                                    data: .object([
                                        "input_index": .integer(Int64(inputIndex)),
                                        "child_status": .integer(Int64(result.code)),
                                        "truncated": .bool(false),
                                    ]))
                                guard result.code == 0 else {
                                    await failureCode.set("script_failed")
                                    await failureCode.record(session)
                                    throw CLIError(
                                        "script_failed",
                                        "before_script exited with status \(result.code).")
                                }
                            }
                            if borrowed != nil {
                                for (name, value) in plan.environment.sorted(by: { $0.key < $1.key }
                                ) {
                                    try requireSuccess(
                                        await server.setEnvironment(name, to: value, in: session))
                                }
                            }
                            for (name, value) in plan.options.sorted(by: { $0.key < $1.key }) {
                                try requireSuccess(
                                    await server.setOption(
                                        name, to: value, scope: .session(session)))
                            }
                            for (name, value) in plan.globalOptions.sorted(by: {
                                $0.key < $1.key
                            }) {
                                try requireSuccess(
                                    await server.setOption(name, to: value, scope: .globalSession))
                            }
                        },
                        configureWindow: { window, index in
                            if borrowed != nil { await retained.append(window.id.rawValue) }
                            for (name, value) in plan.windowOptions[index].sorted(by: {
                                $0.key < $1.key
                            }) {
                                try requireSuccess(
                                    await server.setOption(name, to: value, scope: .window(window)))
                            }
                        },
                        configureWindowAfter: { window, index in
                            for (name, value) in plan.windowOptionsAfter[index].sorted(by: {
                                $0.key < $1.key
                            }) {
                                try requireSuccess(
                                    await server.setOption(name, to: value, scope: .window(window)))
                            }
                        }, borrowing: borrowed,
                        onEvent: { event in
                            let name: String
                            var fields: [String: Value] = [
                                "input_index": .integer(Int64(inputIndex))
                            ]
                            switch event {
                            case let .sessionCreated(session):
                                name = "session-created"
                                fields.merge([
                                    "session_id": .string(session.id.rawValue),
                                    "session_name": .string(session.name),
                                ]) { _, new in new }
                            case let .windowStarted(index, window, session):
                                name = "window-created"
                                fields.merge([
                                    "session_id": .string(session.id.rawValue),
                                    "window_id": .string(window.id.rawValue),
                                    "window_name": .string(window.name),
                                    "window_index": .integer(Int64(index + 1)),
                                    "pane_total": .integer(
                                        Int64(plan.workspace.windows[index].panes.count)),
                                ]) { _, new in new }
                            case let .windowCompleted(index, window, session):
                                name = "window-completed"
                                fields.merge([
                                    "session_id": .string(session.id.rawValue),
                                    "window_id": .string(window.id.rawValue),
                                    "window_index": .integer(Int64(index + 1)),
                                ]) { _, new in new }
                            case let .paneStarted(windowIndex, index, pane, window, session):
                                name = "pane-created"
                                fields.merge([
                                    "session_id": .string(session.id.rawValue),
                                    "window_id": .string(window.id.rawValue),
                                    "pane_id": .string(pane.id.rawValue),
                                    "window_index": .integer(Int64(windowIndex + 1)),
                                    "pane_index": .integer(Int64(index + 1)),
                                ]) { _, new in new }
                            case let .paneCompleted(windowIndex, index, pane, window, session):
                                name = "pane-completed"
                                fields.merge([
                                    "session_id": .string(session.id.rawValue),
                                    "window_id": .string(window.id.rawValue),
                                    "pane_id": .string(pane.id.rawValue),
                                    "window_index": .integer(Int64(windowIndex + 1)),
                                    "pane_index": .integer(Int64(index + 1)),
                                ]) { _, new in new }
                            }
                            try await output.event(name, command: "load", data: .object(fields))
                        })
                }
                let result = Value.object([
                    "input": .string(plan.source), "input_index": .integer(Int64(inputIndex)),
                    "session_name": .string(session.name),
                    "session_id": .string(session.id.rawValue), "created": .bool(existing == nil),
                    "reused": .bool(existing != nil),
                    "action": .string(
                        borrowed != nil ? "appended" : existing == nil ? "created" : "reused"),
                ])
                results.append(result)
                completedCount += 1
                lastSession = session
                try await output.event("workspace-completed", command: "load", data: result)
            }
            // The envelope the other six ports already share: schema_version,
            // command, status, results, errors — not the former
            // status/workspaces pair.
            let result = Value.object([
                "schema_version": .integer(1), "command": .string("load"),
                "status": .string("ok"), "results": .array(results), "errors": .array([]),
            ])
            try await output.event("completed", command: "load", data: result)
            if command.output.json && !command.output.ndjson {
                try await output.result(result)
            } else if !command.output.machine {
                for result in results {
                    if borrowed != nil {
                        try await context.output(
                            "Appended \(Presenter.sanitize(result["session_name"]?.string ?? ""))")
                    } else {
                        try await output.row(
                            .object([
                                "name": result["session_name"] ?? .null,
                                "path": result["action"] ?? .null,
                            ]))
                    }
                }
            }
        } catch {
            let changed = await retained.started
            // WorkspaceBuilder.build's typed throws re-wraps whatever
            // configureSession/configureWindow raised as a generic tmux
            // failure, losing a CLIError's own code; failureCode carries the
            // precise one back for the known cases that set it.
            let overrideCode = await failureCode.value
            let code = overrideCode ?? WorkspaceCLI.canonicalCode(for: error)
            let message = WorkspaceCLI.message(for: error)
            // before_script failed after creating (and then rolling back) an
            // owned session: still name it, the way a later input's success
            // would, rather than leaving this input out of results[].
            if borrowed == nil, let failedSession = await failureCode.session {
                results.append(
                    .object([
                        "input": .string(plans[currentInputIndex].source),
                        "input_index": .integer(Int64(currentInputIndex)),
                        "session_id": .string(failedSession.id),
                        "session_name": .string(failedSession.name),
                        "reused": .bool(false),
                    ]))
            }
            var fields: [String: Value] = [
                "schema_version": .integer(1), "command": .string("load"),
                "status": .string(completedCount == 0 && !changed ? "error" : "partial"),
                "results": .array(results),
                "errors": .array([
                    .object([
                        "input_index": .integer(Int64(currentInputIndex)),
                        "code": .string(code), "message": .string(message),
                    ])
                ]),
            ]
            if let borrowed, changed {
                fields["retained_state"] = .object([
                    "ownership": .string("borrowed"),
                    "session_id": .string(borrowed.id.rawValue),
                    "session_name": .string(borrowed.name),
                    "window_ids": .array(await retained.windows.map(Value.string)),
                    "settings_may_have_changed": .bool(true),
                ])
            }
            let result = Value.object(fields)
            await output.failedLoad(result)
            // Re-throw with the restored code so the stderr diagnostic
            // matches errors[0].code instead of the generic one the wrapped
            // error would otherwise report.
            if let overrideCode { throw CLIError(overrideCode, message) }
            throw error
        }
        if case .switched = target, let session = lastSession {
            try await server.switchClient(to: session)
        } else if case let .attached(client) = target, let session = lastSession {
            if let client {
                try await server.switchClient(client, to: session)
            } else {
                guard try await server.incarnation() == session.incarnation else {
                    throw CLIError(
                        "attach_context", "The workspace's tmux server changed before attachment.")
                }
                var arguments = [server.tmuxExecutable, "-N", "-u"]
                if command.colors256 { arguments.append("-2") }
                switch server.endpoint {
                case let .socketPath(path): arguments += ["-S", path]
                case let .socketName(name): arguments += ["-L", name]
                }
                arguments += ["attach-session", "-t", session.id.rawValue]
                let result = try await ProcessCommands.run(
                    arguments, context: context, terminal: true)
                guard result.code == 0 else {
                    throw CLIError(
                        "attach_failed", "tmux attachment exited with status \(result.code).",
                        status: result.code)
                }
            }
        }
    }

    private enum LoadTarget {
        case detached
        case append(Session)
        case attached(Client?)
        /// Inside tmux, with no client identified for the invoking pane — a
        /// `run-shell` key binding sets `TMUX` but not `TMUX_PANE`. Switches
        /// without naming a client, letting tmux pick its own.
        case switched
    }

    private static func loadTarget(
        _ command: Load, plans: [PlannedWorkspace], server: Server, context: CLIContext,
        output: Presenter
    ) async throws -> LoadTarget {
        if command.detached { return .detached }
        if command.append {
            return .append(
                try await currentTarget(server, context: context, verifyTerminal: false).session)
        }
        let insideTmux = !(context.environment["TMUX"] ?? "").isEmpty
        if insideTmux {
            guard let inherited = TmuxContext(parsing: context.environment["TMUX"] ?? "") else {
                throw CLIError(
                    "usage", "TMUX does not contain a valid socket, PID and session index.",
                    status: 2)
            }
            // The context is decided before anything is built: a load aimed
            // at a server other than the current pane's is refused here,
            // whether or not that server is already running.
            try await verifySelectedServerMatches(inherited, selected: server)
        }
        let existingSession = try await existingTargetSession(plans, server: server)
        // Prompting needs a real foreground terminal on both ends; without
        // one this proceeds as though the default answer (yes) had been
        // given, the same as a script — including one with stdin closed
        // rather than piped, which a redirected stdout alone would miss.
        let canPrompt = context.terminal && context.inputTTY != nil
        if !command.yes, canPrompt, let existingSession {
            let answer = try await prompt(
                "\(existingSession.name) is already running. Attach? [Y/n]", context: context)
            if ["n", "no"].contains(answer) { return .detached }
        }
        guard insideTmux else { return .attached(nil) }
        guard let rawPane = context.environment["TMUX_PANE"], PaneID(rawValue: rawPane) != nil
        else { return .switched }
        let current = try await currentTarget(server, context: context, verifyTerminal: true)
        if !command.yes, canPrompt, existingSession == nil {
            while true {
                let answer = try await prompt(
                    "Load: [y] switch, [n] detached, [a] append, [q] cancel (y)", context: context)
                if ["n", "no", "d", "detached"].contains(answer) { return .detached }
                if ["a", "append"].contains(answer) { return .append(current.session) }
                if ["", "y", "yes", "s", "switch"].contains(answer) { break }
            }
        }
        guard !current.hasIndependentPaneClient else {
            throw CLIError(
                "load_context",
                "A client on this window uses active-pane; its current pane cannot be identified. Use -d or --append."
            )
        }
        guard !current.clients.isEmpty else {
            throw CLIError(
                "load_context", "No attached client views the current pane. Use -d or --append.")
        }
        if current.clients.count == 1 { return .attached(current.clients[0]) }
        guard !command.yes else {
            throw CLIError(
                "confirmation_required",
                "Several clients view this pane. Omit -y to choose a client, or use -d or --append.",
                status: 2)
        }
        let clients = current.clients.sorted { $0.name < $1.name }
        for (index, client) in clients.enumerated() {
            try await output.row(
                .object(["name": .string("[\(index + 1)]"), "path": .string(client.name)]))
        }
        while true {
            let answer = try await prompt(
                "Choose client (1-\(clients.count), q to cancel):", context: context
            )
            if let number = Int(answer), clients.indices.contains(number - 1) {
                return .attached(clients[number - 1])
            }
        }
    }

    /// The already-running session a load with this target name would
    /// switch or attach to, or `nil` when none by that name exists yet.
    private static func existingTargetSession(
        _ plans: [PlannedWorkspace], server: Server
    ) async throws -> Session? {
        guard let sessionName = plans.last?.workspace.sessionName, try await server.isRunning()
        else { return nil }
        return try await server.sessions().first { $0.name == sessionName }
    }

    /// Confirms `selected` — chosen via `-S`/`-L`, or inherited from `$TMUX`
    /// when neither was given — is the running server `$TMUX` names, without
    /// needing to identify a pane. Refuses with the same message whether or
    /// not `selected` is running yet, never a raw connection error.
    private static func verifySelectedServerMatches(
        _ inherited: TmuxContext, selected: Server
    ) async throws {
        let mismatch = CLIError(
            "usage", "Selected endpoint does not identify the current pane's server.", status: 2)
        guard
            let origin = try? await inherited.server(tmuxExecutable: selected.tmuxExecutable)
                .incarnation(),
            let incarnation = try? await selected.incarnation(),
            origin.processID == inherited.serverProcessID,
            incarnation.processID == origin.processID,
            incarnation.startedAt == origin.startedAt,
            incarnation.socketPath == origin.socketPath
        else { throw mismatch }
    }

    private static func prompt(_ message: String, context: CLIContext)
        async throws -> String
    {
        try await context.output(message)
        guard let input = context.input, let line = try await input() else {
            throw CLIError("cancelled", "Load cancelled.", status: 130)
        }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !["q", "quit", "cancel"].contains(answer) else {
            throw CLIError("cancelled", "Load cancelled.", status: 130)
        }
        return answer
    }

    private static func currentTarget(
        _ selected: Server, context: CLIContext, verifyTerminal: Bool,
        code requestedCode: String? = nil
    ) async throws -> (session: Session, clients: [Client], hasIndependentPaneClient: Bool) {
        // A context refusal — about how the command was invoked, not about
        // what tmux did — is code usage, exit 2, unless a caller (freeze)
        // asked for its own code, which keeps status 1.
        let code = requestedCode ?? "usage"
        let status: Int32 = requestedCode == nil ? 2 : 1
        guard let inherited = TmuxContext.current(environment: context.environment),
            let rawPane = context.environment["TMUX_PANE"], let paneID = PaneID(rawValue: rawPane)
        else { throw CLIError(code, "A valid TMUX and TMUX_PANE are required.", status: status) }
        let origin = try await inherited.server(tmuxExecutable: selected.tmuxExecutable)
            .incarnation()
        // Never a raw connection error: an unreachable or not-yet-running
        // selected server is exactly a server that isn't the current pane's.
        let snapshot: Snapshot
        do {
            snapshot = try await selected.snapshot()
        } catch {
            throw CLIError(
                code, "Selected endpoint does not identify the current pane's server.",
                status: status)
        }
        guard origin.processID == inherited.serverProcessID,
            snapshot.incarnation.processID == origin.processID,
            snapshot.incarnation.startedAt == origin.startedAt,
            snapshot.incarnation.socketPath == origin.socketPath,
            let pane = snapshot.panes.first(where: { $0.id == paneID })
        else {
            throw CLIError(
                code, "Selected endpoint does not identify the current pane's server.",
                status: status)
        }
        let links = snapshot.windowLinks.filter { $0.windowID == pane.windowID }
        let link =
            links.first { $0.sessionID == inherited.sessionID }
            ?? (links.count == 1 ? links.first : nil)
        guard let link, let session = snapshot.sessions.first(where: { $0.id == link.sessionID })
        else {
            throw CLIError(
                code, "The current pane's session is missing or ambiguous.", status: status)
        }
        if verifyTerminal {
            guard let tty = context.inputTTY,
                try await selected.format("#{pane_tty}", for: pane, through: link) == tty
            else {
                throw CLIError(code, "TMUX_PANE does not identify this terminal.", status: status)
            }
        }
        let windowPaneIDs = Set(
            snapshot.panes.lazy.filter { $0.windowID == pane.windowID }.map(\.id))
        return (
            session,
            snapshot.clients.filter {
                !$0.isControlMode && $0.sessionID == session.id && $0.activePaneID == pane.id
            },
            snapshot.clients.contains { client in
                !client.isControlMode && client.flags.contains("active-pane")
                    && client.activePaneID.map(windowPaneIDs.contains) == true
            }
        )
    }

    static func freeze(_ command: Freeze, context: CLIContext, output: Presenter) async throws {
        let server = try server(command.socket, context: context)
        let snapshot = try await emptyTolerantSnapshot(server)
        let session = try await freezeSession(
            command, snapshot: snapshot, server: server, context: context)
        // Fallback for a shell not on the common-name list below.
        let defaultShell = try await defaultShellBasename(for: session, server: server)
        var windows: [Value] = []
        for link in snapshot.windowLinks(of: session).sorted(by: { $0.index < $1.index }) {
            guard let window = snapshot.windows.first(where: { $0.id == link.windowID }) else {
                throw CLIError("stale_session", "A captured window disappeared.")
            }
            let panes = snapshot.panes(of: window).map { pane -> Value in
                var fields: [String: Value] = [
                    "start_directory": .string(pane.currentPath),
                    "focus": .bool(pane.isActive),
                ]
                // Omitted for the pane's own shell so reload starts a
                // plain pane, not a shell inside a shell.
                if !pane.currentCommand.isEmpty,
                    !isDefaultShellCommand(pane.currentCommand, defaultShell: defaultShell)
                {
                    fields["shell_command"] = .array([.string(pane.currentCommand)])
                }
                return .object(fields)
            }
            var value: [String: Value] = [
                "window_name": .string(window.name), "panes": .array(panes),
                "window_index": .integer(Int64(link.index)), "focus": .bool(link.isActive),
            ]
            if let layout = try await server.format("#{window_layout}", for: link) {
                value["layout"] = .string(layout)
            }
            // `options_after` applies once the panes exist, which is what
            // a captured `automatic-rename off` needs to hold.
            value["options_after"] = .object(
                try await freezeOptions(.window(window), server: server))
            windows.append(.object(value))
        }
        let document = Value.object([
            "session_name": .string(session.name), "windows": .array(windows),
            "options": .object(try await freezeOptions(.session(session), server: server)),
        ])
        // Checked before the warning below, not just inside store.save: a
        // destination that already exists should fail cleanly, not print an
        // explanatory note about a capture it is then refused. store.save's
        // own atomic check still governs a race against this one.
        if let destination = command.destination, !command.force {
            let file = DocumentStore(context: context).path(destination)
            guard !FileManager.default.fileExists(atPath: file.path) else {
                throw CLIError(
                    "destination_exists", "\(file.path) already exists; use --force to overwrite."
                )
            }
        }
        if !command.quiet {
            try await output.warning(
                "Capture preserves current commands, directories, layouts, indexes, focus and local options. Original arguments, scripts and session environment values are unavailable; global settings are omitted."
            )
        }
        if let destination = command.destination {
            let store = DocumentStore(context: context)
            let file = store.path(destination)
            let format =
                command.format ?? (file.pathExtension.lowercased() == "json" ? .json : .yaml)
            try store.save(document, to: file, format: format, overwrite: command.force)
            if command.output.machine {
                try await output.result(
                    .object(["path": .string(file.path), "workspace": document]))
            } else if !command.quiet {
                try await context.output("Saved \(Presenter.sanitize(file.path))")
            }
        } else if command.output.machine {
            try await output.document(document, command: "freeze")
        } else {
            try await context.output(
                DocumentStore(context: context).encode(document, format: command.format ?? .yaml))
        }
    }

    /// Common interactive shell basenames, recognised regardless of
    /// `default-shell`.
    private static let ordinaryShellNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "ash", "ksh", "mksh", "csh", "tcsh", "fish", "pwsh",
    ]

    /// Whether `command` is the pane's own no-explicit-command shell:
    /// a common name, or `defaultShell`'s basename. Both sides are
    /// stripped of the login-shell dash (`-bash`) first.
    static func isDefaultShellCommand(_ command: String, defaultShell: String?) -> Bool {
        let name = command.hasPrefix("-") ? String(command.dropFirst()) : command
        if ordinaryShellNames.contains(name) { return true }
        guard let defaultShell else { return false }
        return name == URL(fileURLWithPath: defaultShell).lastPathComponent
    }

    /// The basename of the session's effective `default-shell`, or `nil`
    /// if tmux has no answer for it.
    private static func defaultShellBasename(
        for session: Session, server: Server
    ) async throws -> String? {
        guard let shell = try await server.resolvedOption("default-shell", scope: .session(session))
        else { return nil }
        return URL(fileURLWithPath: shell).lastPathComponent
    }

    private static func freezeOptions(
        _ scope: OptionScope, server: Server
    ) async throws -> [String: Value] {
        var values: [String: Value] = [:]
        for option in try await server.options(scope) {
            if isListedVerbatim(option.value) {
                values[option.name] = .string(option.value)
                continue
            }
            guard let value = try await server.optionValue(option.name, scope: scope) else {
                throw CLIError("stale_session", "An option disappeared during capture.")
            }
            values[option.name] = .string(value)
        }
        return values
    }

    /// Whether the listing can be trusted to have printed a value as tmux
    /// stores it.
    ///
    /// `show-options` quotes a value holding whitespace or a quote, escapes a
    /// backslash, and spells a newline `\n`, so a value made only of the
    /// characters below went through none of that and needs no second read.
    private static func isListedVerbatim(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber
                        || "_-./=:@%+,".contains(character))
            }
    }

    /// `server.snapshot()`, tolerant of a server with no sessions at all.
    /// `list-windows -a`, `list-panes -a` and `list-clients` all fail
    /// outright there ("no current target"), even though `-a` asks for
    /// everything, so a plain snapshot would misreport an empty server as
    /// unreachable rather than as having no session to freeze.
    private static func emptyTolerantSnapshot(_ server: Server) async throws -> Snapshot {
        do {
            return try await server.snapshot()
        } catch {
            guard try await server.sessions().isEmpty else { throw error }
            return Snapshot(
                incarnation: try await server.incarnation(), sessions: [], windows: [],
                windowLinks: [], panes: [], clients: [])
        }
    }

    private static func freezeSession(
        _ command: Freeze, snapshot: Snapshot, server: Server, context: CLIContext
    ) async throws -> Session {
        if let name = command.sessionName {
            guard
                let session = snapshot.sessions.first(where: {
                    $0.name == name || $0.id.rawValue == name
                })
            else {
                throw CLIError("session_not_found", "Session not found: \(name)")
            }
            return session
        }
        if !(context.environment["TMUX"] ?? "").isEmpty {
            let current = try await currentTarget(
                server, context: context, verifyTerminal: false, code: "freeze_context")
            guard let session = snapshot.sessions.first(where: { $0 == current.session }) else {
                throw CLIError("stale_session", "The current session changed during capture.")
            }
            return session
        }
        let sessions = snapshot.sessions.sorted { $0.name < $1.name }
        if sessions.count == 1 { return sessions[0] }
        guard !sessions.isEmpty else {
            throw CLIError("session_not_found", "No live sessions to capture.")
        }
        guard !command.output.machine, context.terminal, let input = context.input else {
            throw CLIError(
                "session_required", "Several sessions are available; provide a session name or ID.",
                status: 2)
        }
        for (index, session) in sessions.enumerated() {
            try await context.error("[\(index + 1)] \(Presenter.sanitize(session.name))")
        }
        while true {
            try await context.error("Choose a session (1-\(sessions.count), q to cancel):")
            guard let line = try await input() else {
                throw CLIError("cancelled", "Capture cancelled.", status: 130)
            }
            let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if ["q", "quit", "cancel"].contains(answer.lowercased()) {
                throw CLIError("cancelled", "Capture cancelled.", status: 130)
            }
            if let index = Int(answer), index > 0, index <= sessions.count {
                return sessions[index - 1]
            }
            if let session = sessions.first(where: { $0.name == answer || $0.id.rawValue == answer }
            ) {
                return session
            }
        }
    }

    private struct PlannedWorkspace {
        let source: String
        let workspace: Workspace
        let environment: [String: String]
        let options: [String: String]
        let globalOptions: [String: String]
        let windowOptions: [[String: String]]
        let windowOptionsAfter: [[String: String]]
        let beforeScript: [String]?
    }

    private static func requireSuccess(_ reply: TmuxReply) throws {
        guard reply.isSuccess else { throw CLIError("tmux_failed", reply.errorText) }
    }

    static func validateImport(_ value: Value, file: URL, store: DocumentStore) throws {
        _ = try normalize(value, file: file, override: nil, store: store)
    }

    private static func normalize(
        _ value: Value, file: URL, override: String?, store: DocumentStore
    ) throws -> PlannedWorkspace {
        guard !containsNUL(value) else {
            throw CLIError("invalid_workspace", "Workspace values and keys cannot contain NUL.")
        }
        let root = try mapping(
            value,
            allowed: [
                "session_name", "start_directory", "windows", "shell_command_before",
                "suppress_history", "environment", "options", "global_options", "window_options",
                "before_script",
            ], at: "workspace")
        let expandedName = (override ?? root["session_name"]?.string).map {
            expand($0, environment: store.context.environment)
        }
        guard let name = expandedName, !name.isEmpty,
            !name.contains(":"), !name.contains("."), !name.contains("\n")
        else {
            throw CLIError(
                "invalid_workspace",
                "session_name must be a nonempty tmux session name without dots or colons.")
        }
        let rootDirectory =
            try directory(
                root["start_directory"], parent: file.deletingLastPathComponent(), store: store)
            ?? store.context.directory.path
        let history = try boolean(root["suppress_history"], fallback: true, at: "suppress_history")
        let environment = try scalarMapping(root["environment"], at: "environment", store: store)
        for name in environment.keys where name.isEmpty || name.contains("=") || name.contains("\0")
        {
            throw CLIError("invalid_workspace", "Invalid environment variable name.")
        }
        let options = try scalarMapping(root["options"], at: "options", store: store)
        // Distinct tmuxp keys, distinct set-option scopes.
        let globalOptions = try scalarMapping(
            root["global_options"], at: "global_options", store: store)
        let inheritedOptions = try scalarMapping(
            root["window_options"], at: "window_options", store: store)
        let beforeScript = try optionalString(root["before_script"], at: "before_script").map {
            try ProcessCommands.splitArguments(expand($0, environment: store.context.environment))
        }
        if let beforeScript,
            beforeScript.isEmpty || beforeScript[0].isEmpty
                || beforeScript.contains(where: { $0.contains("\0") })
        {
            throw CLIError("invalid_workspace", "before_script must name an executable.")
        }
        guard let source = root["windows"]?.array, !source.isEmpty else {
            throw CLIError("invalid_workspace", "windows must be a nonempty list.")
        }
        var windowOptions: [[String: String]] = []
        var windowOptionsAfter: [[String: String]] = []
        let windows = try source.enumerated().map { index, item in
            let window = try mapping(
                item,
                allowed: [
                    "window_name", "start_directory", "layout", "panes", "shell_command_before",
                    "suppress_history", "options", "options_after", "window_index", "focus",
                    "environment", "window_shell",
                ], at: "windows[\(index)]")
            windowOptions.append(
                inheritedOptions.merging(
                    try scalarMapping(window["options"], at: "window.options", store: store)
                ) { _, local in local })
            // Both spellings load; `freeze` emits `options_after`.
            windowOptionsAfter.append(
                try scalarMapping(
                    window["options_after"], at: "window.options_after", store: store))
            let windowDirectory =
                try directory(
                    window["start_directory"], parent: URL(fileURLWithPath: rootDirectory),
                    store: store) ?? rootDirectory
            let suppress = try boolean(
                window["suppress_history"], fallback: history, at: "suppress_history")
            let windowEnvironment = try window["environment"].map {
                try scalarMapping($0, at: "window.environment", store: store)
            }
            let windowShell = try optionalString(window["window_shell"], at: "window_shell")
            let before =
                entries(root["shell_command_before"]) + entries(window["shell_command_before"])
            // `panes: []` builds one pane with no command, the same as
            // omitting a command on the sole implicit pane.
            let sourcePanes: [Value]
            if let paneValue = window["panes"] {
                guard let array = paneValue.array else {
                    throw CLIError("invalid_workspace", "panes must be a list.")
                }
                sourcePanes = array.isEmpty ? [.null] : array
            } else {
                throw CLIError("invalid_workspace", "panes must be a nonempty list.")
            }
            let panes = try sourcePanes.map { item in
                let pane: [String: Value]
                switch item {
                case .object:
                    pane = try mapping(
                        item,
                        allowed: [
                            "start_directory", "shell_command", "shell_command_before",
                            "suppress_history", "enter", "focus", "environment", "shell",
                            "sleep_before", "sleep_after",
                        ], at: "pane")
                default: pane = ["shell_command": item]
                }
                let history = try boolean(
                    pane["suppress_history"], fallback: suppress, at: "suppress_history")
                var enter = try boolean(pane["enter"], fallback: true, at: "enter")
                let commands = try
                    (before + entries(pane["shell_command_before"]) + entries(pane["shell_command"]))
                    .compactMap { value -> TmuxShellCommand? in
                        if value == .null { return nil }
                        let text: String
                        if let string = value.string {
                            if ["blank", "pane"].contains(string) { return nil }
                            text = string
                        } else {
                            let command = try mapping(
                                value, allowed: ["cmd", "enter"], at: "command")
                            guard let cmd = command["cmd"]?.string else {
                                throw CLIError("invalid_workspace", "cmd must be a string.")
                            }
                            text = cmd
                            enter = try boolean(command["enter"], fallback: enter, at: "enter")
                        }
                        return TmuxShellCommand(
                            (history ? " " : "")
                                + expand(text, environment: store.context.environment), enter: enter
                        )
                    }
                return PanePlan(
                    shellCommands: commands,
                    startDirectory: try directory(
                        pane["start_directory"], parent: URL(fileURLWithPath: windowDirectory),
                        store: store) ?? windowDirectory,
                    focus: try boolean(pane["focus"], fallback: false, at: "pane.focus"),
                    environment: try pane["environment"].map {
                        try scalarMapping($0, at: "pane.environment", store: store)
                    },
                    shell: try optionalString(pane["shell"], at: "shell"),
                    sleepBefore: try optionalDouble(pane["sleep_before"], at: "sleep_before"),
                    sleepAfter: try optionalDouble(pane["sleep_after"], at: "sleep_after"))
            }
            return WindowPlan(
                windowName: try optionalString(window["window_name"], at: "window_name"),
                startDirectory: windowDirectory,
                layout: try optionalString(window["layout"], at: "layout"), panes: panes,
                windowIndex: try windowIndex(window["window_index"]),
                focus: try boolean(window["focus"], fallback: false, at: "window.focus"),
                environment: windowEnvironment, windowShell: windowShell)
        }
        let indexes = windows.compactMap(\.windowIndex)
        guard Set(indexes).count == indexes.count else {
            throw CLIError("invalid_workspace", "Each explicit window_index must be unique.")
        }
        guard windows.filter({ $0.focus == true }).count <= 1,
            windows.allSatisfy({ $0.panes.filter { $0.focus == true }.count <= 1 })
        else {
            throw CLIError(
                "invalid_workspace", "Choose one focused window and one focused pane per window.")
        }
        return PlannedWorkspace(
            source: file.path,
            workspace: Workspace(
                sessionName: name, startDirectory: rootDirectory, windows: windows),
            environment: environment, options: options, globalOptions: globalOptions,
            windowOptions: windowOptions, windowOptionsAfter: windowOptionsAfter,
            beforeScript: beforeScript)
    }

    private static func containsNUL(_ value: Value) -> Bool {
        switch value {
        case let .string(text): return text.contains("\0")
        case let .array(values): return values.contains(where: containsNUL)
        case let .object(values):
            return values.keys.contains { $0.contains("\0") }
                || values.values.contains(where: containsNUL)
        default: return false
        }
    }

    private static func windowIndex(_ value: Value?) throws -> Int? {
        guard let value else { return nil }
        guard case let .integer(index) = value, index >= 0, index <= Int32.max else {
            throw CLIError(
                "invalid_workspace", "window_index must be an integer from 0 through 2147483647.")
        }
        return Int(index)
    }

    private static func scalarMapping(_ value: Value?, at location: String, store: DocumentStore)
        throws -> [String: String]
    {
        guard let value else { return [:] }
        guard let mapping = value.object else {
            throw CLIError("invalid_workspace", "\(location) must be a mapping.")
        }
        guard mapping.keys.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("\0") })
        else {
            throw CLIError("invalid_workspace", "\(location) contains an invalid name.")
        }
        return try mapping.mapValues { value in
            let text: String
            switch value {
            case let .string(value): text = expand(value, environment: store.context.environment)
            case let .integer(value): text = String(value)
            case let .number(value): text = String(value)
            case let .bool(value):
                text =
                    location == "environment" ? (value ? "true" : "false") : (value ? "on" : "off")
            default:
                throw CLIError(
                    "invalid_workspace", "\(location) values must be strings, numbers or booleans.")
            }
            guard !text.contains("\0") else {
                throw CLIError("invalid_workspace", "\(location) values cannot contain NUL.")
            }
            return text
        }
    }

    private static func mapping(_ value: Value, allowed: Set<String>, at location: String) throws
        -> [String: Value]
    {
        guard let object = value.object else {
            throw CLIError("invalid_workspace", "\(location) must be a mapping.")
        }
        // An `x-` key is a caller's own extension, at any level: left alone
        // at load and round-tripped by `convert`, never refused.
        if let unknown = object.keys.sorted().first(where: {
            !$0.hasPrefix("x-") && !allowed.contains($0)
        }) {
            throw CLIError(
                "unsupported_key",
                "\(location).\(unknown) is not implemented; no session was created. Prefix a custom key with 'x-' to have it ignored."
            )
        }
        return object
    }

    private static func entries(_ value: Value?) -> [Value] {
        guard let value, value != .null else { return [] }
        return value.array ?? [value]
    }

    private static func optionalString(_ value: Value?, at key: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value.string else {
            throw CLIError("invalid_workspace", "\(key) must be a string.")
        }
        return string
    }

    private static func optionalDouble(_ value: Value?, at key: String) throws -> Double? {
        guard let value else { return nil }
        switch value {
        case let .integer(number): return Double(number)
        case let .number(number): return number
        default: throw CLIError("invalid_workspace", "\(key) must be a number.")
        }
    }

    /// A boolean field, also accepting `tmuxp freeze`'s quoted
    /// `'true'`/`'false'` strings.
    private static func boolean(_ value: Value?, fallback: Bool, at key: String) throws -> Bool {
        guard let value else { return fallback }
        switch value {
        case let .bool(flag): return flag
        case .string("true"): return true
        case .string("false"): return false
        default: throw CLIError("invalid_workspace", "\(key) must be a boolean.")
        }
    }

    private static func directory(_ value: Value?, parent: URL, store: DocumentStore) throws
        -> String?
    {
        guard let text = try optionalString(value, at: "start_directory") else { return nil }
        return store.path(expand(text, environment: store.context.environment), relativeTo: parent)
            .path
    }

    private static func expand(_ text: String, environment: [String: String]) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .reversed()
        {
            let keyRange = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            guard let key = Range(keyRange, in: text), let full = Range(match.range, in: result),
                let value = environment[String(text[key])]
            else { continue }
            result.replaceSubrange(full, with: value)
        }
        return result
    }
}

/// Carries the specific code for a failure raised inside a callback
/// `WorkspaceBuilder.build` re-throws as a generic `WorkspaceBuilderError`,
/// losing the original `CLIError.code` in the process. Read back in `load`'s
/// catch block instead of trusting the generic mapping there.
private actor FailureCode {
    private(set) var value: String?
    private(set) var session: (id: String, name: String)?
    func set(_ code: String) {
        if value == nil { value = code }
    }
    func record(_ session: Session) {
        if self.session == nil { self.session = (session.id.rawValue, session.name) }
    }
}

private actor AppendState {
    var started = false
    var windows: [String] = []
    func reset() {
        started = false
        windows = []
    }
    func begin() { started = true }
    func append(_ window: String) { windows.append(window) }
}
