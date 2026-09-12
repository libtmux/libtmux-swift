import Foundation

enum ReadCommands {
    static func list(_ command: ListWorkspaces, context: CLIContext, output: Presenter) async throws
    {
        let store = DocumentStore(context: context)
        let rows = store.discover(full: command.full)
        if command.output.json && !command.output.ndjson {
            try await output.result(
                .object([
                    "workspaces": .array(Array(rows)),
                    "global_workspace_dirs": .array(
                        store.globalDirectories.map { .string($0.path) }),
                ]))
        } else {
            var previous: String?
            for row in rows {
                if command.tree && !command.output.machine,
                    let directory = row["directory"]?.string, previous != directory
                {
                    try await context.output(Presenter.sanitize(directory))
                    previous = directory
                }
                try await output.row(row, tree: command.tree)
            }
        }
    }

    static func convert(_ command: Convert, context: CLIContext, output: Presenter) async throws {
        let store = DocumentStore(context: context)
        let file = try store.resolve(command.file)
        let value = try store.read(file)
        if command.output.machine {
            try await output.document(value, command: "convert")
            return
        }
        let format: WorkspaceFormat = file.pathExtension == "json" ? .yaml : .json
        let destination = file.deletingPathExtension().appendingPathExtension(format.rawValue)
        if command.yes {
            try store.save(value, to: destination, format: format, overwrite: false)
            try await context.output("Saved \(Presenter.sanitize(destination.path))")
        } else {
            try await context.output(store.encode(value, format: format))
        }
    }

    static func search(_ command: Search, context: CLIContext, output: Presenter) async throws {
        let aliases = [
            "name": "name", "session": "session", "s": "session", "path": "path", "p": "path",
            "window": "window", "w": "window", "pane": "pane",
        ]
        let selected = try command.field.flatMap { value in
            try value.split(separator: ",").map { name in
                guard let canonical = aliases[String(name)] else {
                    throw CLIError("usage", "Unknown search field: \(name)", status: 2)
                }
                return canonical
            }
        }
        let patterns = try command.terms.map { term -> (String?, NSRegularExpression) in
            let parts = term.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = parts.count == 2 ? aliases[String(parts[0])] : nil
            let text = field == nil ? term : String(parts[1])
            var pattern =
                command.fixedStrings ? NSRegularExpression.escapedPattern(for: text) : text
            if command.wordRegexp { pattern = "(?<!\\w)(?:" + pattern + ")(?!\\w)" }
            let insensitive = command.ignoreCase || (command.smartCase && text == text.lowercased())
            do {
                return (
                    field,
                    try NSRegularExpression(
                        pattern: pattern, options: insensitive ? .caseInsensitive : [])
                )
            } catch { throw CLIError("usage", "Invalid search expression: \(text)", status: 2) }
        }
        var found: [Value] = []
        for row in DocumentStore(context: context).discover(full: true) {
            let config = row["config"] ?? .object([:])
            let windows = config["windows"]?.array ?? []
            let fields: [String: [String]] = [
                "name": [row["name"]?.string ?? ""], "path": [row["path"]?.string ?? ""],
                "session": [config["session_name"]?.string ?? ""],
                "window": windows.compactMap { $0["window_name"]?.string },
                "pane": windows.flatMap { $0["panes"]?.array ?? [] }.map {
                    $0.string ?? (try? $0.encoded()) ?? ""
                },
            ]
            let matches = patterns.map { field, regex in
                let keys = field.map { [$0] } ?? (selected.isEmpty ? Array(fields.keys) : selected)
                return keys.flatMap { fields[$0] ?? [] }.contains { text in
                    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                }
            }
            let matched = command.any ? matches.contains(true) : matches.allSatisfy { $0 }
            if matched != command.invertMatch {
                var record = row.object ?? [:]
                record.removeValue(forKey: "config")
                let value = Value.object(record)
                if command.output.ndjson || !command.output.json {
                    try await output.row(value)
                } else {
                    found.append(value)
                }
            }
        }
        if command.output.json && !command.output.ndjson { try await output.result(.array(found)) }
    }
}
