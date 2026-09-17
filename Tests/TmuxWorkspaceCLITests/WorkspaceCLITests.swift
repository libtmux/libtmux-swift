import Foundation
import LibTmux
import Testing
import TmuxFixture
import TmuxWorkspace

@testable import TmuxWorkspaceCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("workspace CLI", .serialized, .timeLimit(.minutes(1)))
struct WorkspaceCLITests {
    @Test("imports refuse untranslated semantics before preview or destination replacement")
    func importRefusalBeforePublication() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("source.json")
            let destination = root.appendingPathComponent("destination.json")
            let original = Data("preserve destination".utf8)
            for (kind, source) in [
                (
                    "teamocil",
                    #"{"name":"test","windows":[{"name":"work","clear":true,"panes":[null]}]}"#
                ),
                (
                    "teamocil",
                    #"{"name":"test","windows":[{"name":"work","filters":{"after":"echo lost"},"panes":[null]}]}"#
                ),
                (
                    "teamocil",
                    #"{"name":"test","windows":[{"name":"work","panes":[{"cmd":":","width":50}]}]}"#
                ),
                (
                    "tmuxinator",
                    #"{"name":"test","socket_name":"foreign","windows":[{"work":":"}]}"#
                ),
                (
                    "tmuxinator",
                    #"{"name":"test","tmux_options":"-f foreign.conf","windows":[{"work":":"}]}"#
                ),
                (
                    "tmuxinator",
                    #"{"name":"test","windows":[{"work":{"panes":[{"title":":"}]}}]}"#
                ),
                (
                    "tmuxinator",
                    #"{"name":"test","windows":[{"work":{"synchronize":"before","panes":[":"]}}]}"#
                ),
                (
                    "teamocil",
                    #"{"name":"test","windows":[{"name":"work","panes":[{"cmd":":","focus":1}]}]}"#
                ),
                ("tmuxinator", #"{"name":"test","pre":"echo lifecycle","windows":[{"work":":"}]}"#),
                ("tmuxinator", #"{"name":"test","rbenv":2.7,"windows":[{"work":":"}]}"#),
                (
                    "teamocil",
                    #"{"name":"test","windows":[{"name":"work","panes":[{"commands":[42]}]}]}"#
                ),
                ("tmuxinator", #"{"name":"test","windows":[]}"#),
                // tmuxinator expands ERB through Ruby before parsing; a
                // native reader cannot, so markup in a value, a command, or
                // a mapping key must all be refused before conversion.
                (
                    "tmuxinator",
                    #"{"name":"test","root":"<%= dynamic_root %>","windows":[{"work":":"}]}"#
                ),
                (
                    "tmuxinator",
                    #"{"name":"test","windows":[{"work":"echo <%= dynamic_command %>"}]}"#
                ),
                (
                    "tmuxinator",
                    #"{"name":"test","windows":[{"<%= dynamic_window %>":":"}]}"#
                ),
            ] {
                try Data(source.utf8).write(to: file)
                for save in [false, true] {
                    try original.write(to: destination)
                    let arguments =
                        ["import", kind, file.path, "--json"]
                        + (save ? ["--save-to", destination.path, "--force"] : [])
                    let result = await invoke(arguments, in: root)
                    #expect(result.code == 1, "\(kind): \(source): \(result.output)")
                    #expect(result.output.isEmpty)
                    #expect(try Data(contentsOf: destination) == original)
                    if source.contains("<%") {
                        #expect(
                            result.error.joined().contains("ERB"),
                            "\(kind): \(source): \(result.error)")
                    }
                }
            }
        }
    }

    @Test("imported focus and before-command groups survive loading")
    func importedFocusAndBeforeCommands() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            for kind in ["teamocil", "tmuxinator"] {
                let source = root.appendingPathComponent("\(kind).json")
                let destination = root.appendingPathComponent("\(kind)-imported.yaml")
                let text =
                    kind == "teamocil"
                    ? #"{"name":"teamocil","windows":[{"name":"one","panes":[null,null]},{"name":"two","focus":true,"panes":[null,{"commands":["false","printf done > marker"],"focus":true},{"focus":true}]},{"name":"three","focus":true,"panes":[null]}]}"#
                    : #"{"name":"tmuxinator","pre_window":["false","touch continued-project"],"windows":[{"one":{"pre":["false","touch skipped-window"],"panes":["printf done > marker",null]}},{"two":null}]}"#
                try Data(text.utf8).write(to: source)
                let imported = await invoke(
                    ["import", kind, source.path, "--save-to", destination.path, "--json"],
                    in: root)
                #expect(imported.code == 0, "\(imported.error)")
                let preview = await invoke(["convert", destination.path, "--json"], in: root)
                let document = try preview.json()
                let importedWindows = try #require(document["windows"] as? [[String: Any]])
                let selected = kind == "teamocil" ? 1 : 0
                #expect(importedWindows[selected]["focus"] as? Bool == true)
                for (index, window) in importedWindows.enumerated() {
                    let panes = try #require(window["panes"] as? [[String: Any]])
                    let selectedPane = kind == "teamocil" && index == 1 ? 1 : 0
                    #expect(panes[selectedPane]["focus"] as? Bool == true)
                    #expect(panes.filter { $0["focus"] as? Bool == true }.count == 1)
                }
                #expect(importedWindows.filter { $0["focus"] as? Bool == true }.count == 1)
                if kind == "tmuxinator" {
                    #expect(
                        (document["shell_command_before"] as? [String: String])?["cmd"]
                            == "false; touch continued-project")
                    #expect(
                        (importedWindows[0]["shell_command_before"] as? [String: String])?["cmd"]
                            == "false && touch skipped-window")
                }
                let loaded = await invoke(
                    ["load", "-d", "-S", socket, destination.path, "--json"],
                    in: root, extra: environment)
                #expect(loaded.code == 0, "\(loaded.error)")
                let snapshot = try await server.snapshot()
                let session = try #require(snapshot.sessions.first { $0.name == kind })
                let windows = snapshot.windows(of: session)
                #expect(
                    windows.map(\.name)
                        == (kind == "teamocil" ? ["one", "two", "three"] : ["one", "two"]))
                #expect(
                    snapshot.windowLinks(of: session).filter(\.isActive).map(\.windowID)
                        == [windows[selected].id])
                for (index, window) in windows.enumerated() {
                    let selectedPane = kind == "teamocil" && index == 1 ? 1 : 0
                    #expect(
                        snapshot.panes(of: window).filter(\.isActive).map(\.index)
                            == [selectedPane])
                }
                let marker = root.appendingPathComponent("marker")
                var contents = ""
                for _ in 0..<100 {
                    contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
                    if contents == "done" { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(contents == "done")
                #expect(
                    FileManager.default.fileExists(atPath: root.path + "/continued-project")
                        == (kind == "tmuxinator"))
                #expect(!FileManager.default.fileExists(atPath: root.path + "/skipped-window"))
                try FileManager.default.removeItem(at: marker)
            }
        }
    }

    @Test("imported blank and pane strings remain executable commands")
    func importedLiteralCommands() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let marker = root.appendingPathComponent("literal-marker")
            for name in ["blank", "pane"] {
                let file = root.appendingPathComponent(name)
                try Data("#!/bin/sh\nprintf '\(name)\\n' >> '\(marker.path)'\n".utf8).write(
                    to: file)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
            try await server.setOption(
                "default-command",
                to: "exec /usr/bin/env PATH='\(root.path):/usr/bin:/bin' /bin/sh",
                scope: .globalSession)
            for (kind, name, text) in [
                (
                    "teamocil", "team",
                    #"{"name":"team","windows":[{"name":"work","panes":[{"cmd":"blank"},{"commands":"pane"}]}]}"#
                ),
                (
                    "tmuxinator", "window",
                    #"{"name":"window","windows":[{"work":["blank","pane"]}]}"#
                ),
                (
                    "tmuxinator", "prefix",
                    #"{"name":"prefix","pre_window":"blank","windows":[{"work":{"pre":"pane","panes":[":"]}}]}"#
                ),
            ] {
                let source = root.appendingPathComponent(name + ".json")
                let destination = root.appendingPathComponent(name + "-imported.json")
                try Data(text.utf8).write(to: source)
                let imported = await invoke(
                    [
                        "import", kind, source.path, "--save-to", destination.path,
                        "--workspace-format", "json", "--json",
                    ], in: root)
                #expect(imported.code == 0, "\(imported.error)")
                let loaded = await invoke(
                    ["load", "-d", "-S", socket, destination.path, "--json"], in: root,
                    extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
                #expect(loaded.code == 0, "\(loaded.error)")
                var contents = ""
                for _ in 0..<100 {
                    contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
                    if contents.split(separator: "\n").count == 2 { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                var captured: [String] = []
                if contents.isEmpty {
                    let snapshot = try await server.snapshot()
                    let session = try #require(snapshot.sessions.first { $0.name == name })
                    for pane in snapshot.panes(of: session) {
                        captured += try await server.capture(pane)
                    }
                }
                #expect(
                    contents.split(separator: "\n").sorted() == ["blank", "pane"],
                    "\(captured)")
                if FileManager.default.fileExists(atPath: marker.path) {
                    try FileManager.default.removeItem(at: marker)
                }
            }
        }
    }

    @Test("imports create loadable command groups with stable directories")
    func importedCommandGroups() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let project = root.appendingPathComponent("project")
            let destinationDirectory = root.appendingPathComponent("elsewhere")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: destinationDirectory, withIntermediateDirectories: false)
            for kind in ["teamocil", "tmuxinator"] {
                let source = root.appendingPathComponent("\(kind).json")
                let destination = destinationDirectory.appendingPathComponent("\(kind).json")
                let commands = [
                    "export IMPORT_SEQUENCE=first", "printf '%s\\n' \"$IMPORT_SEQUENCE\" > marker",
                ]
                let document: [String: Any] =
                    kind == "teamocil"
                    ? [
                        "name": kind, "root": "project",
                        "windows": [["name": "work", "panes": [["commands": commands]]]],
                    ]
                    : ["name": kind, "root": "project", "windows": [["work": commands]]]
                try JSONSerialization.data(withJSONObject: document).write(to: source)
                let imported = await invoke(
                    [
                        "import", kind, source.path, "--save-to", destination.path,
                        "--workspace-format", "json", "--json",
                    ], in: root)
                #expect(imported.code == 0, "\(imported.error)")
                let loaded = await invoke(
                    ["load", "-d", "-S", socket, destination.path, "--json"],
                    in: destinationDirectory, extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
                #expect(loaded.code == 0, "\(loaded.error)")
                let snapshot = try await server.snapshot()
                let session = try #require(snapshot.sessions.first { $0.name == kind })
                let windows = snapshot.windows(of: session)
                let window = try #require(windows.first)
                let panes = snapshot.panes(of: window)
                #expect(windows.count == 1)
                #expect(panes.count == 1)
                let marker = project.appendingPathComponent("marker")
                var contents = ""
                for _ in 0..<100 {
                    contents = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
                    if contents == "first\n" { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(contents == "first\n")
                try FileManager.default.removeItem(at: marker)
            }
        }
    }

    @Test("root version is a machine result")
    func machineVersion() async throws {
        try await withFiles { root in
            let result = await invoke(["--json", "--version"], in: root)
            #expect(result.code == 0)
            let value = try result.json()
            #expect(value["name"] as? String == "tmux-workspace")
            #expect(result.error.isEmpty)
        }
    }

    @Test("human --version prints a plain line, not JSON")
    func humanVersionIsPlainText() async throws {
        try await withFiles { root in
            let result = await invoke(["--version"], in: root)
            #expect(result.code == 0)
            #expect(result.output == ["tmux-workspace \(LibTmuxVersion.current)"])
            #expect(
                (try? JSONSerialization.jsonObject(with: Data(result.output.joined().utf8)))
                    == nil)
        }
    }

    @Test("invalid options are structured before backend access")
    func invalidOption() async throws {
        try await withFiles { root in
            let result = await invoke(["load", "missing", "--unknown", "--json"], in: root)
            #expect(result.code == 2)
            #expect(result.output.isEmpty)
            let diagnostic =
                try JSONSerialization.jsonObject(with: Data(result.error.joined().utf8))
                as? [String: Any]
            #expect(diagnostic?["code"] as? String == "usage")
        }
    }

    @Test(
        "legacy color mode fails before document or backend access",
        arguments: ["--json", "--ndjson"])
    func legacyColor(_ mode: String) async throws {
        try await withFiles { root in
            let result = await invoke(["load", "missing", "-d", "-8", mode], in: root)
            #expect(result.code == 2)
            #expect(result.output.isEmpty)
            #expect(result.error.joined().contains("unsupported_color_mode"))
            for flags in [["-2", "-8"], ["-8", "-2"]] {
                let conflict = await invoke(["load", "missing", "-d", mode] + flags, in: root)
                #expect(conflict.code == 2)
                #expect(conflict.output.isEmpty)
                #expect(conflict.error.joined().contains("Choose one of -2 and -8"))
            }
        }
    }

    @Test("machine root usage and empty search remain structured")
    func machineUsage() async throws {
        try await withFiles { root in
            for arguments in [["--json"], ["search", "--ndjson"]] {
                let result = await invoke(arguments, in: root)
                #expect(result.code == 2)
                #expect(result.output.isEmpty)
                #expect(result.error.joined().contains("usage"))
            }
        }
    }

    @Test(
        "implicit attachment fails before input discovery without a terminal",
        arguments: [[], ["--json"], ["--ndjson"]])
    func loadModePreflight(_ mode: [String]) async throws {
        try await withFiles { root in
            let result = await invoke(["load", "missing"] + mode, in: root)
            #expect(result.code == 2)
            #expect(result.output.isEmpty)
            #expect(
                result.error.joined().contains(
                    mode.isEmpty ? "foreground terminal" : "-d or --append"))
            guard !mode.isEmpty else { return }
            // A machine load with no way to attach is a usage error, the
            // same code the other six ports report for it.
            #expect(result.error.joined().contains("\"code\":\"usage\""), "\(result.error)")
        }
    }

    @Test("native parser help and completion are executable")
    func parserHelp() async throws {
        try await withFiles { root in
            for arguments in [
                ["--help"], ["load", "--help"], ["help", "freeze"],
                ["--generate-completion-script", "zsh"],
            ] {
                let result = await invoke(arguments, in: root)
                #expect(result.code == 0)
                #expect(!result.output.isEmpty)
                #expect(result.error.isEmpty)
            }
        }
    }

    @Test("root --help documents the completion flag")
    func completionFlagIsDocumented() async throws {
        try await withFiles { root in
            let result = await invoke(["--help"], in: root)
            #expect(result.code == 0)
            #expect(
                result.output.joined(separator: "\n").contains("--generate-completion-script"),
                "\(result.output)")
        }
    }

    @Test("diagnostic levels filter warnings without hiding results or failures")
    func diagnosticLevels() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let session = try await server.newSession(named: "levels")
            for level in ["debug", "info", "warning", "error", "critical"] {
                let arguments = ["freeze", session.name, "-S", socket, "--json"]
                for flags in [
                    ["--log-level", level] + arguments, arguments + ["--log-level", level],
                ] {
                    let result = await invoke(
                        flags, in: root, extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
                    try #require(result.code == 0, "\(result.error)")
                    #expect(try result.json()["session_name"] as? String == "levels")
                    #expect(result.error.isEmpty == ["error", "critical"].contains(level))
                }
            }
            let invalid = await invoke(
                ["convert", "missing", "--log-level", "invalid", "--ndjson"], in: root)
            #expect(invalid.code == 2)
            #expect(invalid.output.isEmpty)
            let failure = await invoke(
                ["convert", "missing", "--log-level", "critical", "--json"], in: root)
            #expect(failure.code == 1)
            #expect(failure.output.isEmpty)
            #expect(!failure.error.isEmpty)
        }
    }

    @Test("load logs append structured diagnostics without changing stderr")
    func loadLogPreflight() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("load.log")
            for mode in ["--json", "--ndjson"] {
                let result = await invoke(
                    ["load", "missing", "-d", "--log-file", file.path, mode], in: root)
                #expect(result.code == 1)
                #expect(result.output.isEmpty)
                #expect(result.error.joined().contains("workspace_not_found"))
            }
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            #expect(lines.count == 2)
            for line in lines {
                let record = try JSONDecoder().decode(Value.self, from: Data(line.utf8))
                #expect(record["severity"] == .string("error"))
                #expect(record["code"] == .string("workspace_not_found"))
            }
            let fifo = root.appendingPathComponent("log.fifo")
            try #require(mkfifo(fifo.path, 0o600) == 0)
            let rejected = await invoke(
                ["load", "missing", "-d", "--log-file", fifo.path, "--json"], in: root)
            #expect(rejected.code == 1)
            #expect(rejected.output.isEmpty)
            #expect(rejected.error.joined().contains("log_open"))
        }
    }

    @Test("progress flags validate before document and backend access")
    func progressFlags() async throws {
        try await withFiles { root in
            for preset in [
                "default", "minimal", "window", "pane", "verbose", "{session} {pane_progress}",
            ] {
                let result = await invoke(
                    [
                        "load", "missing", "-d", "--progress-format", preset,
                        "--progress-lines", "-1", "--json",
                    ], in: root)
                #expect(result.code == 1)
                #expect(result.output.isEmpty)
                #expect(result.error.joined().contains("workspace_not_found"))
            }
            for value in ["bad", "-2"] {
                let arguments = await invoke(
                    ["load", "missing", "-d", "--progress-lines", value, "--ndjson"], in: root)
                #expect(arguments.code == 2)
                #expect(arguments.output.isEmpty)
                let environment = await invoke(
                    ["load", "missing", "-d", "--json"], in: root,
                    extra: ["TMUXP_PROGRESS_LINES": value])
                #expect(environment.code == 2)
                #expect(environment.output.isEmpty)
            }
        }
    }

    @Test("load logs lifecycle events and escaped bootstrap output")
    func loadLog() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let input = root.appendingPathComponent("logged.json")
            try Data(
                #"{"session_name":"logged","before_script":"/usr/bin/printf 'line\\n\\033[31m'","windows":[{"panes":[null]}]}"#
                    .utf8
            ).write(to: input)
            let file = root.appendingPathComponent("load.log")
            let result = await invoke(
                [
                    "load", input.path, "-d", "-S", socket, "--log-file", file.path,
                    "--log-level", "info", "--json",
                ],
                in: root, extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            try #require(result.code == 0, "\(result.error)")
            #expect(try result.json()["status"] as? String == "ok")
            #expect(try await server.sessions().contains { $0.name == "logged" })
            let raw = try String(contentsOf: file, encoding: .utf8)
            #expect(!raw.contains("\u{1b}"))
            let records = try raw.split(separator: "\n").map {
                try JSONDecoder().decode(Value.self, from: Data($0.utf8))
            }
            #expect(
                records.compactMap { $0["event"]?.string } == [
                    "started", "workspace-started", "session-created", "script-started",
                    "script-output", "script-completed", "window-created", "pane-created",
                    "pane-completed", "window-completed", "workspace-completed", "completed",
                ])
            #expect(records.contains { $0["code"] == .string("bootstrap_stdout") })
            #expect(result.error.joined().contains("bootstrap_stdout"))
        }
    }

    @Test("ndjson load events are flat records carrying input, session and object ids")
    func ndjsonEventContract() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("ndjson-events.json")
            try Data(
                #"{"session_name":"ndjson-events","windows":[{"panes":[null,null]}]}"#.utf8
            ).write(to: file)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "--ndjson"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(result.code == 0, "\(result.error)")
            let records = try result.output.map {
                try JSONDecoder().decode(Value.self, from: Data($0.utf8))
            }
            // Event fields sit at the top level; five of seven ports already
            // agree and dotnet and swift were the two holdouts.
            #expect(records.allSatisfy { $0["data"] == nil }, "\(records)")
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "ndjson-events" })
            let workspaceStarted = try #require(
                records.first { $0["event"] == .string("workspace-started") })
            #expect(workspaceStarted["input"] == .string(file.path))
            #expect(workspaceStarted["input_index"] == .integer(0))
            let sessionCreated = try #require(
                records.first { $0["event"] == .string("session-created") })
            #expect(sessionCreated["input_index"] == .integer(0))
            #expect(sessionCreated["session_id"] == .string(session.id.rawValue))
            #expect(sessionCreated["session_name"] == .string("ndjson-events"))
            let windowCreated = try #require(
                records.first { $0["event"] == .string("window-created") })
            #expect(windowCreated["input_index"] == .integer(0))
            #expect(windowCreated["session_id"] == .string(session.id.rawValue))
            #expect(windowCreated["window_id"]?.string != nil)
            let windowCompleted = try #require(
                records.first { $0["event"] == .string("window-completed") })
            #expect(windowCompleted["input_index"] == .integer(0))
            #expect(windowCompleted["session_id"] == .string(session.id.rawValue))
            #expect(windowCompleted["window_id"] == windowCreated["window_id"])
            let paneCreated = try #require(
                records.first { $0["event"] == .string("pane-created") })
            #expect(paneCreated["input_index"] == .integer(0))
            #expect(paneCreated["session_id"] == .string(session.id.rawValue))
            #expect(paneCreated["window_id"] == windowCreated["window_id"])
            #expect(paneCreated["pane_id"]?.string != nil)
            #expect(paneCreated["pane_index"] == .integer(1))
            let paneCompleted = try #require(
                records.first { $0["event"] == .string("pane-completed") })
            #expect(paneCompleted["pane_id"] == paneCreated["pane_id"])
            #expect(paneCompleted["window_id"] == windowCreated["window_id"])
        }
    }

    @Test("log write failures retain the primary load outcome")
    func logWriteFailure() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let input = root.appendingPathComponent("limited.json")
            try Data(#"{"session_name":"limited","windows":[{"panes":[null]}]}"#.utf8).write(
                to: input)
            let executable = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/debug/tmux-workspace")
            try #require(FileManager.default.isExecutableFile(atPath: executable.path))
            for source in [input.path, "missing"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [
                    "-c", "ulimit -f 0; trap '' XFSZ; exec \"$@\"", "workspace-log-limit",
                    executable.path, "load", source, "-d", "-S", socket, "--json",
                    "--log-file", root.appendingPathComponent("limited.log").path,
                    "--log-level", "info",
                ]
                process.environment = ProcessInfo.processInfo.environment.merging([
                    "LIBTMUX_TMUX_BIN": server.tmuxExecutable, "TMUXP_CONFIGDIR": root.path,
                ]) { _, new in new }
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                try process.run()
                process.waitUntilExit()
                let out = stdout.fileHandleForReading.readDataToEndOfFile()
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                let records = try String(decoding: err, as: UTF8.self).split(separator: "\n").map {
                    try JSONDecoder().decode(Value.self, from: Data($0.utf8))
                }
                #expect(records.filter { $0["code"] == .string("log_write") }.count == 1)
                if source == input.path {
                    #expect(process.terminationStatus == 0)
                    #expect(
                        try JSONDecoder().decode(Value.self, from: out)["status"]
                            == .string("ok"))
                } else {
                    #expect(process.terminationStatus == 1)
                    #expect(out.isEmpty)
                    #expect(records.contains { $0["code"] == .string("workspace_not_found") })
                }
            }
            #expect(try await server.sessions().contains { $0.name == "limited" })
        }
    }

    @Test("native read commands preserve generic documents and machine framing")
    func readCommands() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("dev.json")
            try Data(
                #"{"session_name":"project","extension":{"keep":true},"windows":[{"window_name":"editor","panes":["echo hello"]}]}"#
                    .utf8
            ).write(to: file)
            let listed = await invoke(["--json", "ls", "--full"], in: root)
            #expect(listed.code == 0)
            let rows = try #require(try listed.json()["workspaces"] as? [[String: Any]])
            #expect(rows.count == 1)
            #expect(rows[0]["name"] as? String == "dev")
            let searched = await invoke(
                ["search", "pane:hello", "--json", "--ndjson", "--color", "always"], in: root)
            #expect(searched.code == 0)
            #expect(searched.output.count == 1)
            #expect(!searched.output.joined().contains("\u{1b}"))
            #expect(try searched.json()["name"] as? String == "dev")
            let converted = await invoke(["convert", file.path, "--json"], in: root)
            #expect(converted.code == 0)
            #expect((try converted.json()["extension"] as? [String: Bool])?["keep"] == true)
            let streamed = await invoke(["convert", file.path, "--ndjson"], in: root)
            #expect(
                (try streamed.json()["workspace"] as? [String: Any])?["session_name"] as? String
                    == "project")
        }
    }

    @Test("native importers resolve sources and preserve workspace structure")
    func importWorkspaces() async throws {
        try await withFiles { root in
            let source = root.appendingPathComponent("incoming")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let tmuxinator = source.appendingPathComponent("work.json")
            try Data(
                #"{"name":"imported","root":"/tmp","windows":[{"editor":{"layout":"tiled","panes":["one","two"]}}]}"#
                    .utf8
            ).write(to: tmuxinator)
            let imported = await invoke(
                ["--json", "import", "tmuxinator", "work"], in: root,
                extra: ["TMUXINATOR_CONFIG": source.path])
            #expect(imported.code == 0, "\(imported.error)")
            let document = try imported.json()
            #expect(document["session_name"] as? String == "imported")
            let windows = try #require(document["windows"] as? [[String: Any]])
            let panes = try #require(windows[0]["panes"] as? [[String: Any]])
            #expect(
                panes.compactMap { $0["shell_command"] as? [[String: String]] }
                    == [[["cmd": "one"]], [["cmd": "two"]]])
            #expect(windows[0]["focus"] as? Bool == true)
            #expect(panes[0]["focus"] as? Bool == true)
            let teamocil = root.appendingPathComponent("team.json")
            try Data(
                #"{"session":{"name":"team","windows":[{"name":"shell","splits":[{"cmd":"echo <%= literal %>"}]}]}}"#
                    .utf8
            ).write(to: teamocil)
            let streamed = await invoke(
                ["import", "teamocil", teamocil.path, "--ndjson"], in: root)
            #expect(streamed.code == 0, "\(streamed.error)")
            let envelope = try streamed.json()
            #expect(envelope["schema_version"] as? Int == 1)
            let teamocilWorkspace = try #require(envelope["workspace"] as? [String: Any])
            #expect(teamocilWorkspace["session_name"] as? String == "team")
            let teamocilWindows = try #require(teamocilWorkspace["windows"] as? [[String: Any]])
            let teamocilPanes = try #require(teamocilWindows.first?["panes"] as? [[String: Any]])
            // Teamocil evaluates no templates, so this markup is ordinary text
            // and must survive the import unchanged.
            #expect(
                teamocilPanes.first?["shell_command"] as? [String: String]
                    == ["cmd": "echo <%= literal %>"])
            // An optional field left out, or written empty, has to leave the
            // key out of the workspace rather than emit a null the loader then
            // refuses as the wrong type.
            let sparse = root.appendingPathComponent("sparse.json")
            try Data(
                #"{"session":{"name":"sparse","windows":[{"focus":null,"splits":[{}]}]}}"#.utf8
            ).write(to: sparse)
            let sparseImport = await invoke(
                ["--json", "import", "teamocil", sparse.path], in: root)
            #expect(sparseImport.code == 0, "\(sparseImport.error)")
            let sparseWindows = try #require(try sparseImport.json()["windows"] as? [[String: Any]])
            #expect(sparseWindows[0]["window_name"] == nil)
            #expect(sparseWindows[0]["layout"] == nil)
            let sparsePanes = try #require(sparseWindows[0]["panes"] as? [[String: Any]])
            #expect(sparsePanes[0]["shell_command"] == nil)
            let emptyLayout = source.appendingPathComponent("sparse.json")
            try Data(
                #"{"name":"sparse","windows":[{"editor":{"layout":null,"panes":["one"]}}]}"#.utf8
            ).write(to: emptyLayout)
            let layoutImport = await invoke(
                ["--json", "import", "tmuxinator", "sparse"], in: root,
                extra: ["TMUXINATOR_CONFIG": source.path])
            #expect(layoutImport.code == 0, "\(layoutImport.error)")
            let layoutWindows = try #require(try layoutImport.json()["windows"] as? [[String: Any]])
            #expect(layoutWindows[0]["layout"] == nil)
            let missing = await invoke(["import", "teamocil", "--json"], in: root)
            #expect(missing.code == 2)
            #expect(missing.output.isEmpty)
            let destination = root.appendingPathComponent("saved.json")
            let saveArgs = [
                "import", "teamocil", teamocil.path, "--save-to", destination.path,
                "--workspace-format", "json", "--json",
            ]
            let saved = await invoke(saveArgs, in: root)
            #expect(saved.code == 0)
            let original = try Data(contentsOf: destination)
            let protected = await invoke(saveArgs, in: root)
            #expect(protected.code == 1)
            #expect(try Data(contentsOf: destination) == original)
            let forced = await invoke(saveArgs + ["--force"], in: root)
            #expect(forced.code == 0)
        }
    }

    @Test(
        "conversion saves explicit destinations in both machine modes",
        arguments: ["--json", "--ndjson"])
    func conversionSave(mode: String) async throws {
        try await withFiles { root in
            let input = root.appendingPathComponent("source.json")
            let destination = root.appendingPathComponent("saved.json")
            try Data(#"{"session_name":"before","extension":{"keep":true}}"#.utf8).write(to: input)
            let arguments = [
                "convert", input.path, "--save-to", destination.path,
                "--workspace-format", "json", mode,
            ]
            let saved = await invoke(arguments, in: root)
            try #require(saved.code == 0, "\(saved.error)")
            let metadata = try saved.json()
            #expect(metadata["schema_version"] as? Int == 1)
            #expect(metadata["command"] as? String == "convert")
            #expect(metadata["destination"] as? String == destination.path)
            let original = try Data(contentsOf: destination)
            #expect(
                try JSONDecoder().decode(Value.self, from: original)["extension"]?["keep"]
                    == .bool(true))
            try Data(#"{"session_name":"after"}"#.utf8).write(to: input)
            let protected = await invoke(arguments, in: root)
            #expect(protected.code == 1)
            #expect(try Data(contentsOf: destination) == original)
            let replaced = await invoke(arguments + ["--force"], in: root)
            #expect(replaced.code == 0, "\(replaced.error)")
            #expect(
                try JSONDecoder().decode(Value.self, from: Data(contentsOf: destination))[
                    "session_name"] == .string("after"))
        }
    }

    @Test(
        "NUL configuration values fail before any input reaches tmux",
        arguments: ["session_name", "start_directory", "window_name", "layout", "command"])
    func nulPreflight(field: String) async throws {
        try await withFiles { root in
            let first = root.appendingPathComponent("first.json")
            try Data(#"{"session_name":"first","windows":[{"panes":[null]}]}"#.utf8).write(
                to: first)
            var window: [String: Value] = ["panes": .array([.null])]
            var document: [String: Value] = ["session_name": .string("second")]
            if field == "command" {
                window["panes"] = .array([.string("printf before\0after")])
            } else if ["session_name", "start_directory"].contains(field) {
                document[field] = .string("before\0after")
            } else {
                window[field] = .string("before\0after")
            }
            document["windows"] = .array([.object(window)])
            let second = root.appendingPathComponent("second.json")
            try Data(Value.object(document).encoded().utf8).write(to: second)
            let result = await invoke(
                ["load", first.path, second.path, "-d", "-S", root.path + "/unused", "--json"],
                in: root)
            #expect(result.code == 1)
            #expect(result.output.isEmpty)
            let error = try JSONDecoder().decode(
                Value.self, from: Data(result.error.joined().utf8))
            #expect(error["code"] == .string("invalid_workspace"))
            #expect(error["message"]?.string?.contains("NUL") == true)
        }
    }

    @Test(
        "NDJSON discovery emits a document before reading the next",
        arguments: [["ls", "--full", "--ndjson"], ["search", "workspace", "--ndjson"]])
    func incrementalDiscovery(arguments: [String]) async throws {
        try await withFiles { root in
            let later = root.appendingPathComponent("b.json")
            try Data(#"{"session_name":"workspace-first"}"#.utf8).write(
                to: root.appendingPathComponent("a.json"))
            try Data(#"{"session_name":"workspace-before"}"#.utf8).write(to: later)
            let lines = Lines()
            let errors = Lines()
            let context = CLIContext(
                directory: root,
                environment: ["TMUXP_CONFIGDIR": root.path, "LIBTMUX_TMUX_BIN": "/unavailable"],
                output: { line in
                    await lines.append(line)
                    let value = try JSONDecoder().decode(Value.self, from: Data(line.utf8))
                    if value["name"]?.string == "a" {
                        try Data(#"{"session_name":"workspace-after"}"#.utf8).write(to: later)
                    }
                }, error: { await errors.append($0) })
            let code = await WorkspaceCLI.run(arguments, context: context)
            #expect(code == 0)
            #expect(await errors.values.isEmpty)
            let records = try await lines.values.map {
                try JSONDecoder().decode(Value.self, from: Data($0.utf8))
            }
            #expect(
                records.map { $0["session_name"]?.string } == [
                    "workspace-first", "workspace-after",
                ])
        }
    }

    @Test("importers validate known fields instead of discarding values")
    func importerTypes() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("typed-import.json")
            try Data(#"{"name":"typed","rbenv":2.7,"windows":[]}"#.utf8).write(to: file)
            let ruby = await invoke(["import", "tmuxinator", file.path, "--json"], in: root)
            #expect(ruby.code == 1)
            #expect(ruby.output.isEmpty)
            for source in [
                #"{"name":"typed","cli_args":{},"windows":[]}"#,
                #"{"name":"typed","windows":[{"name":"one","filters":false,"panes":[null]}]}"#,
                #"{"name":"typed","windows":[{"name":"one","filters":{"before":false},"panes":[null]}]}"#,
            ] {
                try Data(source.utf8).write(to: file)
                let result = await invoke(
                    [
                        "import", source.contains("cli_args") ? "tmuxinator" : "teamocil",
                        file.path, "--json",
                    ], in: root)
                #expect(result.code == 1)
                #expect(result.output.isEmpty)
            }
            try Data(
                #"{"name":"typed","windows":[{"name":"one","filters":{"unknown":"echo lost"},"panes":[null]}]}"#
                    .utf8
            ).write(to: file)
            let warned = await invoke(["import", "teamocil", file.path, "--json"], in: root)
            #expect(warned.code == 1)
            #expect(warned.output.isEmpty)
            #expect(warned.error.joined().contains("filters"))
        }
    }

    @Test(
        "Python shell bridge uses a versioned runtime and explicit endpoint",
        .enabled(if: ProcessInfo.processInfo.environment["TMUX_WORKSPACE_TEST_PYTHON"] != nil))
    func shellBridge() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let session = try await server.sessions()[0]
            let result = await invoke(
                [
                    "shell", session.name, "-S", socket, "--code", "--no-startup",
                    "-c",
                    "print('CLI_RESULT=' + session.session_name); print('CLI_TMUX=' + str(server.tmux_bin))",
                    "--ndjson",
                ], in: root,
                extra: [
                    "LIBTMUX_TMUX_BIN": server.tmuxExecutable,
                    "TMUX_WORKSPACE_PYTHON": ProcessInfo.processInfo.environment[
                        "TMUX_WORKSPACE_TEST_PYTHON"] ?? "python3",
                    "HOME": ProcessInfo.processInfo.environment["HOME"] ?? root.path,
                ])
            #expect(result.code == 0, "\(result.error)")
            guard result.code == 0 else { return }
            let childOutput = try result.json()["stdout"] as? String
            #expect(
                childOutput?.hasSuffix(
                    "CLI_RESULT=" + session.name + "\nCLI_TMUX=" + server.tmuxExecutable + "\n")
                    == true)
        }
    }

    @Test("shell runtime and parser failures precede evaluation")
    func shellRuntime() async throws {
        try await withFiles { root in
            let fake = root.appendingPathComponent("python")
            try Data("#!/bin/sh\nprintf '0.0.0\\n'\n".utf8).write(to: fake)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: fake.path)
            for python in [fake.path, "/missing-python"] {
                let result = await invoke(
                    [
                        "shell", "-S", root.appendingPathComponent("unused").path, "-c", "pass",
                        "--json",
                    ],
                    in: root, extra: ["TMUX_WORKSPACE_PYTHON": python])
                #expect(result.code == 1)
                #expect(result.output.isEmpty)
                #expect(result.error.joined().contains("unsupported_runtime"))
            }
            for arguments in [["shell", "--code", "--ipython", "--json"], ["shell", "--json"]] {
                let result = await invoke(arguments, in: root)
                #expect(result.code == 2)
                #expect(result.output.isEmpty)
            }
        }
    }

    @Test("Python paired toggles preserve occurrence order")
    func shellFlags() throws {
        for (flags, expected) in [
            (["--use-pythonrc", "--no-startup"], PythonStartup.noStartup),
            (["--no-startup", "--use-pythonrc"], PythonStartup.usePythonrc),
        ] {
            let parsed = try #require(WorkspaceRoot.parseAsRoot(["shell"] + flags) as? Shell)
            #expect(parsed.startup == expected)
        }
        for (flags, expected) in [
            (["--use-vi-mode", "--no-vi-mode"], PythonViMode.noViMode),
            (["--no-vi-mode", "--use-vi-mode"], PythonViMode.useViMode),
        ] {
            let parsed = try #require(WorkspaceRoot.parseAsRoot(["shell"] + flags) as? Shell)
            #expect(parsed.viMode == expected)
        }
    }

    @Test("native diagnostics report unavailable and selected tmux binaries")
    func diagnostics() async throws {
        try await withFiles { root in
            let unavailable = await invoke(["debug-info", "--json"], in: root)
            #expect(unavailable.code == 0)
            let value = try unavailable.json()
            #expect(value["port"] as? String == "swift")
            #expect((value["tmux"] as? [String: Any])?["available"] as? Bool == false)
            #expect(!unavailable.output.joined().contains(root.path))
            let binary = root.appendingPathComponent("fake-tmux")
            try Data("#!/bin/sh\nprintf 'tmux 3.2a\\n'\n".utf8).write(to: binary)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: binary.path)
            let available = await invoke(
                ["debug-info", "--ndjson"], in: root, extra: ["LIBTMUX_TMUX_BIN": binary.path])
            #expect(available.code == 0)
            #expect(
                (try available.json()["tmux"] as? [String: Any])?["version"] as? String
                    == "tmux 3.2a")
        }
    }

    @Test("human debug-info prints plain lines, not JSON")
    func humanDiagnosticsAreLines() async throws {
        try await withFiles { root in
            let result = await invoke(["debug-info"], in: root)
            #expect(result.code == 0)
            let text = result.output.joined(separator: "\n")
            #expect((try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil)
            #expect(text.contains("swift"))
            #expect(text.contains(LibTmuxVersion.current))
        }
    }

    @Test("quoted argv preserves ordinary backslashes and joins continuations")
    func quotedArguments() throws {
        #expect(
            try ProcessCommands.splitArguments(#"editor "a\q" "\$x" "\`x" "\\" "\"" 'literal\q'"#)
                == ["editor", #"a\q"#, "$x", "`x", "\\", "\"", #"literal\q"#])
        #expect(
            try ProcessCommands.splitArguments("editor foo\\\nbar \\\n") == ["editor", "foobar"])
    }

    @Test("editor argv and child exit status survive native execution")
    func editor() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("edit.json")
            try Data(#"{"session_name":"edit","windows":[]}"#.utf8).write(to: file)
            let script = root.appendingPathComponent("editor helper")
            try Data(
                "#!/bin/sh\nprintf '%s\\n' \"$1\" \"$2\" > \"$MARKER\"\nexit \"$EDITOR_EXIT\"\n"
                    .utf8
            ).write(to: script)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: script.path)
            let marker = root.appendingPathComponent("argv")
            let environment = [
                "EDITOR": "'\(script.path)' 'two words'", "MARKER": marker.path, "EDITOR_EXIT": "7",
            ]
            let failed = await invoke(["edit", "edit", "--json"], in: root, extra: environment)
            #expect(failed.code == 7)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "two words\n\(file.path)\n")
            let completed = await invoke(
                ["edit", "edit", "--ndjson"], in: root,
                extra: environment.merging(["EDITOR_EXIT": "0"]) { _, right in right })
            #expect(completed.code == 0)
            #expect(try completed.json()["exit_code"] as? Int == 0)
        }
    }

    @Test("process output limits and cancellation keep machine streams clean")
    func processBoundaries() async throws {
        try await withFiles { root in
            try Data(#"{"session_name":"edit","windows":[]}"#.utf8).write(
                to: root.appendingPathComponent("edit.json"))
            let invalid = await invoke(
                ["edit", "edit", "--json"], in: root, extra: ["EDITOR": "'unfinished"])
            #expect(invalid.code == 2)
            #expect(invalid.output.isEmpty)
            let overflow = await invoke(
                ["edit", "edit", "--ndjson"], in: root,
                extra: ["EDITOR": "/bin/sh -c 'head -c 1048577 /dev/zero'"])
            #expect(overflow.code == 1)
            #expect(overflow.output.count == 0)
            let marker = root.appendingPathComponent("ready")
            let task = Task {
                await invoke(
                    ["edit", "edit", "--json"], in: root,
                    extra: [
                        "EDITOR": "/bin/sh -c 'echo ready > \"$MARKER\"; exec sleep 30'",
                        "MARKER": marker.path,
                    ])
            }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let start = ContinuousClock.now
            task.cancel()
            let cancelled = await task.value
            #expect(cancelled.code == 130)
            #expect(cancelled.output.isEmpty)
            #expect(start.duration(to: .now) < .seconds(1))
        }
    }

    @Test(
        "discovery and bare names share the first existing configuration directory",
        arguments: [
            "configured", "configured-empty", "missing-configured", "file-configured",
            "xdg-empty", "legacy", "none", "empty-xdg", "symlink-configured",
        ])
    func activeConfigurationDirectory(_ scenario: String) async throws {
        try await withFiles { root in
            let configured = root.appendingPathComponent("configured")
            let xdg = root.appendingPathComponent("xdg/tmuxp")
            let legacy = root.appendingPathComponent(".tmuxp")
            let fallback = root.appendingPathComponent(".config/tmuxp")
            for (directory, name) in [
                (configured, "configured"), (xdg, "xdg"), (legacy, "legacy"),
                (fallback, "default"),
            ] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try Data("{\"session_name\":\"\(name)\",\"windows\":[]}".utf8).write(
                    to: directory.appendingPathComponent(name + ".json"))
            }
            var active = configured
            var name: String? = "configured"
            if scenario == "configured-empty" {
                try FileManager.default.removeItem(
                    at: configured.appendingPathComponent("configured.json"))
                name = nil
            } else if scenario != "configured" {
                try FileManager.default.removeItem(at: configured)
                active = xdg
                name = "xdg"
                if scenario == "file-configured" { try Data().write(to: configured) }
                if scenario == "xdg-empty" {
                    try FileManager.default.removeItem(at: xdg.appendingPathComponent("xdg.json"))
                    name = nil
                } else if ["legacy", "none"].contains(scenario) {
                    try FileManager.default.removeItem(at: xdg)
                    active = legacy
                    name = "legacy"
                    if scenario == "none" {
                        try FileManager.default.removeItem(at: legacy)
                        name = nil
                    }
                } else if scenario == "empty-xdg" {
                    active = fallback
                    name = "default"
                } else if scenario == "symlink-configured" {
                    try FileManager.default.createSymbolicLink(
                        at: configured, withDestinationURL: legacy)
                    active = configured
                    name = "legacy"
                }
            }
            let environment = [
                "TMUXP_CONFIGDIR": configured.path,
                "XDG_CONFIG_HOME": scenario == "empty-xdg"
                    ? "" : xdg.deletingLastPathComponent().path,
            ]
            let listed = await invoke(["ls", "--json"], in: root, extra: environment)
            #expect(listed.code == 0)
            let document = try listed.json()
            #expect(document["global_workspace_dirs"] as? [String] == [active.path])
            let workspaces = try #require(document["workspaces"] as? [[String: Any]])
            #expect(workspaces.compactMap { $0["name"] as? String } == name.map { [$0] } ?? [])
            if let name {
                #expect(
                    workspaces.first?["path"] as? String
                        == active.appendingPathComponent(name + ".json").path)
                let resolved = await invoke(
                    ["convert", name, "--json"], in: root, extra: environment)
                #expect(resolved.code == 0, "\(resolved.error)")
                #expect(try resolved.json()["session_name"] as? String == name)
            }
            if name != "legacy" {
                let inactive = await invoke(
                    ["convert", "legacy", "--json"], in: root, extra: environment)
                #expect(inactive.code == 1)
                #expect(inactive.error.joined().contains("workspace_not_found"))
            }
            if scenario == "none" {
                #expect(!FileManager.default.fileExists(atPath: configured.path))
                #expect(!FileManager.default.fileExists(atPath: xdg.path))
                #expect(!FileManager.default.fileExists(atPath: legacy.path))
            }
        }
    }

    @Test("import names stay in their source directory", arguments: ["teamocil", "tmuxinator"])
    func importDirectoryIsolation(_ kind: String) async throws {
        try await withFiles { root in
            let global = root.appendingPathComponent(".tmuxp")
            try FileManager.default.createDirectory(at: global, withIntermediateDirectories: true)
            try Data(#"{"name":"decoy","windows":[]}"#.utf8).write(
                to: global.appendingPathComponent("work.json"))
            let source = root.appendingPathComponent("." + kind)
            let environment = [
                "TMUXINATOR_CONFIG": source.path,
                "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
            ]
            let missing = await invoke(
                ["import", kind, "work", "--json"], in: root, extra: environment)
            #expect(missing.code == 1)
            #expect(missing.output.isEmpty)
            #expect(missing.error.joined().contains("workspace_not_found"))
            #expect(!FileManager.default.fileExists(atPath: source.path))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let document =
                kind == "teamocil"
                ? #"{"name":"imported","windows":[{"name":"work","panes":[null]}]}"#
                : #"{"name":"imported","windows":[{"work":null}]}"#
            try Data(document.utf8).write(
                to: source.appendingPathComponent("work.json"))
            let imported = await invoke(
                ["import", kind, "work", "--json"], in: root, extra: environment)
            #expect(imported.code == 0, "\(imported.error)")
            #expect(try imported.json()["session_name"] as? String == "imported")
        }
    }

    @Test("bare names resolve globally and explicit files resolve locally")
    func workspaceResolution() async throws {
        try await withFiles { root in
            let global = root.appendingPathComponent("global")
            try FileManager.default.createDirectory(at: global, withIntermediateDirectories: false)
            try Data(#"{"session_name":"local","windows":[]}"#.utf8).write(
                to: root.appendingPathComponent("dev.json"))
            try Data(#"{"session_name":"global","windows":[]}"#.utf8).write(
                to: global.appendingPathComponent("dev.json"))
            let named = await invoke(
                ["convert", "dev", "--json"], in: root, extra: ["TMUXP_CONFIGDIR": global.path])
            let local = await invoke(
                ["convert", "./dev.json", "--json"], in: root,
                extra: ["TMUXP_CONFIGDIR": global.path])
            #expect(named.code == 0, "\(named.error)")
            #expect(local.code == 0, "\(local.error)")
            #expect(try named.json()["session_name"] as? String == "global")
            #expect(try local.json()["session_name"] as? String == "local")
        }
    }

    #if YAMLWorkspaces
        @Test("failed conversion writes leave no destination or temporary file")
        func atomicWriteFailure() async throws {
            try await withFiles { root in
                let input = root.appendingPathComponent("large.yaml")
                try Data(
                    ("session_name: test\nvalue: " + String(repeating: "x", count: 16_384) + "\n")
                        .utf8
                ).write(to: input)
                let executable = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent(".build/debug/tmux-workspace")
                try #require(FileManager.default.isExecutableFile(atPath: executable.path))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [
                    "-c", "ulimit -f 1; trap '' XFSZ; exec \"$@\"", "workspace-file-limit",
                    executable.path, "convert", input.path, "-y",
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 1)
                let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
                #expect(remaining == ["large.yaml"])
                let saved = await invoke(["convert", input.path, "-y"], in: root)
                #expect(saved.code == 0)
                let destination = root.appendingPathComponent("large.json")
                let original = try Data(contentsOf: destination)
                try Data("session_name: changed\n".utf8).write(to: input)
                let protected = await invoke(["convert", input.path, "-y"], in: root)
                #expect(protected.code == 1)
                #expect(try Data(contentsOf: destination) == original)
            }
        }

        @Test("YAML retains quoted scalar types and rejects multiple documents")
        func yamlTypes() async throws {
            try await withFiles { root in
                let file = root.appendingPathComponent("typed.yaml")
                try Data("session_name: 'true'\nnumber: '001'\nflag: false\nwindows: []\n".utf8)
                    .write(to: file)
                let converted = await invoke(["convert", file.path, "--json"], in: root)
                #expect(converted.code == 0)
                let document = try converted.json()
                #expect(document["session_name"] as? String == "true")
                #expect(document["number"] as? String == "001")
                #expect(document["flag"] as? Bool == false)
                try Data("session_name: one\n---\nsession_name: two\n".utf8).write(to: file)
                let rejected = await invoke(["convert", file.path, "--json"], in: root)
                #expect(rejected.code == 1)
                #expect(rejected.output.isEmpty)
            }
        }
    #endif

    @Test("unsupported configuration fails before endpoint lookup")
    func rejectsUnsupported() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("unsupported.json")
            try Data(
                #"{"session_name":"invalid","plugins":["unavailable"],"windows":[{"panes":[null]}]}"#
                    .utf8
            ).write(to: file)
            let rejected = await invoke(["load", file.path, "-d", "--json"], in: root)
            #expect(rejected.code == 1)
            #expect(rejected.output.isEmpty)
            #expect(rejected.error.joined().contains("unsupported_key"))
        }
    }

    @Test("expanded session names are validated before endpoint lookup")
    func expandedSessionName() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("expanded.json")
            try Data(#"{"session_name":"${WORKSPACE_NAME}","windows":[{"panes":[null]}]}"#.utf8)
                .write(to: file)
            for name in ["", "bad:name", "bad.name", "bad\nname"] {
                let result = await invoke(
                    ["load", file.path, "-d", "--json"], in: root, extra: ["WORKSPACE_NAME": name])
                #expect(result.code == 1)
                #expect(result.output.isEmpty)
                #expect(
                    result.error.joined().contains("\"code\":\"invalid_workspace\""),
                    "\(result.error)")
            }
        }
    }

    @Test("workspace reads reject FIFO inputs")
    func specialFile() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("pipe.json")
            try #require(mkfifo(file.path, 0o600) == 0)
            let descriptor = open(file.path, O_RDWR | O_NONBLOCK)
            try #require(descriptor >= 0)
            let feeder = Task.detached {
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                try await Task.sleep(for: .milliseconds(50))
                try handle.write(contentsOf: Data(#"{"session_name":"fifo"}"#.utf8))
                try handle.close()
            }
            let result = await invoke(["convert", file.path, "--json"], in: root)
            try await feeder.value
            #expect(result.code == 1)
            #expect(result.error.joined().contains("document_type"), "\(result.error)")
        }
    }

    @Test(
        "invalid layouts are rejected before any workspace mutation",
        arguments: ["not-a-layout", "32d2,80x24,0,0{}", "b25d,80x24,0,0,0"])
    func invalidLayoutsBeforeMutation(layout: String) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let before = try await server.snapshot()
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let good = root.appendingPathComponent("first.json")
            let bad = root.appendingPathComponent("invalid.json")
            let marker = root.appendingPathComponent("before-script-ran")
            try JSONSerialization.data(withJSONObject: [
                "session_name": "first",
                "before_script": "/usr/bin/touch '\(marker.path)'",
                "windows": [["panes": [NSNull()]]],
            ]).write(to: good)
            try JSONSerialization.data(withJSONObject: [
                "session_name": "invalid",
                "windows": [["layout": layout, "panes": [NSNull(), NSNull()]]],
            ]).write(to: bad)
            let rejected = await invoke(
                ["load", good.path, bad.path, "-d", "-S", socket, "--json"],
                in: root, extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(rejected.code == 1)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            let running = try await server.isRunning()
            try #require(running, "Invalid layout terminated the existing tmux server.")
            let after = try await server.snapshot()
            #expect(after.serverProcessID == before.serverProcessID)
            #expect(after.sessions.map(\.id) == before.sessions.map(\.id))
            #expect(after.windows.map(\.id) == before.windows.map(\.id))
            #expect(after.panes.map(\.id) == before.panes.map(\.id))
        }
    }

    @Test("every load result names its input, index and whether the session was reused")
    func loadResultsCarryInputAndReuse() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let first = root.appendingPathComponent("one.json")
            let second = root.appendingPathComponent("two.json")
            try Data(#"{"session_name":"first","windows":[{"panes":[null]}]}"#.utf8).write(
                to: first)
            try Data(#"{"session_name":"second","windows":[{"panes":[null]}]}"#.utf8).write(
                to: second)
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            let created = await invoke(
                ["load", first.path, second.path, "-d", "-S", socket, "--json"], in: root,
                extra: environment)
            #expect(created.code == 0, "\(created.error)")
            let results = try #require(try created.json()["results"] as? [[String: Any]])
            #expect(results.count == 2)
            for (index, expected) in [(first, "first"), (second, "second")].enumerated() {
                let row = results[index]
                #expect(row["input"] as? String == expected.0.path)
                #expect(row["input_index"] as? Int == index)
                #expect(row["session_name"] as? String == expected.1)
                #expect((row["session_id"] as? String)?.isEmpty == false)
                #expect(row["reused"] as? Bool == false)
            }
            // Loading the same workspace again reuses its session.
            let reloaded = await invoke(
                ["load", first.path, "-d", "-S", socket, "--ndjson"], in: root, extra: environment)
            #expect(reloaded.code == 0, "\(reloaded.error)")
            let events = try reloaded.output.map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            let completedResults = try #require(
                (events.first { $0["event"] as? String == "completed" })?["results"]
                    as? [[String: Any]])
            #expect(completedResults.count == 1)
            #expect(completedResults[0]["input"] as? String == first.path)
            #expect(completedResults[0]["input_index"] as? Int == 0)
            #expect(completedResults[0]["reused"] as? Bool == true)
        }
    }

    @Test(
        "a before_script that cannot start is script_failed, not tmux_failed, with a results entry")
    func beforeScriptLaunchFailureIsScriptFailed() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            // A path that names no file at all, not a script that runs and
            // exits nonzero: the failure happens before the script starts.
            let missingScript = root.appendingPathComponent("does-not-exist")
            let file = root.appendingPathComponent("missing-script.json")
            try Data(
                Value.object([
                    "session_name": .string("missing-script"),
                    "before_script": .string(missingScript.path),
                    "windows": .array([.object(["panes": .array([.null])])]),
                ]).encoded().utf8
            ).write(to: file)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(result.code == 1)
            let diagnostic =
                try JSONSerialization.jsonObject(
                    with: Data(result.error.joined().utf8)) as? [String: Any]
            #expect(diagnostic?["code"] as? String == "script_failed", "\(result.error)")
            let envelope = try result.json()
            // No input completed, so this is a total failure, not partial,
            // despite results[] now naming the session that was rolled back.
            #expect(envelope["status"] as? String == "error")
            let errors = try #require(envelope["errors"] as? [[String: Any]])
            #expect(errors.first?["code"] as? String == "script_failed")
            let results = try #require(envelope["results"] as? [[String: Any]])
            try #require(results.count == 1, "\(envelope)")
            #expect(results[0]["input"] as? String == file.path)
            #expect(results[0]["input_index"] as? Int == 0)
            #expect((results[0]["session_id"] as? String)?.isEmpty == false)
            #expect(results[0]["session_name"] as? String == "missing-script")
            #expect(results[0]["reused"] as? Bool == false)
            #expect(try await !server.sessions().contains { $0.name == "missing-script" })
        }
    }

    @Test("before_script brackets its live output with script-started/-output/-completed events")
    func beforeScriptStreamsScriptEvents() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let script = root.appendingPathComponent("slow.sh")
            try Data(
                "#!/bin/sh\nprintf 'early\\n'\nsleep 2\nprintf 'late\\n'\n".utf8
            ).write(to: script)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path)
            let file = root.appendingPathComponent("stream.json")
            try Data(
                Value.object([
                    "session_name": .string("script-stream"),
                    "before_script": .string(script.path),
                    "windows": .array([.object(["panes": .array([.null])])]),
                ]).encoded().utf8
            ).write(to: file)
            let arrivals = Timestamps()
            let context = CLIContext(
                directory: root,
                environment: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable],
                output: { line in await arrivals.record(line) }, error: { _ in })
            let code = await WorkspaceCLI.run(
                ["load", file.path, "-d", "-S", socket, "--ndjson"], context: context)
            #expect(code == 0)
            let records = try await arrivals.rows.map {
                (
                    elapsed: $0.elapsed,
                    value: try JSONDecoder().decode(Value.self, from: Data($0.line.utf8))
                )
            }
            let started = try #require(
                records.first { $0.value["event"] == .string("script-started") })
            #expect(started.value["input_index"] == .integer(0))
            let early = try #require(
                records.first {
                    $0.value["event"] == .string("script-output")
                        && $0.value["text"]?.string?.contains("early") == true
                })
            // The reference proof: this line must arrive well before the
            // script's own 2-second sleep ends, not only once it exits.
            #expect(early.elapsed < .seconds(1.5), "\(early.elapsed)")
            #expect(early.value["input_index"] == .integer(0))
            #expect(early.value["stream"] == .string("stdout"))
            let late = try #require(
                records.first {
                    $0.value["event"] == .string("script-output")
                        && $0.value["text"]?.string?.contains("late") == true
                })
            #expect(late.elapsed > early.elapsed + .seconds(1))
            let completed = try #require(
                records.first { $0.value["event"] == .string("script-completed") })
            #expect(completed.value["input_index"] == .integer(0))
            #expect(completed.value["child_status"] == .integer(0))
            #expect(completed.elapsed > late.elapsed)
        }
    }

    @Test("load failures report retained sessions and roll back only the failed workspace")
    func partialLoad() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let good = root.appendingPathComponent("first.json")
            let bad = root.appendingPathComponent("second.json")
            try Data(#"{"session_name":"first","windows":[{"panes":[null]}]}"#.utf8).write(to: good)
            try Data(
                #"{"session_name":"second","windows":[{"options":{"libtmux-invalid-option":"1"},"panes":[null]}]}"#
                    .utf8
            ).write(to: bad)
            let failed = await invoke(
                ["load", good.path, bad.path, "-s", "renamed", "-d", "-S", socket, "--json"],
                in: root, extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(failed.code == 1)
            let sessions = try await server.sessions().map(\.name)
            #expect(sessions.contains("first"))
            #expect(!sessions.contains("renamed"))
            let result = try failed.json()
            #expect(result["status"] as? String == "partial")
            #expect((result["results"] as? [Any])?.count == 1)
            let errors = try #require(result["errors"] as? [[String: Any]])
            #expect(errors.count == 1)
            #expect(errors[0]["input_index"] as? Int == 1)
            #expect(!(errors[0]["code"] as? String ?? "").isEmpty)
        }
    }

    @Test("append preserves the borrowed session and reports failed windows")
    func appendWorkspace() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let initial = try await server.snapshot()
            let pane = try #require(initial.panes.first)
            let session = try #require(initial.sessions.first)
            let file = root.appendingPathComponent("append.json")
            try Data(
                #"{"session_name":"unused","environment":{"APPEND_VALUE":"literal;#{session_name}"},"windows":[{"window_name":"added","panes":[null]}]}"#
                    .utf8
            ).write(to: file)
            let environment = [
                "LIBTMUX_TMUX_BIN": server.tmuxExecutable,
                "TMUX": "\(socket),\(initial.serverProcessID),999",
                "TMUX_PANE": pane.id.rawValue,
            ]
            let loaded = await invoke(
                ["load", file.path, "-a", "--json"], in: root, extra: environment)
            #expect(loaded.code == 0, "\(loaded.error)")
            let after = try await server.snapshot()
            #expect(after.sessions.map(\.id) == initial.sessions.map(\.id))
            #expect(after.windows.count == initial.windows.count + 1)
            #expect(
                try await server.environmentValue("APPEND_VALUE", in: .session(session.id.rawValue))
                    == "literal;#{session_name}")
            let bad = root.appendingPathComponent("bad.json")
            try Data(
                #"{"session_name":"unused","windows":[{"window_name":"retained","options":{"libtmux-invalid-option":"1"},"panes":[null]}]}"#
                    .utf8
            ).write(to: bad)
            let failed = await invoke(
                ["load", bad.path, "--append", "--json"], in: root, extra: environment)
            #expect(failed.code == 1)
            let result = try failed.json()
            #expect(result["status"] as? String == "partial")
            let retained = try #require(result["retained_state"] as? [String: Any])
            #expect(retained["session_id"] as? String == session.id.rawValue)
            #expect((retained["window_ids"] as? [String])?.count == 1)
            let final = try await server.snapshot()
            #expect(final.sessions.map(\.id) == initial.sessions.map(\.id))
            #expect(final.windows.count == after.windows.count + 1)
            let stream = await invoke(
                ["load", bad.path, "--append", "--ndjson"], in: root, extra: environment)
            #expect(stream.code == 1)
            let records = try stream.output.map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            #expect(records.last?["event"] as? String == "failed")
            #expect(
                records.filter { ["completed", "failed"].contains($0["event"] as? String ?? "") }
                    .count == 1)
            // Event fields sit at the top level of the record now, not
            // nested under a `data` key.
            #expect(records.last?["status"] as? String == "partial")
            let detached = await invoke(
                ["load", file.path, "--append", "-d", "--json"], in: root, extra: environment)
            #expect(detached.code == 0, "\(detached.error)")
            #expect(try await server.sessions().contains { $0.name == "unused" })
        }
    }

    @Test("append rejects foreign and stale inherited endpoints before mutation")
    func appendIdentity() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let snapshot = try await server.snapshot()
            let pane = try #require(snapshot.panes.first)
            let file = root.appendingPathComponent("append.json")
            try Data(#"{"session_name":"unused","windows":[{"panes":[null]}]}"#.utf8).write(
                to: file)
            let alias = root.appendingPathComponent("socket,alias")
            try FileManager.default.createSymbolicLink(
                atPath: alias.path, withDestinationPath: socket)
            let environment = [
                "LIBTMUX_TMUX_BIN": server.tmuxExecutable,
                "TMUX": "\(alias.path),\(snapshot.serverProcessID),999",
                "TMUX_PANE": pane.id.rawValue,
            ]
            let accepted = await invoke(
                ["load", file.path, "--append", "-S", socket, "--json"], in: root,
                extra: environment)
            #expect(accepted.code == 0, "\(accepted.error)")
            let count = try await server.snapshot().windows.count
            let stale = environment.merging(["TMUX": "\(socket),1,0"]) { _, new in new }
            let rejected = await invoke(
                ["load", file.path, "--append", "--json"], in: root, extra: stale)
            #expect(rejected.code == 1)
            #expect(rejected.error.joined().contains("append_context"))
            #expect(try await server.snapshot().windows.count == count)
            try await withTmuxServer { other in
                guard case let .socketPath(otherSocket) = other.endpoint else { return }
                let before = try await other.snapshot().windows.count
                let foreign = await invoke(
                    ["load", file.path, "--append", "-S", otherSocket, "--json"], in: root,
                    extra: environment)
                #expect(foreign.code == 1)
                #expect(foreign.error.joined().contains("append_context"))
                #expect(try await other.snapshot().windows.count == before)
            }
            let coldSocket = root.appendingPathComponent("unstarted").path
            let cold = await invoke(
                ["load", file.path, "--append", "-S", coldSocket, "--json"], in: root,
                extra: environment)
            #expect(cold.code == 1)
            #expect(!FileManager.default.fileExists(atPath: coldSocket))
            _ = try await server.run(TmuxCommand("kill-server"))
            try #require(await waitForSocketClosure(socket))
            let replacement = try await server.newSession(named: "replacement")
            let recycled = try await server.snapshot()
            #expect(recycled.panes.first?.id == pane.id)
            let restarted = await invoke(
                ["load", file.path, "--append", "-S", socket, "--json"], in: root,
                extra: environment)
            #expect(restarted.code == 1)
            #expect(restarted.error.joined().contains("append_context"))
            #expect(try await server.snapshot().windows.count == 1)
            let old = try #require(snapshot.sessions.first)
            await #expect(throws: TmuxError.serverRestarted) {
                _ = try await server.setEnvironment("UNCHANGED", to: "bad", in: old)
            }
            #expect(
                try await server.environmentValue(
                    "UNCHANGED", in: .session(replacement.id.rawValue)) == nil)
        }
    }

    @Test("native load and capture use an explicit socket")
    func loadAndCapture() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("work.json")
            try Data(
                #"{"session_name":"native-cli","windows":[{"window_name":"editor","panes":[null,null]},{"window_name":"shell","panes":[null]}]}"#
                    .utf8
            ).write(to: file)
            let loaded = await invoke(
                ["--json", "load", file.path, "-d", "-S", socket, "--ndjson"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(loaded.code == 0)
            let events = try loaded.output.map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            #expect(events.first?["event"] as? String == "started")
            #expect(events.last?["event"] as? String == "completed")
            #expect(events.filter { $0["event"] as? String == "completed" }.count == 1)
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "native-cli" })
            #expect(snapshot.windows(of: session).map(\.paneCount) == [2, 1])
            let captured = await invoke(
                ["freeze", "native-cli", "-S", socket, "--json"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(captured.code == 0)
            #expect(try captured.json()["session_name"] as? String == "native-cli")
            #expect((try captured.json()["windows"] as? [Any])?.count == 2)
            #expect(!captured.error.isEmpty)
            let streamed = await invoke(
                ["freeze", "native-cli", "-S", socket, "--ndjson"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(
                (try streamed.json()["workspace"] as? [String: Any])?["session_name"] as? String
                    == "native-cli")
        }
    }

    @Test("duplicate indexes and conflicting focus fail before endpoint lookup")
    func focusPreflight() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("focus.json")
            for windows in [
                #"[{"window_index":2,"panes":[null]},{"window_index":2,"panes":[null]}]"#,
                #"[{"focus":true,"panes":[null]},{"focus":true,"panes":[null]}]"#,
                #"[{"panes":[{"focus":true},{"focus":true}]}]"#,
                #"[{"window_index":-1,"panes":[null]}]"#,
                #"[{"focus":1,"panes":[null]}]"#,
            ] {
                try Data("{\"session_name\":\"preflight\",\"windows\":\(windows)}".utf8).write(
                    to: file)
                let result = await invoke(
                    ["load", file.path, "-d", "-S", "unavailable", "--json"], in: root)
                #expect(result.code == 1)
                #expect(
                    result.error.joined().contains(#""code":"invalid_workspace""#),
                    "\(result.error)")
            }
        }
    }

    @Test("focus accepts the quoted strings tmuxp freeze writes")
    func focusAcceptsQuotedBoolean() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("focus-quoted.json")
            for windows in [
                #"[{"focus":"true","panes":[{"focus":"false"}]}]"#,
                #"[{"panes":[{"focus":"true"}]}]"#,
            ] {
                try Data("{\"session_name\":\"quoted\",\"windows\":\(windows)}".utf8)
                    .write(to: file)
                let result = await invoke(
                    ["load", file.path, "-d", "-S", "unavailable", "--json"], in: root)
                // The document must clear validation; what stops the load next is
                // the unreachable backend, never the boolean parse.
                #expect(
                    !result.error.joined().contains("must be a boolean"), "\(result.error)")
                #expect(
                    !result.error.joined().contains(#""code":"invalid_workspace""#),
                    "\(result.error)")
            }
            let invalid = root.appendingPathComponent("focus-invalid.json")
            try Data(
                #"{"session_name":"invalid","windows":[{"panes":[{"focus":"maybe"}]}]}"#.utf8
            ).write(to: invalid)
            let result = await invoke(
                ["load", invalid.path, "-d", "-S", "unavailable", "--json"], in: root)
            #expect(result.code == 1)
            #expect(result.error.joined().contains("must be a boolean"), "\(result.error)")
        }
    }

    @Test("tmux failures read as plain sentences, not Swift enum literals")
    func tmuxFailuresReadAsSentences() async throws {
        try await withFiles { root in
            // No live server needed: an invalid layout fails before any
            // daemon probe, and LIBTMUX_TMUX_BIN defaults to a missing binary.
            let badLayout = root.appendingPathComponent("bad-layout.json")
            try Data(
                #"""
                {"session_name":"bad-layout","windows":[{"layout":"not-a-real-layout-string","panes":[null,null]}]}
                """#.utf8
            ).write(to: badLayout)
            let layoutResult = await invoke(
                ["load", badLayout.path, "-d", "-S", "nonexistent"], in: root)
            #expect(layoutResult.code == 1)
            #expect(
                !layoutResult.error.joined().contains("invocationFailed(reason"),
                "\(layoutResult.error)")
            #expect(
                layoutResult.error.joined().contains("Invalid window layout"),
                "\(layoutResult.error)")

            let plain = root.appendingPathComponent("plain.json")
            try Data(#"{"session_name":"plain","windows":[{"panes":[null]}]}"#.utf8).write(
                to: plain)
            let launchResult = await invoke(
                ["load", plain.path, "-d", "-S", "nonexistent"], in: root)
            #expect(launchResult.code == 1)
            #expect(
                !launchResult.error.joined().contains("processLaunchFailed(reason"),
                "\(launchResult.error)")
            #expect(
                !launchResult.error.joined().contains("LibTmux.TmuxError"),
                "\(launchResult.error)")
        }
    }

    @Test("the error-to-sentence mapping covers every builder and tmux failure")
    func errorMessageMapping() {
        // Most of these cases are impractical to force through the CLI
        // deterministically; tmuxFailuresReadAsSentences covers the two that are.
        let wrapped = WorkspaceCLI.message(
            for: WorkspaceBuilderError.tmux(
                .invocationFailed(reason: "size or position no space for a new pane")))
        #expect(wrapped == "size or position no space for a new pane")
        #expect(!wrapped.contains("tmux("))
        #expect(!wrapped.contains("LibTmux"))

        let rollback = WorkspaceCLI.message(
            for: WorkspaceBuilderError.rollbackFailed(
                original: .sessionVanished("gone"),
                cleanup: .invocationFailed(reason: "cannot kill session")))
        #expect(!rollback.contains("rollbackFailed("))
        #expect(rollback.contains("gone"))
        #expect(rollback.contains("cannot kill session"))

        #expect(!WorkspaceCLI.message(for: WorkspaceBuilderError.noWindows).contains("noWindows"))
        #expect(
            !WorkspaceCLI.message(for: WorkspaceBuilderError.sessionExists("dup"))
                .contains("sessionExists("))
        #expect(
            WorkspaceCLI.message(
                for: TmuxError.commandFailed(
                    command: "split-window", exitCode: 1, reason: "no space")
            )
            .contains("no space"))
    }

    @Test(
        "a common shell is recognised regardless of default-shell, with or without the login-shell dash",
        arguments: [
            ("bash", nil, true), ("-bash", nil, true), ("zsh", nil, true), ("-zsh", nil, true),
            ("sh", nil, true), ("fish", nil, true), ("python3", nil, false),
            ("-python3", nil, false), ("vim", nil, false),
            // A common name wins even over a mismatched default-shell --
            // macOS's own /bin/sh is bash, not the "sh" it resolves to.
            ("bash", "sh", true), ("bash", "zsh", true),
        ])
    func defaultShellCommandRecognisesCommonNames(
        command: String, defaultShell: String?, expected: Bool
    ) {
        #expect(
            WorkspaceCommands.isDefaultShellCommand(command, defaultShell: defaultShell)
                == expected, "\(command) / \(defaultShell ?? "nil")")
    }

    @Test(
        "an exotic default-shell is still recognised by its own resolved basename",
        arguments: [
            ("mycustomshell", "/opt/exotic/mycustomshell", true),
            ("-mycustomshell", "/opt/exotic/mycustomshell", true),
            ("mycustomshell", nil, false),
            ("mycustomshell", "/opt/exotic/othershell", false),
        ])
    func defaultShellCommandFallsBackToResolvedBasename(
        command: String, defaultShell: String?, expected: Bool
    ) {
        // A live pane can't reach this path through the test fixture, so
        // the pure function is tested directly.
        #expect(
            WorkspaceCommands.isDefaultShellCommand(command, defaultShell: defaultShell)
                == expected, "\(command) / \(defaultShell ?? "nil")")
    }

    @Test("freeze selects explicit, pane-context and sole sessions without guessing")
    func freezeSessionSelection() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            var environment = [
                "LIBTMUX_TMUX_BIN": server.tmuxExecutable, "TMUX": "", "TMUX_PANE": "",
            ]
            let sole = await invoke(
                ["freeze", "-S", socket, "--json"], in: root, extra: environment)
            #expect(sole.code == 0, "\(sole.error)")
            #expect(try sole.json()["session_name"] as? String == "bootstrap")
            let other = try await server.newSession(named: "other")
            let snapshot = try await server.snapshot()
            let pane = try #require(snapshot.panes(of: other).first)
            let ambiguous = await invoke(
                ["freeze", "-S", socket, "--json"], in: root, extra: environment)
            #expect(ambiguous.code == 2)
            #expect(ambiguous.output.isEmpty)
            #expect(ambiguous.error.joined().contains("session_required"))
            let selected = await invoke(
                ["freeze", "-S", socket, "-f", "json"], in: root, extra: environment,
                responses: [String(Int.min), "invalid", "2"])
            #expect(selected.code == 0)
            #expect(try selected.json()["session_name"] as? String == "other")
            let cancelled = await invoke(
                ["freeze", "-S", socket], in: root, extra: environment, responses: ["q"])
            #expect(cancelled.code == 130)
            #expect(cancelled.output.isEmpty)
            environment["TMUX"] = "\(socket),\(snapshot.serverProcessID),999"
            environment["TMUX_PANE"] = pane.id.rawValue
            let current = await invoke(["freeze", "--json"], in: root, extra: environment)
            #expect(current.code == 0, "\(current.error)")
            #expect(try current.json()["session_name"] as? String == "other")
            environment["TMUX"] = "\(socket),1,999"
            let stale = await invoke(["freeze", "--json"], in: root, extra: environment)
            #expect(stale.code == 1)
            #expect(stale.output.isEmpty)
            #expect(stale.error.joined().contains("freeze_context"))
            let explicit = await invoke(
                ["freeze", "bootstrap", "-S", socket, "--json"], in: root, extra: environment)
            #expect(explicit.code == 0)
            #expect(try explicit.json()["session_name"] as? String == "bootstrap")
        }
    }

    @Test("load fits five or more panes in a window with no explicit layout")
    func manyPanesFitWithoutExplicitLayout() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("many-panes.json")
            // No layout key, default detached 80x24: runs out of room by
            // the fifth pane without an interim rebalance between splits.
            try Data(
                Value.object([
                    "session_name": .string("many-panes"),
                    "windows": .array([
                        .object(["panes": .array(Array(repeating: .string("true"), count: 12))])
                    ]),
                ]).encoded().utf8
            ).write(to: file)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(result.code == 0, "\(result.error)")
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "many-panes" })
            let window = try #require(snapshot.windows(of: session).first)
            #expect(snapshot.panes(of: window).count == 12)
        }
    }

    @Test("an explicit layout still wins once the many-pane interim rebalance is done")
    func explicitLayoutSurvivesManyPaneRebalance() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("layout-panes.json")
            try Data(
                Value.object([
                    "session_name": .string("layout-panes"),
                    "windows": .array([
                        .object([
                            "layout": .string("even-vertical"),
                            "panes": .array(Array(repeating: .string("true"), count: 5)),
                        ])
                    ]),
                ]).encoded().utf8
            ).write(to: file)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(result.code == 0, "\(result.error)")
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "layout-panes" })
            let window = try #require(snapshot.windows(of: session).first)
            let panes = snapshot.panes(of: window)
            #expect(panes.count == 5)
            // even-vertical is one column, so every pane is at the left
            // edge; the interim tiled rebalance would not leave it so.
            #expect(panes.allSatisfy { $0.isAtLeft }, "\(panes)")
        }
    }

    @Test("load applies global_options with set-option -g")
    func globalOptionsApply() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("global-options.json")
            // cxx, dotnet, go, java, ts and tmuxp all accept this key; swift
            // and rs refused it outright.
            try Data(
                #"""
                {"session_name":"global-options","global_options":{"status":false},"windows":[{"panes":[null]}]}
                """#.utf8
            ).write(to: file)
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            let loaded = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root, extra: environment)
            #expect(loaded.code == 0, "\(loaded.error)")
            #expect(try await server.option("status", scope: .globalSession) == "off")
        }
    }

    @Test("load applies window options_after once every pane in the window exists")
    func windowOptionsAfterAppliesPostPane() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("options-after.json")
            // java and rs freeze window options under this key; the loader
            // now accepts it instead of refusing the window outright.
            try Data(
                #"""
                {"session_name":"options-after","windows":[{"window_name":"one","options_after":{"automatic-rename":"off"},"panes":["true","true","true"]}]}
                """#.utf8
            ).write(to: file)
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            let loaded = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root, extra: environment)
            #expect(loaded.code == 0, "\(loaded.error)")
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "options-after" })
            let window = try #require(snapshot.windows(of: session).first)
            #expect(snapshot.panes(of: window).count == 3)
            #expect(try await server.option("automatic-rename", scope: .window(window)) == "off")
        }
    }

    @Test(
        "freeze and reload preserve local options as options_after, without leaking environment or a default shell"
    )
    func freezeSettingsRoundTrip() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first)
            let window = try #require(snapshot.windows(of: session).first)
            let sessionValue = "session 'quoted' \\ λ\nnext"
            let windowValue = "window \"quoted\" #{session_name}\nlast"
            try await server.setOption(
                "@freeze-session", to: sessionValue, scope: .session(session))
            // A value the listing prints as it is stored takes the short path
            // through capture; a quoted or escaped one takes the second read.
            try await server.setOption("@freeze-plain", to: "plain/value", scope: .session(session))
            try await server.setOption("@freeze-window", to: windowValue, scope: .window(window))
            // freeze omits the top-level environment block entirely now,
            // rather than only filtering ambient SSH/display values out of
            // it.
            try await server.setEnvironment(
                "FREEZE_VALUE", to: "should not be captured", in: .session(session.id.rawValue))
            // Mismatched on purpose: the omission below must not depend on
            // this matching what the pane is actually running.
            try await server.setOption(
                "default-shell", to: "/completely/different/not-the-pane-shell",
                scope: .session(session))
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            let captured = await invoke(
                ["freeze", "bootstrap", "-S", socket, "--json"], in: root, extra: environment)
            #expect(captured.code == 0, "\(captured.error)")
            let document = try captured.json()
            #expect((document["options"] as? [String: String])?["@freeze-session"] == sessionValue)
            #expect((document["options"] as? [String: String])?["@freeze-plain"] == "plain/value")
            #expect(document["environment"] == nil, "\(document)")
            let windows = try #require(document["windows"] as? [[String: Any]])
            #expect(windows[0]["options"] == nil, "\(windows[0])")
            #expect(
                (windows[0]["options_after"] as? [String: String])?["@freeze-window"]
                    == windowValue)
            let panes = try #require(windows[0]["panes"] as? [[String: Any]])
            // The lone pane runs a plain shell, so shell_command is omitted.
            #expect(panes[0]["shell_command"] == nil, "\(panes[0])")
            let quiet = await invoke(
                ["freeze", "bootstrap", "-S", socket, "--json", "-q"], in: root, extra: environment)
            #expect(quiet.code == 0)
            #expect(quiet.error.isEmpty)
            #expect(try quiet.json()["session_name"] as? String == "bootstrap")
            let saved = root.appendingPathComponent("captured.json")
            try Data(captured.output.joined().utf8).write(to: saved)
            let loaded = await invoke(
                ["load", saved.path, "-s", "replayed-settings", "-d", "-S", socket, "--json"],
                in: root, extra: environment)
            #expect(loaded.code == 0, "\(loaded.error)")
            let after = try await server.snapshot()
            let replayed = try #require(after.sessions.first { $0.name == "replayed-settings" })
            let replayedWindow = try #require(after.windows(of: replayed).first)
            #expect(
                try await server.option("@freeze-session", scope: .session(replayed))
                    == sessionValue)
            #expect(
                try await server.option("@freeze-window", scope: .window(replayedWindow))
                    == windowValue)
        }
    }

    @Test(
        "freeze infers JSON destinations and preserves explicit format choices",
        arguments: ["--json", "--ndjson"])
    func freezeSaveFormat(mode: String) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            for (name, flags) in [
                ("inferred.JsOn", [String]()), ("explicit.yaml", ["-f", "json"]),
            ] {
                let file = root.appendingPathComponent(name)
                let arguments =
                    ["freeze", "bootstrap", "-S", socket, mode, "-q", "--save-to", file.path]
                    + flags
                let saved = await invoke(arguments, in: root, extra: environment)
                #expect(saved.code == 0, "\(saved.error)")
                #expect(saved.error.isEmpty)
                let result = try saved.json()
                #expect(result["path"] as? String == file.path)
                #expect(
                    (result["workspace"] as? [String: Any])?["session_name"] as? String
                        == "bootstrap")
                let original = try Data(contentsOf: file)
                let document = try JSONSerialization.jsonObject(with: original) as? [String: Any]
                #expect(document?["session_name"] as? String == "bootstrap")
                let protected = await invoke(arguments, in: root, extra: environment)
                #expect(protected.code == 1)
                #expect(protected.output.isEmpty)
                #expect(try Data(contentsOf: file) == original)
            }
            #if YAMLWorkspaces
                let file = root.appendingPathComponent("inferred.JsOn")
                let overridden = await invoke(
                    [
                        "freeze", "bootstrap", "-S", socket, mode, "-q", "--save-to", file.path,
                        "--force", "-f", "yaml",
                    ], in: root, extra: environment)
                #expect(overridden.code == 0, "\(overridden.error)")
                #expect(overridden.error.isEmpty)
                #expect(
                    (try overridden.json()["workspace"] as? [String: Any])?["session_name"]
                        as? String == "bootstrap")
                let yaml = try Data(contentsOf: file)
                #expect((try? JSONSerialization.jsonObject(with: yaml)) == nil)
                let readable = root.appendingPathComponent("overridden.yaml")
                try yaml.write(to: readable)
                let converted = await invoke(["convert", readable.path, "--json"], in: root)
                #expect(converted.code == 0)
                #expect(try converted.json()["session_name"] as? String == "bootstrap")
            #endif
            let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!contents.contains { $0.hasPrefix(".workspace-") })
        }
    }

    @Test("load and capture preserve explicit indexes and window/pane focus")
    func focusAndIndexes() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("focus.json")
            try Data(
                #"{"session_name":"focused","windows":[{"window_name":"one","window_index":3,"panes":[null]},{"window_name":"two","window_index":7,"focus":true,"panes":[{"focus":true},null]}]}"#
                    .utf8
            ).write(to: file)
            let environment = ["LIBTMUX_TMUX_BIN": server.tmuxExecutable]
            let loaded = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root, extra: environment)
            #expect(loaded.code == 0, "\(loaded.error)")
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "focused" })
            let links = snapshot.windowLinks(of: session)
            #expect(links.map(\.index) == [3, 7])
            #expect(links.filter(\.isActive).map(\.index) == [7])
            let focused = try #require(snapshot.windows.first { $0.id == links.last?.windowID })
            #expect(snapshot.panes(of: focused).filter(\.isActive).map(\.index) == [0])
            let capture = await invoke(
                ["freeze", "focused", "-S", socket, "--json"], in: root, extra: environment)
            #expect(capture.code == 0)
            let windows = try #require(try capture.json()["windows"] as? [[String: Any]])
            #expect(windows.compactMap { $0["window_index"] as? Int } == [3, 7])
            #expect(windows.compactMap { $0["focus"] as? Bool } == [false, true])
            let panes = try #require(windows.last?["panes"] as? [[String: Any]])
            #expect(panes.compactMap { $0["focus"] as? Bool } == [true, false])
            let saved = root.appendingPathComponent("captured.json")
            try Data(capture.output.joined().utf8).write(to: saved)
            let replay = await invoke(
                ["load", saved.path, "-s", "replayed", "-d", "-S", socket, "--json"], in: root,
                extra: environment)
            #expect(replay.code == 0, "\(replay.error)")
            let after = try await server.snapshot()
            let restored = try #require(after.sessions.first { $0.name == "replayed" })
            #expect(after.windowLinks(of: restored).map(\.index) == [3, 7])
            #expect(after.windowLinks(of: restored).filter(\.isActive).map(\.index) == [7])
        }
    }

    @Test("native configuration reaches the first pane and rolls back failed bootstrap")
    func loadConfiguration() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let configs = root.appendingPathComponent("configs")
            let work = root.appendingPathComponent("work")
            let physicalWork = root.appendingPathComponent("physical-work")
            try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(
                at: physicalWork, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: work, withDestinationURL: physicalWork)
            let script = root.appendingPathComponent("bootstrap")
            try Data(
                "#!/bin/sh\n\"$TMUX_BIN\" -S \"$SOCKET\" has-session -t '=configured' || exit 9\npwd > \"$MARKER\"\n"
                    .utf8
            ).write(to: script)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: script.path)
            let file = configs.appendingPathComponent("work.json")
            let value = Value.object([
                "session_name": .string("configured"), "start_directory": .string("../work"),
                "before_script": .string(script.path),
                "environment": .object(["WORKSPACE_TOKEN": .string("native value")]),
                "options": .object(["@session-option": .integer(17)]),
                "window_options": .object(["@window-option": .string("inherited")]),
                "windows": .array([
                    .object([
                        "options": .object(["@window-option": .string("local")]),
                        "panes": .array([
                            .string("printf '%s' \"$WORKSPACE_TOKEN\" > token"), .null,
                        ]),
                    ])
                ]),
            ])
            try Data(value.encoded().utf8).write(to: file)
            let marker = root.appendingPathComponent("bootstrap-cwd")
            let loaded = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root,
                extra: [
                    "LIBTMUX_TMUX_BIN": server.tmuxExecutable, "TMUX_BIN": server.tmuxExecutable,
                    "SOCKET": socket, "MARKER": marker.path,
                ])
            #expect(loaded.code == 0, "\(loaded.error)")
            guard loaded.code == 0 else { return }
            let configuredDirectory = try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .newlines)
            #expect(
                URL(fileURLWithPath: configuredDirectory).resolvingSymlinksInPath().path
                    == work.resolvingSymlinksInPath().path)
            let snapshot = try await server.snapshot()
            let session = try #require(snapshot.sessions.first { $0.name == "configured" })
            let window = try #require(snapshot.windows(of: session).first)
            #expect(try await server.option("@session-option", scope: .session(session)) == "17")
            #expect(try await server.option("@window-option", scope: .window(window)) == "local")
            let token = work.appendingPathComponent("token")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: token.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(try String(contentsOf: token, encoding: .utf8) == "native value")
            var failed = try #require(value.object)
            failed["session_name"] = .string("invocation-cwd")
            failed.removeValue(forKey: "start_directory")
            try Data(Value.object(failed).encoded().utf8).write(to: file)
            let inherited = await invoke(
                ["load", file.path, "-d", "-S", socket, "--json"], in: root,
                extra: [
                    "LIBTMUX_TMUX_BIN": server.tmuxExecutable, "TMUX_BIN": server.tmuxExecutable,
                    "SOCKET": socket, "MARKER": marker.path,
                ])
            #expect(inherited.code == 0)
            let inheritedDirectory = try String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .newlines)
            #expect(
                URL(fileURLWithPath: inheritedDirectory).resolvingSymlinksInPath().path
                    == root.resolvingSymlinksInPath().path)
            failed["session_name"] = .string("failed-bootstrap")
            failed["before_script"] = .string("/bin/false")
            try Data(Value.object(failed).encoded().utf8).write(to: file)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "--ndjson"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(result.code == 1)
            #expect(try await !server.sessions().contains { $0.name == "failed-bootstrap" })
            #expect(try await server.sessions().contains { $0.id == session.id })
        }
    }

    @Test("configuration preflight rejects unsafe fields before any input loads")
    func configurationPreflight() async throws {
        try await withFiles { root in
            let first = root.appendingPathComponent("first.json")
            let second = root.appendingPathComponent("second.json")
            let base: [String: Value] = [
                "session_name": .string("preflight"),
                "windows": .array([.object(["panes": .array([.null])])]),
            ]
            try Data(Value.object(base).encoded().utf8).write(to: first)
            for (key, value) in [
                ("options", Value.object(["-g": .string("on")])),
                ("before_script", Value.string("/bin/true\0")),
                ("environment", Value.object(["INVALID=NAME": .string("value")])),
            ] {
                var invalid = base
                invalid[key] = value
                try Data(Value.object(invalid).encoded().utf8).write(to: second)
                let result = await invoke(
                    ["load", first.path, second.path, "-d", "--json"], in: root)
                #expect(result.code == 1)
                #expect(result.error.joined().contains("invalid_workspace"))
                #expect(result.output.isEmpty)
            }
        }
    }

    @Test("load starts an absent server with its requested color mode", arguments: [false, true])
    func coldLoad(_ colors256: Bool) async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            _ = try await server.run(TmuxCommand("kill-server"))
            try #require(await waitForSocketClosure(socket))
            #expect(try await !server.isRunning())
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("cold.json")
            try Data(#"{"session_name":"cold","windows":[{"panes":[null]}]}"#.utf8).write(to: file)
            let wrapper = root.appendingPathComponent("tmux-wrapper")
            let recorded = root.appendingPathComponent("prefixes")
            let quote = { (value: String) in
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            try Data(
                ("#!/bin/sh\nif [ \"$1\" = -u ]; then printf '%s|%s|%s|%s|%s\\n' \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" >> "
                    + quote(recorded.path) + "; fi\nexec " + quote(server.tmuxExecutable)
                    + " \"$@\"\n").utf8
            ).write(to: wrapper)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "-f", "/dev/null", "--json"]
                    + (colors256 ? ["-2"] : []), in: root,
                extra: ["LIBTMUX_TMUX_BIN": wrapper.path])
            try #require(result.code == 0, "\(result.error)")
            let sessions = try await server.sessions()
            #expect(sessions.map(\.name) == ["cold"])
            let configured = Server(
                endpoint: server.endpoint, tmuxExecutable: wrapper.path,
                configurationFile: "/dev/null", force256Colors: colors256)
            let connectedNames = try await configured.using(.connected(to: "cold")) { connected in
                try await connected.sessions().map(\.name)
            }
            #expect(connectedNames == ["cold"])
            let prefixes = try String(contentsOf: recorded, encoding: .utf8).split(separator: "\n")
            #expect(!prefixes.isEmpty)
            let expected = colors256 ? "-u|-2|-f|/dev/null|" : "-u|-f|/dev/null|"
            #expect(prefixes.allSatisfy { $0.hasPrefix(expected) })
            #expect(prefixes.contains { $0.contains("|-C") })
            #expect(prefixes.contains { $0.contains("|-S") })
        }
    }

    private func invoke(
        _ args: [String], in root: URL, extra: [String: String] = [:], responses: [String]? = nil
    ) async
        -> Outcome
    {
        let output = Lines()
        let error = Lines()
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["TMUXP_CONFIGDIR"] = root.path
        environment["LIBTMUX_TMUX_BIN"] = "/unavailable-tmux"
        environment.merge(extra) { _, right in right }
        var context = CLIContext(
            directory: root, environment: environment, output: { await output.append($0) },
            error: { await error.append($0) })
        if let responses {
            let input = Responses(responses)
            context.terminal = true
            context.input = { await input.next() }
        }
        let code = await WorkspaceCLI.run(args, context: context)
        return await Outcome(code: code, output: output.values, error: error.values)
    }

    @Test("an interrupt cancels the work task whether it arrives before or after it")
    func interruptsReachTheWorkTask() async {
        for beforeTheTask in [true, false] {
            let relay = InterruptRelay()
            if beforeTheTask { relay.cancel() }
            let task = Task { () -> Int32 in
                await Task.yield()
                return 0
            }
            relay.adopt(task)
            if !beforeTheTask { relay.cancel() }
            #expect(task.isCancelled)
            _ = await task.value
        }
    }

    private func withFiles(_ body: (URL) async throws -> Void) async throws {
        let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test").appendingPathComponent(
            "cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }
}

private actor Lines {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

/// Each line's arrival time relative to when this actor was created, so a
/// test can tell a line that streamed in while a child ran from one that
/// only appeared once the whole command finished.
private actor Timestamps {
    private let start = ContinuousClock.now
    var rows: [(elapsed: Duration, line: String)] = []
    func record(_ line: String) { rows.append((start.duration(to: .now), line)) }
}

private actor Responses {
    var values: [String]
    init(_ values: [String]) { self.values = values }
    func next() -> String? { values.isEmpty ? nil : values.removeFirst() }
}

private struct Outcome: Sendable {
    let code: Int32
    let output: [String]
    let error: [String]

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(output.joined().utf8)) as? [String: Any] ?? [:]
    }
}
