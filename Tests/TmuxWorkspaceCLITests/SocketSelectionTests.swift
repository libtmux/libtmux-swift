import Foundation
import Testing

@testable import LibTmux
@testable import TmuxFixture
@testable import TmuxWorkspaceCLI

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A command names its server with `-S`, then `-L`, then `LIBTMUX_SOCKET_PATH`,
/// then `LIBTMUX_SOCKET`. With none of them it passes tmux no socket, except
/// where it acts on the pane it runs in, which takes the socket `TMUX` names.
@Suite("workspace socket selection", .timeLimit(.minutes(5)))
struct WorkspaceSocketSelectionTests {
    private static let pane = "/tmp/libtmux-swift-test/pane/s,4242,3"

    private func endpoint(
        path: String? = nil, name: String? = nil, followingPane: Bool = false,
        environment: [String: String] = [:]
    ) throws -> Endpoint {
        var options = SocketOptions()
        options.path = path
        options.name = name
        let context = CLIContext(
            directory: URL(fileURLWithPath: "/tmp/libtmux-swift-test"),
            environment: environment, output: { _ in }, error: { _ in })
        return try WorkspaceCommands.server(
            options, followingPane: followingPane, context: context
        ).endpoint
    }

    @Test("with no flag and no variable, tmux is left to choose, in tmux or out of it")
    func nothingNamedLeavesTheChoiceToTmux() throws {
        #expect(try endpoint() == .tmuxChoice)
        #expect(try endpoint(environment: ["TMUX": Self.pane, "TMUX_PANE": "%1"]) == .tmuxChoice)
        // A `TMUX` that is not a socket is not this command's to refuse: it
        // names no socket here, and tmux is the one that reads it.
        #expect(try endpoint(environment: ["TMUX": "not a socket"]) == .tmuxChoice)
        #expect(try endpoint(environment: ["TMUX": ""]) == .tmuxChoice)
    }

    @Test("a socket variable names the server, and the path wins over the name")
    func variablesNameTheServer() throws {
        #expect(
            try endpoint(environment: ["LIBTMUX_SOCKET_PATH": "/tmp/libtmux-swift-test/v.sock"])
                == .socketPath("/tmp/libtmux-swift-test/v.sock"))
        #expect(
            try endpoint(environment: ["LIBTMUX_SOCKET": "libtmux-swift-v"])
                == .socketName("libtmux-swift-v"))
        #expect(
            try endpoint(environment: [
                "LIBTMUX_SOCKET": "libtmux-swift-v", "LIBTMUX_SOCKET_PATH": "/tmp/v.sock",
            ]) == .socketPath("/tmp/v.sock"))
        #expect(
            try endpoint(environment: ["LIBTMUX_SOCKET": " ", "LIBTMUX_SOCKET_PATH": ""])
                == .tmuxChoice)
    }

    @Test("a variable beats the TMUX socket, which a pane-bound command uses otherwise")
    func variablesBeatTmux() throws {
        let inside = ["TMUX": Self.pane, "TMUX_PANE": "%1"]
        #expect(
            try endpoint(
                followingPane: true,
                environment: inside.merging(["LIBTMUX_SOCKET": "libtmux-swift-v"]) { $1 })
                == .socketName("libtmux-swift-v"))
        #expect(
            try endpoint(
                followingPane: true,
                environment: inside.merging(["LIBTMUX_SOCKET_PATH": "/tmp/v.sock"]) { $1 })
                == .socketPath("/tmp/v.sock"))
    }

    @Test("the flags come first, and the variables are not read beside them")
    func flagsComeFirst() throws {
        let variables = [
            "LIBTMUX_SOCKET_PATH": "/tmp/libtmux-swift-test/variable.sock",
            "LIBTMUX_SOCKET": "libtmux-swift-variable",
        ]
        #expect(
            try endpoint(path: "/tmp/libtmux-swift-test/flag.sock", environment: variables)
                == .socketPath("/tmp/libtmux-swift-test/flag.sock"))
        #expect(
            try endpoint(name: "libtmux-swift-flag", environment: variables)
                == .socketName("libtmux-swift-flag"))
        // Even an unusable variable is not looked at beside a flag.
        let tooLong = String(repeating: "x", count: 200)
        #expect(
            try endpoint(
                name: "libtmux-swift-flag", environment: ["LIBTMUX_SOCKET_PATH": "/" + tooLong])
                == .socketName("libtmux-swift-flag"))
    }

    @Test("a command that acts on its own pane takes the socket TMUX names")
    func aPaneBoundCommandFollowsTmux() throws {
        let inside = ["TMUX": Self.pane, "TMUX_PANE": "%1"]
        #expect(
            try endpoint(followingPane: true, environment: inside)
                == .socketPath("/tmp/libtmux-swift-test/pane/s"))
        // Outside tmux there is no pane to follow, and nothing is refused.
        #expect(try endpoint(followingPane: true) == .tmuxChoice)
        #expect(try endpoint(followingPane: true, environment: ["TMUX": ""]) == .tmuxChoice)
        // A flag still comes first, and a command that is not pane-bound does
        // not read `TMUX` at all.
        #expect(
            try endpoint(
                path: "/tmp/libtmux-swift-test/flag.sock", followingPane: true, environment: inside)
                == .socketPath("/tmp/libtmux-swift-test/flag.sock"))
        #expect(try endpoint(environment: inside) == .tmuxChoice)
    }

    @Test("a pane-bound command refuses a TMUX that is not a socket, PID and session")
    func aPaneBoundCommandRefusesAMalformedTmux() {
        do {
            _ = try endpoint(followingPane: true, environment: ["TMUX": "/tmp/s,not-a-pid,0"])
            Issue.record("a malformed TMUX was accepted")
        } catch let error as CLIError {
            #expect(error.code == "usage")
            #expect(error.status == 2)
            #expect(!error.message.contains("not-a-pid"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("a socket path past the limit is refused without being repeated")
    func aLongPathVariableIsRefusedWithoutBeingRepeated() {
        let long = "/private-directory-name" + String(repeating: "x", count: 200)
        do {
            _ = try endpoint(environment: ["LIBTMUX_SOCKET_PATH": long])
            Issue.record("a path past the limit was accepted")
        } catch let error as TmuxError {
            guard case .invalidEndpoint(.socketPathTooLong) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(!String(describing: error).contains("private-directory-name"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("the terminal handoff names a socket only when one was chosen")
    func attachNamesASocketOnlyWhenChosen() {
        func arguments(_ endpoint: Endpoint) -> [String] {
            WorkspaceCommands.attachArguments(
                executable: "tmux", colors256: false, endpoint: endpoint, session: "s")
        }
        #expect(arguments(.tmuxChoice) == ["tmux", "-N", "-u", "attach-session", "-t", "s"])
        #expect(
            arguments(.socketName("libtmux-swift-n"))
                == ["tmux", "-N", "-u", "-L", "libtmux-swift-n", "attach-session", "-t", "s"])
        #expect(
            arguments(.socketPath("/tmp/libtmux-swift-test/s"))
                == [
                    "tmux", "-N", "-u", "-S", "/tmp/libtmux-swift-test/s", "attach-session", "-t",
                    "s",
                ])
    }

    // MARK: The executable, against a real tmux

    @Test("with no socket named, the executable acts on the server TMUX names")
    func theExecutableFollowsTmux() async throws {
        try await withTmuxServer { surrounding in
            let incarnation = try await surrounding.incarnation()
            let pane = "\(incarnation.socketPath),\(incarnation.processID),0"
            try withPrivateDirectory { directory in
                let inside = try freeze(in: directory, environment: ["TMUX": pane])
                #expect(inside.status == 0, "\(inside.error)")
                #expect(inside.session == "bootstrap")

                // The control: the same command outside any pane has no server
                // to reach, so the answer above came from `TMUX`.
                let outside = try freeze(in: directory, environment: [:])
                #expect(outside.status == 1)
                #expect(outside.error.contains("session_not_found"), "\(outside.error)")
            }
        }
    }

    @Test("with no flag, the executable acts on the server LIBTMUX_SOCKET_PATH names")
    func theExecutableFollowsTheVariable() async throws {
        try await withTmuxServer { chosen in
            let incarnation = try await chosen.incarnation()
            try withPrivateDirectory { directory in
                let named = try freeze(
                    in: directory, environment: ["LIBTMUX_SOCKET_PATH": incarnation.socketPath])
                #expect(named.status == 0, "\(named.error)")
                #expect(named.session == "bootstrap")
            }
        }
    }

    /// What `tmux-workspace freeze bootstrap --json` printed and exited with.
    private struct Frozen {
        let status: Int32
        let session: String?
        let error: String
    }

    private func withPrivateDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("workspace-socket-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// Runs the shipped executable with a `TMUX_TMPDIR` of its own and exactly
    /// the selectors the case passes, and names no `-S` or `-L`.
    private func freeze(in directory: URL, environment: [String: String]) throws -> Frozen {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/tmux-workspace")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["freeze", "bootstrap", "--json"]
        process.environment = sandboxedEnvironment(
            tmuxTemporaryDirectory: directory.path
        ).merging([
            "LIBTMUX_TMUX_BIN": tmuxExecutablePath(), "HOME": directory.path,
            "TMUXP_CONFIGDIR": directory.path,
        ]) { _, new in new }.merging(environment) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let document = try? JSONSerialization.jsonObject(with: out) as? [String: Any]
        return Frozen(
            status: process.terminationStatus, session: document?["session_name"] as? String,
            error: String(decoding: err, as: UTF8.self))
    }
}
