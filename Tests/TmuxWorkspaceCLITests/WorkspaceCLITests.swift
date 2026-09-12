import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import TmuxWorkspaceCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("workspace CLI", .serialized, .timeLimit(.minutes(1)))
struct WorkspaceCLITests {
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

    @Test("diagnostic levels filter warnings without hiding results or failures")
    func diagnosticLevels() async throws {
        try await withFiles { root in
            let file = root.appendingPathComponent("import.json")
            try Data(#"{"name":"levels","windows":[],"untranslated":true}"#.utf8).write(to: file)
            for level in ["debug", "info", "warning", "error", "critical"] {
                let arguments = ["import", "tmuxinator", file.path, "--json"]
                for flags in [
                    ["--log-level", level] + arguments, arguments + ["--log-level", level],
                ] {
                    let result = await invoke(flags, in: root)
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
                #"{"name":"imported","root":"/tmp","tmux_options":"-f /tmp/a-file.conf","windows":[{"editor":{"layout":"tiled","panes":["one","two"]}}]}"#
                    .utf8
            ).write(to: tmuxinator)
            let imported = await invoke(
                ["--json", "import", "tmuxinator", "work"], in: root,
                extra: ["TMUXINATOR_CONFIG": source.path])
            #expect(imported.code == 0, "\(imported.error)")
            let document = try imported.json()
            #expect(document["session_name"] as? String == "imported")
            #expect(document["config"] as? String == "/tmp/a-file.conf")
            let windows = try #require(document["windows"] as? [[String: Any]])
            #expect((windows[0]["panes"] as? [String]) == ["one", "two"])
            let teamocil = root.appendingPathComponent("team.json")
            try Data(
                #"{"session":{"name":"team","windows":[{"name":"shell","splits":[{"cmd":"echo imported"}]}]}}"#
                    .utf8
            ).write(to: teamocil)
            let streamed = await invoke(
                ["import", "teamocil", teamocil.path, "--ndjson"], in: root)
            #expect(streamed.code == 0)
            let envelope = try streamed.json()
            #expect(envelope["schema_version"] as? Int == 1)
            #expect((envelope["workspace"] as? [String: Any])?["session_name"] as? String == "team")
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
            #expect(error["code"] == .string("document"))
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
            #expect(try ruby.json()["shell_command_before"] as? [String] == ["rbenv shell 2.7"])
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
            #expect(warned.code == 0)
            #expect(warned.error.joined().contains("filters.unknown"))
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
            #expect(rejected.error.joined().contains("unsupported_config"))
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
                #expect(result.error.joined().contains("\"code\":\"document\""), "\(result.error)")
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

    @Test("load failures report retained sessions and roll back only the failed workspace")
    func partialLoad() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let good = root.appendingPathComponent("first.json")
            let bad = root.appendingPathComponent("second.json")
            try Data(#"{"session_name":"first","windows":[{"panes":[null]}]}"#.utf8).write(to: good)
            try Data(
                #"{"session_name":"second","windows":[{"layout":"not-a-layout","panes":[null]}]}"#
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
            #expect((result["workspaces"] as? [Any])?.count == 1)
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
                #"{"session_name":"unused","windows":[{"window_name":"retained","layout":"not-a-layout","panes":[null]}]}"#
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
            #expect((records.last?["data"] as? [String: Any])?["status"] as? String == "partial")
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
                #expect(result.error.joined().contains(#""code":"document""#), "\(result.error)")
            }
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
            try FileManager.default.createDirectory(at: configs, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
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
            #expect(try String(contentsOf: marker, encoding: .utf8) == work.path + "\n")
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
            #expect(try String(contentsOf: marker, encoding: .utf8) == root.path + "\n")
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
                #expect(result.error.joined().contains("document"))
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

    private func invoke(_ args: [String], in root: URL, extra: [String: String] = [:]) async
        -> Outcome
    {
        let output = Lines()
        let error = Lines()
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["TMUXP_CONFIGDIR"] = root.path
        environment["LIBTMUX_TMUX_BIN"] = "/unavailable-tmux"
        environment.merge(extra) { _, right in right }
        let context = CLIContext(
            directory: root, environment: environment, output: { await output.append($0) },
            error: { await error.append($0) })
        let code = await WorkspaceCLI.run(args, context: context)
        return await Outcome(code: code, output: output.values, error: error.values)
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

private struct Outcome: Sendable {
    let code: Int32
    let output: [String]
    let error: [String]

    func json() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(output.joined().utf8)) as? [String: Any] ?? [:]
    }
}
