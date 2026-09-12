import Foundation

enum ImportCommands {
    static func run(_ command: any ImportAction, context: CLIContext, output: Presenter)
        async throws
    {
        let kind = type(of: command).importer
        var sourceContext = context
        sourceContext.environment["TMUXP_CONFIGDIR"] =
            kind == "tmuxinator"
            ? context.environment["TMUXINATOR_CONFIG"] ?? "~/.tmuxinator"
            : "~/.teamocil"
        let store = DocumentStore(context: sourceContext)
        let source = try store.read(store.resolve(command.file))
        if try source.encoded().contains("<%") {
            throw CLIError(
                "unsupported_template",
                "ERB templates require tmuxinator; provide expanded YAML or JSON.")
        }
        var warnings: [String] = []
        let document =
            try kind == "teamocil"
            ? teamocil(source, warnings: &warnings) : tmuxinator(source, warnings: &warnings)
        for warning in warnings { try await output.warning(warning, code: "import_unsupported") }
        var result: [String: Value] = [
            "schema_version": .integer(1), "command": .string("import \(kind)"),
            "status": .string("success"),
        ]
        if let destination = command.save.destination {
            let file = store.path(destination)
            try store.save(
                document, to: file, format: command.save.format, overwrite: command.save.force)
            result["destination"] = .string(file.path)
            result["format"] = .string(command.save.format.rawValue)
            if command.output.machine {
                try await output.result(.object(result))
            } else {
                try await context.output("Saved \(Presenter.sanitize(file.path))")
            }
        } else if command.output.ndjson {
            result["workspace"] = document
            try await output.result(.object(result))
        } else if command.output.json {
            try await output.result(document)
        } else {
            try await context.output(store.encode(document, format: command.save.format))
        }
    }

    private static func tmuxinator(_ document: Value, warnings: inout [String]) throws -> Value {
        let source = try object(document, at: "tmuxinator")
        warnUnknown(
            source,
            known: [
                "project_name", "name", "project_root", "root", "cli_args", "tmux_options",
                "socket_name", "windows", "tabs", "pre", "pre_window", "rbenv",
            ], at: "workspace", warnings: &warnings)
        var result: [String: Value] = [
            "session_name": source["project_name"] ?? source["name"] ?? .null
        ]
        result["start_directory"] = source["project_root"] ?? source["root"]
        result["socket_name"] = source["socket_name"]
        if let configuration = (source["cli_args"] ?? source["tmux_options"])?.string {
            let value = configuration.trimmingCharacters(in: .whitespaces)
            result["config"] = .string(
                value.hasPrefix("-f ")
                    ? String(value.dropFirst(3)).trimmingCharacters(in: .whitespaces) : value)
        }
        var before = list(source["pre"])
        before += list(source["pre_window"])
        if let version = source["rbenv"]?.string {
            before.append(.string("rbenv shell " + version))
        }
        if !before.isEmpty { result["shell_command_before"] = .array(before) }
        guard let windows = (source["tabs"] ?? source["windows"])?.array else {
            throw CLIError("import_document", "tmuxinator windows must be a list.")
        }
        result["windows"] = .array(
            try windows.map { item in
                let mapping = try object(item, at: "window")
                guard mapping.count == 1, let (name, value) = mapping.first else {
                    throw CLIError(
                        "import_document", "Each tmuxinator window must contain one named entry.")
                }
                var window: [String: Value] = ["window_name": .string(name)]
                if let details = value.object {
                    warnUnknown(
                        details, known: ["panes", "pre", "root", "layout"], at: name,
                        warnings: &warnings)
                    window["panes"] = details["panes"] ?? .array([.null])
                    window["shell_command_before"] = details["pre"]
                    window["start_directory"] = details["root"]
                    window["layout"] = details["layout"]
                } else {
                    window["panes"] = value.array == nil ? .array([value]) : value
                }
                return .object(window)
            })
        return .object(result)
    }

    private static func teamocil(_ document: Value, warnings: inout [String]) throws -> Value {
        let source = try object(document["session"] ?? document, at: "teamocil")
        warnUnknown(
            source, known: ["name", "root", "windows"], at: "workspace", warnings: &warnings)
        var result: [String: Value] = ["session_name": source["name"] ?? .null]
        result["start_directory"] = source["root"]
        guard let windows = source["windows"]?.array else {
            throw CLIError("import_document", "teamocil windows must be a list.")
        }
        result["windows"] = .array(
            try windows.map { value in
                let sourceWindow = try object(value, at: "window")
                warnUnknown(
                    sourceWindow,
                    known: ["name", "clear", "filters", "root", "splits", "panes", "layout"],
                    at: "window", warnings: &warnings)
                var window: [String: Value] = ["window_name": sourceWindow["name"] ?? .null]
                window["start_directory"] = sourceWindow["root"]
                window["layout"] = sourceWindow["layout"]
                window["clear"] = sourceWindow["clear"]
                window["shell_command_before"] = sourceWindow["filters"]?["before"]
                window["shell_command_after"] = sourceWindow["filters"]?["after"]
                guard let panes = (sourceWindow["splits"] ?? sourceWindow["panes"])?.array else {
                    throw CLIError("import_document", "teamocil panes must be a list.")
                }
                window["panes"] = .array(
                    panes.map { pane in
                        guard var mapping = pane.object else { return pane }
                        if let command = mapping.removeValue(forKey: "cmd") {
                            mapping["shell_command"] = command
                        }
                        if mapping.removeValue(forKey: "width") != nil {
                            warnings.append("Pane width is not translated; choose a tmux layout.")
                        }
                        if let root = mapping.removeValue(forKey: "root") {
                            mapping["start_directory"] = root
                        }
                        return .object(mapping)
                    })
                return .object(window)
            })
        return .object(result)
    }

    private static func object(_ value: Value, at location: String) throws -> [String: Value] {
        guard let object = value.object else {
            throw CLIError("import_document", "\(location) must be a mapping.")
        }
        return object
    }

    private static func list(_ value: Value?) -> [Value] {
        guard let value, value != .null else { return [] }
        return value.array ?? [value]
    }

    private static func warnUnknown(
        _ mapping: [String: Value], known: Set<String>, at location: String,
        warnings: inout [String]
    ) {
        for key in mapping.keys.sorted() where !known.contains(key) {
            warnings.append("\(location).\(key) is not translated.")
        }
    }
}
