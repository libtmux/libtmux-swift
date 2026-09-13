import Foundation

enum ImportCommands {
    static func run(_ command: any ImportAction, context: CLIContext, output: Presenter)
        async throws
    {
        let kind = type(of: command).importer
        let format = command.save.format ?? .yaml
        let sourceDirectory =
            kind == "tmuxinator"
            ? context.environment["TMUXINATOR_CONFIG"] ?? "~/.tmuxinator"
            : "~/.teamocil"
        let store = DocumentStore(context: context)
        let file = try store.resolve(command.file, in: [store.path(sourceDirectory)])
        let source = try store.read(file)
        if try source.encoded().contains("<%") {
            throw CLIError(
                "unsupported_template",
                "ERB templates require tmuxinator; provide expanded YAML or JSON.")
        }
        var document =
            try kind == "teamocil"
            ? teamocil(source, file: file, store: store)
            : tmuxinator(source, file: file, store: store)
        if var mapping = document.object, let windows = mapping["windows"]?.array {
            mapping["windows"] = .array(
                try defaultFocus(windows).map { window in
                    guard var value = window.object, let panes = value["panes"]?.array else {
                        return window
                    }
                    value["panes"] = .array(try defaultFocus(panes))
                    return .object(value)
                })
            document = .object(mapping)
        }
        try WorkspaceCommands.validateImport(document, file: file, store: store)
        var result: [String: Value] = [
            "schema_version": .integer(1), "command": .string("import \(kind)"),
            "status": .string("success"),
        ]
        if let destination = command.save.destination {
            let file = store.path(destination)
            try store.save(
                document, to: file, format: format, overwrite: command.save.force)
            result["destination"] = .string(file.path)
            result["format"] = .string(format.rawValue)
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
            try await context.output(store.encode(document, format: format))
        }
    }

    private static func tmuxinator(_ document: Value, file: URL, store: DocumentStore) throws
        -> Value
    {
        let source = try object(document, at: "tmuxinator")
        try requireKeys(
            source,
            known: [
                "project_name", "name", "project_root", "root", "windows", "tabs", "pre_window",
            ], at: "workspace")
        let root = try directory(
            alias(source, "project_root", "root"), parent: store.context.directory, store: store)
        var result: [String: Value] = [
            "session_name": try alias(source, "project_name", "name")
                ?? .string(file.deletingPathExtension().lastPathComponent),
            "start_directory": .string(root.path),
        ]
        result["shell_command_before"] = try group(source["pre_window"], separator: "; ")
        guard let windows = try alias(source, "tabs", "windows")?.array else {
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
                    try requireKeys(
                        details, known: ["panes", "pre", "root", "layout"], at: name,
                    )
                    guard
                        details["panes"] == nil || details["panes"] == .null
                            || details["panes"]?.array != nil
                    else {
                        throw CLIError("import_document", "\(name).panes must be a list.")
                    }
                    let panes = details["panes"]?.array ?? [.null]
                    let before = try group(details["pre"], separator: " && ")
                    if before != nil && details["panes"]?.array?.isEmpty != false {
                        throw CLIError("import_unsupported", "\(name).pre requires explicit panes.")
                    }
                    window["panes"] = .array(
                        try panes.map { pane in
                            .object(["shell_command": .array(try commands(pane))])
                        })
                    window["shell_command_before"] = before
                    window["start_directory"] = .string(
                        try directory(details["root"], parent: root, store: store).path)
                    window["layout"] = details["layout"]
                } else {
                    window["panes"] = .array([
                        .object(["shell_command": .array(try commands(value))])
                    ])
                }
                return .object(window)
            })
        return .object(result)
    }

    private static func teamocil(_ document: Value, file: URL, store: DocumentStore) throws -> Value
    {
        if document["session"] != nil {
            try requireKeys(
                try object(document, at: "teamocil"), known: ["session"], at: "teamocil")
        }
        let source = try object(document["session"] ?? document, at: "teamocil")
        try requireKeys(source, known: ["name", "root", "windows"], at: "workspace")
        let root = try directory(source["root"], parent: store.context.directory, store: store)
        var result: [String: Value] = [
            "session_name": source["name"]
                ?? .string(file.deletingPathExtension().lastPathComponent),
            "start_directory": .string(root.path),
        ]
        guard let windows = source["windows"]?.array else {
            throw CLIError("import_document", "teamocil windows must be a list.")
        }
        result["windows"] = .array(
            try windows.map { value in
                let sourceWindow = try object(value, at: "window")
                try requireKeys(
                    sourceWindow,
                    known: ["name", "root", "splits", "panes", "layout", "focus"],
                    at: "window")
                var window: [String: Value] = ["window_name": sourceWindow["name"] ?? .null]
                let windowRoot = try directory(
                    sourceWindow["root"], parent: store.context.directory, store: store,
                    fallback: root)
                window["start_directory"] = .string(windowRoot.path)
                window["layout"] = sourceWindow["layout"]
                window["focus"] = sourceWindow["focus"]
                guard let panes = try alias(sourceWindow, "splits", "panes")?.array else {
                    throw CLIError("import_document", "teamocil panes must be a list.")
                }
                window["panes"] = .array(
                    try panes.map { pane in
                        guard let mapping = pane.object else {
                            return .object([
                                "shell_command": try group(pane, separator: "; ") ?? .null
                            ])
                        }
                        try requireKeys(
                            mapping, known: ["cmd", "commands", "root", "focus"], at: "pane")
                        return .object([
                            "shell_command": try group(
                                alias(mapping, "commands", "cmd"), separator: "; ") ?? .null,
                            "start_directory": .string(
                                try directory(mapping["root"], parent: windowRoot, store: store)
                                    .path),
                            "focus": mapping["focus"] ?? .bool(false),
                        ])
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

    private static func defaultFocus(_ values: [Value]) throws -> [Value] {
        let selected = values.firstIndex { $0["focus"] == .bool(true) } ?? 0
        return try values.enumerated().map { index, value in
            var mapping = try object(value, at: "focus")
            if let focus = mapping["focus"] {
                guard case .bool = focus else {
                    throw CLIError("import_document", "focus must be a boolean.")
                }
            }
            mapping["focus"] = .bool(index == selected)
            return .object(mapping)
        }
    }

    private static func commands(_ value: Value?) throws -> [Value] {
        guard let value, value != .null else { return [] }
        return try (value.array ?? [value]).compactMap { entry in
            if entry == .null { return nil }
            guard entry.string != nil else {
                throw CLIError(
                    "import_document",
                    "Commands must be strings or lists of strings; named panes are unsupported.")
            }
            return .object(["cmd": entry])
        }
    }

    private static func group(_ value: Value?, separator: String) throws -> Value? {
        let values = try commands(value)
        guard !values.isEmpty else { return nil }
        return .object([
            "cmd": .string(values.compactMap { $0["cmd"]?.string }.joined(separator: separator))
        ])
    }

    private static func alias(_ mapping: [String: Value], _ first: String, _ second: String) throws
        -> Value?
    {
        let left = mapping[first].flatMap { $0 == .null ? nil : $0 }
        let right = mapping[second].flatMap { $0 == .null ? nil : $0 }
        if let left, let right, left != right {
            throw CLIError("import_document", "Conflicting \(first) and \(second) values.")
        }
        return left ?? right
    }

    private static func directory(
        _ value: Value?, parent: URL, store: DocumentStore, fallback: URL? = nil
    ) throws -> URL {
        guard let value, value != .null else { return fallback ?? parent }
        guard let text = value.string else {
            throw CLIError("import_document", "Imported directories must be strings.")
        }
        guard !text.contains("$"), !text.hasPrefix("~") || text == "~" || text.hasPrefix("~/")
        else {
            throw CLIError(
                "import_unsupported",
                "Imported directories do not support dollar expansion or named-user homes.")
        }
        return store.path(text, relativeTo: parent).standardizedFileURL
    }

    private static func requireKeys(
        _ mapping: [String: Value], known: Set<String>, at location: String
    ) throws {
        if let key = mapping.keys.sorted().first(where: { !known.contains($0) }) {
            throw CLIError(
                "import_unsupported", "\(location).\(key) is not translated; no output was saved.")
        }
    }
}
