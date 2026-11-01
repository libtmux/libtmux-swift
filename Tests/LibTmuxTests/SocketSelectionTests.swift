import Foundation
import Testing

@testable import LibTmux
@testable import TmuxFixture

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// With no socket chosen, tmux is passed neither `-L` nor `-S` and picks the
/// server itself. `LIBTMUX_SOCKET_PATH` and `LIBTMUX_SOCKET` choose another,
/// and a socket named in code comes first.
@Suite("socket selection", .timeLimit(.minutes(5)))
struct SocketSelectionTests {
    // MARK: The rule, on the endpoint it produces

    @Test("an environment that names no socket leaves the choice to tmux")
    func noVariableChoosesNothing() throws {
        #expect(try Endpoint(environment: [:]) == .tmuxChoice)
        // What tmux itself sets is not a choice of this library's.
        let pane = [
            "TMUX": "/tmp/libtmux-swift-test/s,1,0", "TMUX_PANE": "%1", "TMUX_TMPDIR": "/x",
        ]
        #expect(try Endpoint(environment: pane) == .tmuxChoice)
    }

    @Test("LIBTMUX_SOCKET_PATH is a socket path and LIBTMUX_SOCKET a socket name")
    func eachVariableNamesItsKind() throws {
        let path = "/tmp/libtmux-swift-test/chosen.sock"
        #expect(try Endpoint(environment: ["LIBTMUX_SOCKET_PATH": path]) == .socketPath(path))
        #expect(
            try Endpoint(environment: ["LIBTMUX_SOCKET": "libtmux-swift-chosen"])
                == .socketName("libtmux-swift-chosen"))
    }

    @Test("the path wins when both variables are set")
    func thePathWinsOverTheName() throws {
        let path = "/tmp/libtmux-swift-test/chosen.sock"
        let both = ["LIBTMUX_SOCKET": "libtmux-swift-chosen", "LIBTMUX_SOCKET_PATH": path]
        #expect(try Endpoint(environment: both) == .socketPath(path))
    }

    @Test(
        "a blank variable counts as unset, each one on its own",
        arguments: ["", " ", "\t", " \n "])
    func blankVariablesAreUnset(_ blank: String) throws {
        #expect(try Endpoint(environment: ["LIBTMUX_SOCKET": blank]) == .tmuxChoice)
        #expect(try Endpoint(environment: ["LIBTMUX_SOCKET_PATH": blank]) == .tmuxChoice)
        // A blank path does not hide a name that is set, nor the other way round.
        #expect(
            try Endpoint(environment: [
                "LIBTMUX_SOCKET_PATH": blank, "LIBTMUX_SOCKET": "libtmux-swift-n",
            ])
                == .socketName("libtmux-swift-n"))
        #expect(
            try Endpoint(environment: ["LIBTMUX_SOCKET": blank, "LIBTMUX_SOCKET_PATH": "/tmp/s"])
                == .socketPath("/tmp/s"))
    }

    @Test("a value that is not blank is used as written")
    func valuesAreNotTrimmed() throws {
        #expect(
            try Endpoint(environment: ["LIBTMUX_SOCKET": " padded "]) == .socketName(" padded "))
        #expect(try Endpoint(environment: ["LIBTMUX_SOCKET_PATH": " /x "]) == .socketPath(" /x "))
    }

    @Test("a path past the limit is refused with its length and not its value")
    func aLongPathIsRefusedWithoutBeingRepeated() {
        let marker = "private-directory-name"
        let long =
            "/" + marker + String(repeating: "x", count: Endpoint.portableSocketPathByteLimit)
        do {
            _ = try Endpoint(environment: ["LIBTMUX_SOCKET_PATH": long])
            Issue.record("a path of \(long.utf8.count) bytes was accepted")
        } catch {
            #expect(
                error
                    == .invalidEndpoint(
                        .socketPathTooLong(
                            actualBytes: long.utf8.count,
                            maximumBytes: Endpoint.portableSocketPathByteLimit)))
            #expect(!String(describing: error).contains(marker))
        }
    }

    @Test("a server built from the environment has the endpoint the environment names")
    func serverFollowsTheEnvironment() throws {
        #expect(try Server(environment: [:]).endpoint == .tmuxChoice)
        #expect(
            try Server(environment: ["LIBTMUX_SOCKET": "libtmux-swift-n"]).endpoint
                == .socketName("libtmux-swift-n"))
        #expect(
            try Server(environment: ["LIBTMUX_SOCKET_PATH": "/tmp/s"]).endpoint
                == .socketPath("/tmp/s"))
    }

    @Test("a socket named in code leaves both variables unread")
    func anExplicitSocketComesFirst() throws {
        // These initializers take no environment, so there is nothing for the
        // variables to be read from: the process's own two are not consulted.
        // The case pins that by construction, so a later parameter that read
        // them would have to change this call.
        let named = try Server(socketName: "libtmux-swift-explicit")
        #expect(named.endpoint == .socketName("libtmux-swift-explicit"))
        let path = try Server(socketPath: "/tmp/libtmux-swift-test/explicit")
        #expect(path.endpoint == .socketPath("/tmp/libtmux-swift-test/explicit"))
    }

    // MARK: What tmux is passed

    @Test(
        "tmux is passed the flag that matches the endpoint, and none for a choice left to it",
        arguments: [
            (Endpoint.tmuxChoice, [String]()),
            (Endpoint.socketName("libtmux-swift-n"), ["-L", "libtmux-swift-n"]),
            (
                Endpoint.socketPath("/tmp/libtmux-swift-test/s"),
                ["-S", "/tmp/libtmux-swift-test/s"]
            ),
        ])
    func argumentsMatchTheEndpoint(_ endpoint: Endpoint, _ expected: [String]) async throws {
        let recorder = RecordingTransport()
        let server = Server(endpoint: endpoint, transport: recorder)
        _ = try await server.run(TmuxCommand("list-sessions"))

        let call = try #require(await recorder.calls.last)
        let flags = call.arguments.filter { $0 == "-L" || $0 == "-S" }
        // tmux takes the flags before the command, after the client options.
        let prefix = call.arguments.prefix { $0 != "list-sessions" }
        #expect(Array(prefix.suffix(expected.count)) == expected)
        #expect(flags.count == expected.count / 2)
    }

    @Test("a server that names no socket hands tmux the environment of its process")
    func theProcessEnvironmentReachesTheClient() async throws {
        let recorder = RecordingTransport()
        let server = Server(endpoint: .tmuxChoice, transport: recorder)
        _ = try await server.run(TmuxCommand("list-sessions"))
        let call = try #require(await recorder.calls.last)
        // A boolean, because a failing comparison of two environments prints
        // every variable in both. The sandbox never sets TMUX, so what a pane's
        // TMUX does to this path is `EnvironmentTests` and the executables'.
        let unchanged = call.environment == ProcessInfo.processInfo.environment
        #expect(unchanged, "the client was handed an environment other than the process's")
    }

    @Test("a command run inside a pane has no flag to carry the socket on")
    func shellInvocationNamesNoSocketForAChoice() {
        let server = Server(endpoint: .tmuxChoice, tmuxExecutable: "/usr/bin/tmux")
        #expect(server.shellInvocation == "/usr/bin/tmux")
        let named = Server(
            endpoint: .socketName("libtmux-swift-n"), tmuxExecutable: "/usr/bin/tmux")
        #expect(named.shellInvocation == "/usr/bin/tmux -L libtmux-swift-n")
    }

    // MARK: Against a real tmux, in the sandbox

    @Test(
        "the control client of a server that names no socket keeps TMUX, and one that names a socket drops it",
        .enabled(if: laneSupportsControl, "control mode needs tmux 3.7"))
    func theControlClientFollowsTheEndpointRule() async throws {
        try await withTmuxServer { surrounding in
            try await withPrivateTmuxDirectory { directory in
                let incarnation = try await surrounding.incarnation()
                let pane = "\(incarnation.socketPath),\(incarnation.processID),0"
                // What a process in a pane holds, for the control client to
                // be made from; the case never writes the process's own.
                let inPane = sandboxedEnvironment(
                    tmuxTemporaryDirectory: directory.path
                ).merging(["TMUX": pane, "TMUX_PANE": "%1"]) { $1 }

                let cases: [(name: String, endpoint: Endpoint, keepsTmux: Bool)] = [
                    ("choice", .tmuxChoice, true),
                    ("path", .socketPath(incarnation.socketPath), false),
                ]
                for (name, endpoint, keepsTmux) in cases {
                    let record = directory.appendingPathComponent("\(name).record")
                    let tmux = try recordingControlTmux(
                        at: directory.appendingPathComponent("\(name)-tmux"), recording: record)
                    let server = Server(
                        endpoint: endpoint, tmuxExecutable: tmux.path,
                        transport: PaneTransport(
                            tmuxTemporaryDirectory: directory.path, tmux: pane))
                    try await server.withControlMode(
                        attachingTo: "bootstrap", readingEnvironmentFrom: inPane
                    ) { _ in }

                    let seen = try String(contentsOf: record, encoding: .utf8)
                    #expect(
                        seen.contains("tmux=set") == keepsTmux,
                        "\(name): the control client's TMUX was not what its endpoint calls for: \(seen)"
                    )
                    #expect(seen.contains("pane=set") == false, "\(name): TMUX_PANE reached it")
                }
            }
        }
    }

    @Test("a server that names no socket lands on the default socket in its TMUX_TMPDIR")
    func aChoiceLandsOnTheDefaultSocket() async throws {
        try await withPrivateTmuxDirectory { directory in
            let server = Server(
                endpoint: .tmuxChoice, tmuxExecutable: tmuxExecutablePath(),
                configurationFile: "/dev/null",
                transport: PaneTransport(tmuxTemporaryDirectory: directory.path, tmux: nil))
            let standard = "\(directory.path)/tmux-\(getuid())/default"
            try await withStopped(server, socket: standard) {
                _ = try await server.newSession(named: "bare")
                #expect(FileManager.default.fileExists(atPath: standard))
                #expect(try await server.incarnation().socketPath == standard)
                #expect(try await server.sessions().map(\.name) == ["bare"])
            }
        }
    }

    @Test("inside tmux, a server that names no socket reaches the server TMUX names")
    func aChoiceFollowsTmux() async throws {
        try await withTmuxServer { surrounding in
            try await withPrivateTmuxDirectory { directory in
                let incarnation = try await surrounding.incarnation()
                let pane = "\(incarnation.socketPath),\(incarnation.processID),0"
                let standard = "\(directory.path)/tmux-\(getuid())/default"

                let inside = Server(
                    endpoint: .tmuxChoice, tmuxExecutable: tmuxExecutablePath(),
                    transport: PaneTransport(tmuxTemporaryDirectory: directory.path, tmux: pane))
                #expect(try await inside.sessions().map(\.name) == ["bootstrap"])
                #expect(try await inside.incarnation().socketPath == incarnation.socketPath)
                #expect(!FileManager.default.fileExists(atPath: standard))

                // The control: the same server outside any pane has nothing to
                // reach, so the answer above came from `TMUX` and not from
                // the directory.
                let outside = Server(
                    endpoint: .tmuxChoice, tmuxExecutable: tmuxExecutablePath(),
                    transport: PaneTransport(tmuxTemporaryDirectory: directory.path, tmux: nil))
                #expect(try await outside.isRunning() == false)
                #expect(!FileManager.default.fileExists(atPath: standard))
            }
        }
    }

    @Test("a name from LIBTMUX_SOCKET puts the server on that name in TMUX_TMPDIR")
    func theNameVariableChoosesTheSocketName() async throws {
        try await withNamedSocketRoot { root in
            let name = "libtmux-swift-var-\(UUID().uuidString.prefix(8))"
            let server = try Server(
                tmuxExecutable: tmuxExecutablePath(), configurationFile: "/dev/null",
                environment: ["LIBTMUX_SOCKET": name])
            let socket = "\(root.path)/tmux-\(getuid())/\(name)"
            try await withStopped(server, socket: socket) {
                _ = try await server.newSession(named: "named")
                #expect(server.endpoint == .socketName(name))
                #expect(FileManager.default.fileExists(atPath: socket))
                #expect(try await server.incarnation().socketPath == socket)
            }
        }
    }

    @Test("a path from LIBTMUX_SOCKET_PATH puts the server on that path, and wins over a name")
    func thePathVariableChoosesTheSocketPath() async throws {
        try await withNamedSocketRoot { root in
            let directory = root.appendingPathComponent("var-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let name = "libtmux-swift-ignored-\(UUID().uuidString.prefix(8))"
            let socket = directory.appendingPathComponent("s").path
            let server = try Server(
                tmuxExecutable: tmuxExecutablePath(), configurationFile: "/dev/null",
                environment: ["LIBTMUX_SOCKET_PATH": socket, "LIBTMUX_SOCKET": name])
            try await withStopped(server, socket: socket) {
                _ = try await server.newSession(named: "path")
                #expect(server.endpoint == .socketPath(socket))
                #expect(try await server.incarnation().socketPath == socket)
                #expect(
                    !FileManager.default.fileExists(atPath: "\(root.path)/tmux-\(getuid())/\(name)")
                )
            }
        }
    }
}

// MARK: Support

/// Records what the client is handed and answers as an empty tmux would.
private actor RecordingTransport: ProcessTransport {
    struct Call: Sendable {
        let arguments: [String]
        let environment: [String: String]
    }

    private(set) var calls: [Call] = []

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        calls.append(Call(arguments: arguments, environment: environment))
        return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
    }
}

/// A real tmux, started the way a process in a pane would start it: with the
/// `TMUX_TMPDIR` the test chooses, and a `TMUX` when the test says it is inside
/// tmux. It drops every other selector, so what the client reaches is decided
/// by the two values and not by the shell the suite was started from.
private struct PaneTransport: ProcessTransport {
    let tmuxTemporaryDirectory: String
    let tmux: String?
    private let underlying = SubprocessTransport()

    init(tmuxTemporaryDirectory: String, tmux: String?) {
        self.tmuxTemporaryDirectory = tmuxTemporaryDirectory
        self.tmux = tmux
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        var pane = sandboxedEnvironment(
            environment, tmuxTemporaryDirectory: tmuxTemporaryDirectory)
        if let tmux { pane["TMUX"] = tmux }
        return try await underlying.run(
            executable: executable, arguments: arguments, environment: pane,
            perStreamOutputLimit: perStreamOutputLimit)
    }
}

/// A tmux that writes whether `TMUX` and `TMUX_PANE` are set, and nothing else,
/// for each attach it is started as, and then runs the real one. Only the
/// control client attaches; the version probe and every other command do not.
/// The record holds names and booleans, so no failure can print a value.
private func recordingControlTmux(at script: URL, recording record: URL) throws -> URL {
    try Data(
        """
        #!/bin/sh
        case " $* " in
        *" attach-session "*)
            {
                if [ -n "${TMUX+x}" ]; then echo tmux=set; else echo tmux=unset; fi
                if [ -n "${TMUX_PANE+x}" ]; then echo pane=set; else echo pane=unset; fi
            } >> '\(record.path)'
            ;;
        esac
        exec '\(tmuxExecutablePath())' "$@"

        """.utf8
    ).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
}

/// A `TMUX_TMPDIR` of the case's own inside the run's, so two cases never share
/// a default socket.
private func withPrivateTmuxDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    try requireSandbox()
    let sandbox = try #require(ProcessInfo.processInfo.environment[sandboxMarker])
    let directory = URL(fileURLWithPath: sandbox)
        .appendingPathComponent("choice-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

/// The run's `TMUX_TMPDIR`, which a socket *name* resolves inside.
private func withNamedSocketRoot<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    try requireSandbox()
    let root = try #require(namedSocketRoot)
    try #require(namedSocketsAvailable, "needs TMUX_TMPDIR under the suite root")
    return try await body(root)
}

/// Runs `body`, then stops the server on `socket` and waits for it to go: the
/// run is failed for a server still listening when it ends.
private func withStopped(
    _ server: Server,
    socket: String,
    _ body: () async throws -> Void
) async throws {
    do {
        try await body()
    } catch {
        _ = try? await server.run(TmuxCommand("kill-server"))
        _ = try? await waitForSocketClosure(socket)
        throw error
    }
    _ = try await server.run(TmuxCommand("kill-server"))
    #expect(try await waitForSocketClosure(socket), "the server did not stop")
}
