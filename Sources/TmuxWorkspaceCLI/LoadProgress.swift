import Foundation

struct LoadProgress {
    private static let presets = [
        "default": "Loading workspace: {session} {bar} {progress} {window}",
        "minimal": "Loading workspace: {session} [{window_progress}]",
        "window": "Loading workspace: {session} {window_bar} {window_progress_rel}",
        "pane": "Loading workspace: {session} {pane_bar} {session_pane_progress}",
        "verbose":
            "Loading workspace: {session} [window {window_index} of {window_total}, pane {pane_index} of {pane_total}] {window}",
    ]

    private let format: String
    private let columns: Int
    private let panelRows: Int
    private let color: Bool
    private var panel: [String] = []
    private var values: [String: String] = [:]
    private var windows = 0
    private var windowIndex = 0
    private var windowsDone = 0
    private var panes = 0
    private var paneIndex = 0
    private var panesDone = 0
    private var sessionPanes = 0
    private var sessionPanesDone = 0
    private var painted = 0
    private(set) var active = false

    static func create(_ command: Load, context: CLIContext) throws -> LoadProgress? {
        let raw =
            command.progressLines.map(String.init)
            ?? context.environment["TMUXP_PROGRESS_LINES"] ?? "3"
        guard let lines = Int(raw), lines >= -1 else {
            throw CLIError("usage", "Progress lines must be an integer at least -1.", status: 2)
        }
        guard !command.output.machine, !command.noProgress, context.errorTerminal,
            context.environment["TMUXP_PROGRESS"] != "0", context.environment["TERM"] != "dumb"
        else { return nil }
        let format =
            command.progressFormat ?? context.environment["TMUXP_PROGRESS_FORMAT"] ?? "default"
        let rows = max(0, context.terminalSize.rows - 2)
        let color =
            (context.environment["NO_COLOR"] ?? "").isEmpty
            && command.output.color != .never
        return LoadProgress(
            format: presets[format] ?? format,
            columns: max(1, context.terminalSize.columns - 1),
            panelRows: min(lines == -1 ? rows : lines, rows), color: color)
    }

    mutating func update(_ event: String, data: Value) {
        func count(_ name: String) -> Int {
            if case let .integer(value) = data[name] { return Int(exactly: value) ?? 0 }
            return 0
        }
        switch event {
        case "workspace-started":
            active = true
            values = [
                "session": data["session_name"]?.string ?? "",
                "workspace_path": data["input"]?.string ?? "",
                "window": "",
            ]
            windows = count("window_total")
            sessionPanes = count("session_pane_total")
            windowIndex = 0
            windowsDone = 0
            panes = 0
            paneIndex = 0
            panesDone = 0
            sessionPanesDone = 0
            panel.removeAll(keepingCapacity: true)
        case "window-created":
            values["window"] = data["window_name"]?.string ?? ""
            windowIndex = count("window_index")
            panes = count("pane_total")
            paneIndex = 0
            panesDone = 0
        case "pane-created": paneIndex = count("pane_index")
        case "pane-completed":
            panesDone += 1
            sessionPanesDone += 1
        case "window-completed": windowsDone += 1
        case "workspace-completed", "completed", "failed": active = false
        default: break
        }
    }

    mutating func appendCapturedOutput(_ text: String) {
        guard panelRows > 0 else { return }
        let bytes = text.utf8.suffix(65_536).drop(while: { $0 & 0xC0 == 0x80 })
        let retained = String(decoding: bytes, as: UTF8.self)
        var lines = retained.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        let candidates = panel + lines.map(String.init)
        panel.removeAll(keepingCapacity: true)
        var remaining = 65_536
        for line in candidates.suffix(panelRows).reversed() {
            guard line.utf8.count <= remaining else { break }
            panel.append(line)
            remaining -= line.utf8.count
        }
        panel.reverse()
    }

    mutating func frame() -> String? {
        guard active else { return nil }
        let fields = fields()
        var text = ""
        var at = format.startIndex
        while at < format.endIndex {
            let rest = format[at...]
            if rest.hasPrefix("{{") || rest.hasPrefix("}}") {
                text.append(format[at])
                at = format.index(at, offsetBy: 2)
            } else if format[at] == "{", let end = rest.firstIndex(of: "}") {
                let name = String(format[format.index(after: at)..<end])
                text += fields[name] ?? String(format[at...end])
                at = format.index(after: end)
            } else {
                text.append(format[at])
                at = format.index(after: at)
            }
        }
        let lines =
            [style(clip(text), code: "1;36")]
            + panel.map { style(clip($0), code: "2") }
        let erase = clear()
        painted = lines.count
        return erase + lines.joined(separator: "\n") + "\n"
    }

    mutating func clear() -> String {
        guard painted > 0 else { return "" }
        defer { painted = 0 }
        return "\u{1b}[\(painted)A\r\u{1b}[0J"
    }

    private func fields() -> [String: String] {
        func ratio(_ done: Int, _ total: Int) -> String { total == 0 ? "" : "\(done)/\(total)" }
        func bar(_ done: Int, _ total: Int) -> String {
            let filled = total == 0 ? 0 : min(10, 10 * done / total)
            return "[" + String(repeating: "#", count: filled)
                + String(repeating: "-", count: 10 - filled) + "]"
        }
        return values.merging([
            "window_index": String(windowIndex), "window_total": String(windows),
            "window_progress": ratio(windowIndex, windows), "windows_done": String(windowsDone),
            "windows_remaining": String(max(0, windows - windowsDone)),
            "window_progress_rel": ratio(windowsDone, windows),
            "pane_index": String(paneIndex), "pane_total": String(panes),
            "pane_progress": ratio(paneIndex, panes), "pane_done": String(panesDone),
            "pane_remaining": String(max(0, panes - panesDone)),
            "pane_progress_rel": ratio(panesDone, panes),
            "session_pane_total": String(sessionPanes),
            "session_panes_done": String(sessionPanesDone),
            "session_panes_remaining": String(max(0, sessionPanes - sessionPanesDone)),
            "session_pane_progress": ratio(sessionPanesDone, sessionPanes),
            "overall_percent": String(
                sessionPanes == 0 ? 0 : 100 * sessionPanesDone / sessionPanes),
            "progress": "\(ratio(windowIndex, windows)) win, \(ratio(paneIndex, panes)) pane",
            "summary": "[\(windowsDone) win, \(sessionPanesDone) panes]",
            "bar": bar(sessionPanesDone, sessionPanes),
            "pane_bar": bar(sessionPanesDone, sessionPanes),
            "window_bar": bar(windowsDone, windows), "status_icon": "",
        ]) { _, new in new }
    }

    private func clip(_ text: String) -> String {
        var result = ""
        var cells = 0
        for character in Presenter.sanitize(text) {
            let width = character.unicodeScalars.contains { $0.value > 127 } ? 2 : 1
            guard cells + width <= columns else { break }
            result.append(character)
            cells += width
        }
        return result
    }

    private func style(_ text: String, code: String) -> String {
        color ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
    }
}
