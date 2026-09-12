import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import TmuxWorkspaceCLI

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
                #"{"session_name":"invalid","before_script":"touch never","windows":[{"panes":[null]}]}"#
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
        }
    }

    @Test("load starts an absent server on its selected socket")
    func coldLoad() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socket) = server.endpoint else { return }
            _ = try await server.run(TmuxCommand("kill-server"))
            #expect(try await !server.isRunning())
            let root = URL(fileURLWithPath: socket).deletingLastPathComponent()
            let file = root.appendingPathComponent("cold.json")
            try Data(#"{"session_name":"cold","windows":[{"panes":[null]}]}"#.utf8).write(to: file)
            let result = await invoke(
                ["load", file.path, "-d", "-S", socket, "-f", "/dev/null", "--json"], in: root,
                extra: ["LIBTMUX_TMUX_BIN": server.tmuxExecutable])
            #expect(result.code == 0, "\(result.error)")
            let sessions = try await server.sessions()
            #expect(sessions.map(\.name) == ["cold"])
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
