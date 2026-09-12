import Foundation
import LibTmux
import TmuxWorkspace

enum WorkspaceCommands {
    static func server(_ socket: SocketOptions, configuration: String? = nil, context: CLIContext)
        throws -> Server
    {
        let executable = context.environment["LIBTMUX_TMUX_BIN"] ?? "tmux"
        if let path = socket.path {
            return try Server(
                socketPath: DocumentStore(context: context).path(path).path,
                tmuxExecutable: executable, configurationFile: configuration)
        }
        if let name = socket.name {
            return try Server(
                socketName: name, tmuxExecutable: executable, configurationFile: configuration)
        }
        if let inherited = context.environment["TMUX"] {
            let fields = inherited.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count >= 3, let pid = Int(fields[fields.count - 2]), pid > 0,
                let index = Int(fields.last ?? ""), index >= 0
            {
                let path = fields.dropLast(2).joined(separator: ",")
                return try Server(
                    socketPath: path, tmuxExecutable: executable, configurationFile: configuration)
            }
            throw CLIError(
                "usage", "TMUX does not contain a valid socket, PID and session index.", status: 2)
        }
        throw CLIError("usage", "Select a tmux endpoint with -S or -L outside tmux.", status: 2)
    }

    static func load(_ command: Load, context: CLIContext, output: Presenter) async throws {
        let store = DocumentStore(context: context)
        let plans = try command.files.enumerated().map { index, input in
            let file = try store.resolve(input)
            return try normalize(
                store.read(file), file: file,
                override: index == command.files.count - 1 ? command.sessionName : nil, store: store
            )
        }
        let server = try server(
            command.socket, configuration: command.configurationFile, context: context)
        var results: [Value] = []
        try await output.event(
            "started", command: "load", data: .object(["inputs": .integer(Int64(plans.count))]))
        do {
            for plan in plans {
                try Task.checkCancellation()
                let existing: Session?
                if try await server.isRunning() {
                    existing = try await server.sessions().first { $0.name == plan.sessionName }
                } else {
                    existing = nil
                }
                let session: Session
                if let existing {
                    session = existing
                } else {
                    session = try await WorkspaceBuilder.build(plan, on: server)
                }
                let result = Value.object([
                    "session_name": .string(session.name),
                    "session_id": .string(session.id.rawValue), "created": .bool(existing == nil),
                ])
                results.append(result)
                try await output.event("workspace-completed", command: "load", data: result)
            }
            let result = Value.object(["status": .string("success"), "workspaces": .array(results)])
            if command.output.ndjson {
                try await output.event("completed", command: "load", data: result)
            } else {
                try await output.result(result)
            }
        } catch {
            let result = Value.object([
                "status": .string(results.isEmpty ? "error" : "partial"),
                "workspaces": .array(results),
            ])
            if command.output.ndjson {
                try? await output.event("completed", command: "load", data: result)
            } else if command.output.json {
                try? await output.result(result)
            }
            throw error
        }
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
                    "shell_command": .array(
                        pane.currentCommand.isEmpty ? [] : [.string(pane.currentCommand)]),
                ])
            }
            var value: [String: Value] = [
                "window_name": .string(window.name), "panes": .array(panes),
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
            "Capture preserves current commands, directories and layout. Original arguments, scripts, environment, options, focus and explicit indexes cannot be reconstructed by this build."
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
            try await output.result(document)
        } else {
            try await context.output(
                DocumentStore(context: context).encode(document, format: command.format))
        }
    }

    private static func normalize(
        _ value: Value, file: URL, override: String?, store: DocumentStore
    ) throws -> Workspace {
        let root = try mapping(
            value,
            allowed: [
                "session_name", "start_directory", "windows", "shell_command_before",
                "suppress_history",
            ], at: "workspace")
        guard let name = override ?? root["session_name"]?.string, !name.isEmpty,
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
        guard let source = root["windows"]?.array, !source.isEmpty else {
            throw CLIError("document", "windows must be a nonempty list.")
        }
        let windows = try source.enumerated().map { index, item in
            let window = try mapping(
                item,
                allowed: [
                    "window_name", "start_directory", "layout", "panes", "shell_command_before",
                    "suppress_history",
                ], at: "windows[\(index)]")
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
                            "suppress_history", "enter",
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
                        store: store) ?? windowDirectory)
            }
            return WindowPlan(
                windowName: try optionalString(window["window_name"], at: "window_name"),
                startDirectory: windowDirectory,
                layout: try optionalString(window["layout"], at: "layout"), panes: panes)
        }
        return Workspace(
            sessionName: expand(name, environment: store.context.environment),
            startDirectory: rootDirectory, windows: windows)
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
