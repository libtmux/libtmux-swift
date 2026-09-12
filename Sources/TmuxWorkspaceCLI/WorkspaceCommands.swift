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

    static func load(_ command: Load, context: CLIContext, output: Presenter) async throws {
        guard !command.colors88 else {
            throw CLIError(
                "unsupported_color_mode",
                "tmux 3.2a and newer do not support 88-color mode (-8); use -2 or automatic detection.",
                status: 2)
        }
        guard !command.output.machine || command.detached || command.append else {
            throw CLIError("load_mode", "Machine load requires -d or --append.", status: 2)
        }
        guard command.detached || command.append || (context.terminal && context.inputTTY != nil)
        else {
            throw CLIError(
                "terminal_required",
                "Attached load requires a foreground terminal. Use -d to load detached.",
                status: 2)
        }
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
        let target = try await loadTarget(command, server: server, context: context, output: output)
        let borrowed: Session?
        if case let .append(session) = target { borrowed = session } else { borrowed = nil }
        let retained = AppendState()
        var results: [Value] = []
        var lastSession: Session?
        try await output.event(
            "started", command: "load", data: .object(["inputs": .integer(Int64(plans.count))]))
        do {
            for plan in plans {
                await retained.reset()
                try Task.checkCancellation()
                try await output.event(
                    "workspace-started", command: "load",
                    data: .object([
                        "session_name": .string(borrowed?.name ?? plan.workspace.sessionName),
                        "input": .string(plan.source),
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
                        configureSession: { session in
                            if borrowed != nil { await retained.begin() }
                            if let script = plan.beforeScript {
                                var processContext = context
                                processContext.directory = URL(
                                    fileURLWithPath: plan.workspace.startDirectory!)
                                let result = try await ProcessCommands.run(
                                    script, context: processContext)
                                if !result.output.isEmpty {
                                    try await output.bootstrap(result.output, stream: "stdout")
                                }
                                if !result.error.isEmpty {
                                    try await output.bootstrap(result.error, stream: "stderr")
                                }
                                guard result.code == 0 else {
                                    throw CLIError(
                                        "before_script",
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
                        },
                        configureWindow: { window, index in
                            if borrowed != nil { await retained.append(window.id.rawValue) }
                            for (name, value) in plan.windowOptions[index].sorted(by: {
                                $0.key < $1.key
                            }) {
                                try requireSuccess(
                                    await server.setOption(name, to: value, scope: .window(window)))
                            }
                        }, borrowing: borrowed,
                        onEvent: { event in
                            let name: String
                            var fields: [String: Value] = [:]
                            switch event {
                            case let .windowStarted(index, window):
                                name = "window-created"
                                fields = [
                                    "window_id": .string(window.id.rawValue),
                                    "window_name": .string(window.name),
                                    "window_index": .integer(Int64(index + 1)),
                                    "pane_total": .integer(
                                        Int64(plan.workspace.windows[index].panes.count)),
                                ]
                            case let .windowCompleted(index, window):
                                name = "window-completed"
                                fields = [
                                    "window_id": .string(window.id.rawValue),
                                    "window_index": .integer(Int64(index + 1)),
                                ]
                            case let .paneStarted(windowIndex, index, pane):
                                name = "pane-created"
                                fields = [
                                    "pane_id": .string(pane.id.rawValue),
                                    "window_index": .integer(Int64(windowIndex + 1)),
                                    "pane_index": .integer(Int64(index + 1)),
                                ]
                            case let .paneCompleted(windowIndex, index, pane):
                                name = "pane-completed"
                                fields = [
                                    "pane_id": .string(pane.id.rawValue),
                                    "window_index": .integer(Int64(windowIndex + 1)),
                                    "pane_index": .integer(Int64(index + 1)),
                                ]
                            }
                            try await output.event(name, command: "load", data: .object(fields))
                        })
                }
                let result = Value.object([
                    "session_name": .string(session.name),
                    "session_id": .string(session.id.rawValue), "created": .bool(existing == nil),
                    "action": .string(
                        borrowed != nil ? "appended" : existing == nil ? "created" : "reused"),
                ])
                results.append(result)
                lastSession = session
                try await output.event("workspace-completed", command: "load", data: result)
            }
            let result = Value.object(["status": .string("success"), "workspaces": .array(results)])
            try await output.event("completed", command: "load", data: result)
            if command.output.json && !command.output.ndjson {
                try await output.result(result)
            } else if !command.output.machine {
                for result in results {
                    try await output.row(
                        .object([
                            "name": result["session_name"] ?? .null,
                            "path": result["action"] ?? .null,
                        ]))
                }
            }
        } catch {
            let changed = await retained.started
            var fields: [String: Value] = [
                "status": .string(results.isEmpty && !changed ? "error" : "partial"),
                "workspaces": .array(results),
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
            try? await output.event("failed", command: "load", data: result)
            if command.output.json && !command.output.ndjson {
                try? await output.result(result)
            }
            throw error
        }
        if case let .attached(client) = target, let session = lastSession {
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
    }

    private static func loadTarget(
        _ command: Load, server: Server, context: CLIContext, output: Presenter
    ) async throws -> LoadTarget {
        if command.detached { return .detached }
        if command.append {
            return .append(
                try await currentTarget(server, context: context, verifyTerminal: false).session)
        }
        guard let tmux = context.environment["TMUX"], !tmux.isEmpty else { return .attached(nil) }
        let current = try await currentTarget(server, context: context, verifyTerminal: true)
        if !command.yes {
            while true {
                let answer = try await prompt(
                    "Load: [y] switch, [n] detached, [a] append, [q] cancel (y)",
                    context: context, output: output)
                if ["n", "no", "d", "detached"].contains(answer) { return .detached }
                if ["a", "append"].contains(answer) { return .append(current.session) }
                if ["", "y", "yes", "s", "switch"].contains(answer) { break }
            }
        }
        guard !current.clients.isEmpty else {
            throw CLIError(
                "load_context", "No attached client views the current pane. Use -d or --append.")
        }
        if current.clients.count == 1 { return .attached(current.clients[0]) }
        guard !command.yes else {
            throw CLIError(
                "load_context",
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
                "Choose client (1-\(clients.count), q to cancel):", context: context, output: output
            )
            if let number = Int(answer), clients.indices.contains(number - 1) {
                return .attached(clients[number - 1])
            }
        }
    }

    private static func prompt(_ message: String, context: CLIContext, output: Presenter)
        async throws -> String
    {
        try await output.row(.object(["name": .string(message)]))
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
        _ selected: Server, context: CLIContext, verifyTerminal: Bool
    ) async throws -> (session: Session, clients: [Client]) {
        let code = verifyTerminal ? "load_context" : "append_context"
        guard let inherited = TmuxContext.current(environment: context.environment),
            let rawPane = context.environment["TMUX_PANE"], let paneID = PaneID(rawValue: rawPane)
        else { throw CLIError(code, "This load requires a valid TMUX and TMUX_PANE.") }
        let origin = try await inherited.server(tmuxExecutable: selected.tmuxExecutable)
            .incarnation()
        let snapshot = try await selected.snapshot()
        guard origin.processID == inherited.serverProcessID,
            snapshot.incarnation.processID == origin.processID,
            snapshot.incarnation.startedAt == origin.startedAt,
            snapshot.incarnation.socketPath == origin.socketPath,
            let pane = snapshot.panes.first(where: { $0.id == paneID })
        else {
            throw CLIError(
                code, "Selected endpoint does not identify the current pane's server.")
        }
        let links = snapshot.windowLinks.filter { $0.windowID == pane.windowID }
        let link =
            links.first { $0.sessionID == inherited.sessionID }
            ?? (links.count == 1 ? links.first : nil)
        guard let link, let session = snapshot.sessions.first(where: { $0.id == link.sessionID })
        else {
            throw CLIError(code, "The current pane's session is missing or ambiguous.")
        }
        if verifyTerminal {
            guard let tty = context.inputTTY,
                try await selected.format("#{pane_tty}", for: pane, through: link) == tty
            else { throw CLIError(code, "TMUX_PANE does not identify this terminal.") }
        }
        return (
            session,
            snapshot.clients.filter {
                !$0.isControlMode && $0.sessionID == session.id && $0.activePaneID == pane.id
            }
        )
    }

    static func freeze(_ command: Freeze, context: CLIContext, output: Presenter) async throws {
        guard let name = command.sessionName else {
            throw CLIError("usage", "Provide a session name for capture.", status: 2)
        }
        let server = try server(command.socket, context: context)
        let snapshot = try await server.snapshot()
        guard
            let session = snapshot.sessions.first(where: {
                $0.name == name || $0.id.rawValue == name
            })
        else {
            throw CLIError("session_not_found", "Session not found: \(name)")
        }
        var windows: [Value] = []
        for link in snapshot.windowLinks(of: session).sorted(by: { $0.index < $1.index }) {
            guard let window = snapshot.windows.first(where: { $0.id == link.windowID }) else {
                throw CLIError("stale_session", "A captured window disappeared.")
            }
            let panes = snapshot.panes(of: window).map { pane in
                Value.object([
                    "start_directory": .string(pane.currentPath),
                    "focus": .bool(pane.isActive),
                    "shell_command": .array(
                        pane.currentCommand.isEmpty ? [] : [.string(pane.currentCommand)]),
                ])
            }
            var value: [String: Value] = [
                "window_name": .string(window.name), "panes": .array(panes),
                "window_index": .integer(Int64(link.index)), "focus": .bool(link.isActive),
            ]
            if let layout = try await server.format("#{window_layout}", for: link) {
                value["layout"] = .string(layout)
            }
            windows.append(.object(value))
        }
        let document = Value.object([
            "session_name": .string(session.name), "windows": .array(windows),
        ])
        try await output.warning(
            "Capture preserves current commands, directories, layout, indexes and focus. Original arguments, scripts, environment and options cannot be reconstructed by this build."
        )
        if let destination = command.destination {
            let store = DocumentStore(context: context)
            let file = store.path(destination)
            try store.save(document, to: file, format: command.format, overwrite: command.force)
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
                DocumentStore(context: context).encode(document, format: command.format))
        }
    }

    private struct PlannedWorkspace {
        let source: String
        let workspace: Workspace
        let environment: [String: String]
        let options: [String: String]
        let windowOptions: [[String: String]]
        let beforeScript: [String]?
    }

    private static func requireSuccess(_ reply: TmuxReply) throws {
        guard reply.isSuccess else { throw CLIError("tmux", reply.errorText) }
    }

    private static func normalize(
        _ value: Value, file: URL, override: String?, store: DocumentStore
    ) throws -> PlannedWorkspace {
        guard !containsNUL(value) else {
            throw CLIError("document", "Workspace values and keys cannot contain NUL.")
        }
        let root = try mapping(
            value,
            allowed: [
                "session_name", "start_directory", "windows", "shell_command_before",
                "suppress_history", "environment", "options", "window_options", "before_script",
            ], at: "workspace")
        let expandedName = (override ?? root["session_name"]?.string).map {
            expand($0, environment: store.context.environment)
        }
        guard let name = expandedName, !name.isEmpty,
            !name.contains(":"), !name.contains("."), !name.contains("\n")
        else {
            throw CLIError(
                "document",
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
            throw CLIError("document", "Invalid environment variable name.")
        }
        let options = try scalarMapping(root["options"], at: "options", store: store)
        let inheritedOptions = try scalarMapping(
            root["window_options"], at: "window_options", store: store)
        let beforeScript = try optionalString(root["before_script"], at: "before_script").map {
            try ProcessCommands.splitArguments(expand($0, environment: store.context.environment))
        }
        if let beforeScript,
            beforeScript.isEmpty || beforeScript[0].isEmpty
                || beforeScript.contains(where: { $0.contains("\0") })
        {
            throw CLIError("document", "before_script must name an executable.")
        }
        guard let source = root["windows"]?.array, !source.isEmpty else {
            throw CLIError("document", "windows must be a nonempty list.")
        }
        var windowOptions: [[String: String]] = []
        let windows = try source.enumerated().map { index, item in
            let window = try mapping(
                item,
                allowed: [
                    "window_name", "start_directory", "layout", "panes", "shell_command_before",
                    "suppress_history", "options", "window_index", "focus",
                ], at: "windows[\(index)]")
            windowOptions.append(
                inheritedOptions.merging(
                    try scalarMapping(window["options"], at: "window.options", store: store)
                ) { _, local in local })
            let windowDirectory =
                try directory(
                    window["start_directory"], parent: URL(fileURLWithPath: rootDirectory),
                    store: store) ?? rootDirectory
            let suppress = try boolean(
                window["suppress_history"], fallback: history, at: "suppress_history")
            let before =
                entries(root["shell_command_before"]) + entries(window["shell_command_before"])
            guard let sourcePanes = window["panes"]?.array, !sourcePanes.isEmpty else {
                throw CLIError("document", "panes must be a nonempty list.")
            }
            let panes = try sourcePanes.map { item in
                let pane: [String: Value]
                switch item {
                case .object:
                    pane = try mapping(
                        item,
                        allowed: [
                            "start_directory", "shell_command", "shell_command_before",
                            "suppress_history", "enter", "focus",
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
                                throw CLIError("document", "cmd must be a string.")
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
                    focus: try boolean(pane["focus"], fallback: false, at: "pane.focus"))
            }
            return WindowPlan(
                windowName: try optionalString(window["window_name"], at: "window_name"),
                startDirectory: windowDirectory,
                layout: try optionalString(window["layout"], at: "layout"), panes: panes,
                windowIndex: try windowIndex(window["window_index"]),
                focus: try boolean(window["focus"], fallback: false, at: "window.focus"))
        }
        let indexes = windows.compactMap(\.windowIndex)
        guard Set(indexes).count == indexes.count else {
            throw CLIError("document", "Each explicit window_index must be unique.")
        }
        guard windows.filter({ $0.focus == true }).count <= 1,
            windows.allSatisfy({ $0.panes.filter { $0.focus == true }.count <= 1 })
        else {
            throw CLIError("document", "Choose one focused window and one focused pane per window.")
        }
        return PlannedWorkspace(
            source: file.path,
            workspace: Workspace(
                sessionName: name, startDirectory: rootDirectory, windows: windows),
            environment: environment, options: options, windowOptions: windowOptions,
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
            throw CLIError("document", "window_index must be an integer from 0 through 2147483647.")
        }
        return Int(index)
    }

    private static func scalarMapping(_ value: Value?, at location: String, store: DocumentStore)
        throws -> [String: String]
    {
        guard let value else { return [:] }
        guard let mapping = value.object else {
            throw CLIError("document", "\(location) must be a mapping.")
        }
        guard mapping.keys.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("\0") })
        else {
            throw CLIError("document", "\(location) contains an invalid name.")
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
                    "document", "\(location) values must be strings, numbers or booleans.")
            }
            guard !text.contains("\0") else {
                throw CLIError("document", "\(location) values cannot contain NUL.")
            }
            return text
        }
    }

    private static func mapping(_ value: Value, allowed: Set<String>, at location: String) throws
        -> [String: Value]
    {
        guard let object = value.object else {
            throw CLIError("document", "\(location) must be a mapping.")
        }
        if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw CLIError(
                "unsupported_config",
                "\(location).\(unknown) is not implemented; no session was created.")
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
            throw CLIError("document", "\(key) must be a string.")
        }
        return string
    }

    private static func boolean(_ value: Value?, fallback: Bool, at key: String) throws -> Bool {
        guard let value else { return fallback }
        guard case let .bool(flag) = value else {
            throw CLIError("document", "\(key) must be a boolean.")
        }
        return flag
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
