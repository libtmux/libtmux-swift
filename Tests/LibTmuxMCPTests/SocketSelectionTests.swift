import Foundation
import Testing

@testable import LibTmux
@testable import LibTmuxMCP
@testable import TmuxFixture

/// With no socket chosen the server passes tmux neither `-L` nor `-S`, so tmux
/// picks the server. `LIBTMUX_SOCKET_PATH` and `LIBTMUX_SOCKET` choose another.
@Suite("MCP socket selection", .timeLimit(.minutes(5)))
struct MCPSocketSelectionTests {
    @Test("an environment that names no socket configures none, and is not an error")
    func noVariableConfiguresNoSocket() throws {
        let configuration = ServerConfiguration(environment: [:])
        #expect(configuration.errors.isEmpty)
        #expect(configuration.socketPath == nil)
        #expect(configuration.socketName == nil)
        #expect(configuration.tmuxConfigurationFile == nil)
        #expect(try configuration.makeServer().endpoint == .tmuxChoice)
        #expect(configuration.endpointSummary == "the server tmux picks")
    }

    @Test("LIBTMUX_SOCKET_PATH is a socket path and LIBTMUX_SOCKET a socket name")
    func eachVariableNamesItsKind() throws {
        let path = ServerConfiguration(environment: ["LIBTMUX_SOCKET_PATH": "/tmp/mcp.sock"])
        #expect(path.errors.isEmpty)
        #expect(path.socketPath == "/tmp/mcp.sock")
        #expect(path.socketName == nil)
        #expect(path.endpointSummary == "socket path /tmp/mcp.sock")

        let name = ServerConfiguration(environment: ["LIBTMUX_SOCKET": "libtmux-swift-mcp"])
        #expect(name.errors.isEmpty)
        #expect(name.socketName == "libtmux-swift-mcp")
        #expect(name.socketPath == nil)
        #expect(try name.makeServer().endpoint == .socketName("libtmux-swift-mcp"))
        #expect(name.endpointSummary == "socket name libtmux-swift-mcp")
    }

    @Test("the path wins when both variables are set, and that is not an error")
    func thePathWinsOverTheName() throws {
        let socket = "/tmp/libtmux-swift-test/mcp-both/s"
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET": "libtmux-swift-mcp", "LIBTMUX_SOCKET_PATH": socket])
        #expect(configuration.errors.isEmpty)
        #expect(configuration.socketPath == socket)
        #expect(configuration.socketName == nil)
        #expect(configuration.endpointSummary == "socket path \(socket)")
    }

    @Test(
        "a blank variable counts as unset, each one on its own",
        arguments: ["", " ", "\t", " \n "])
    func blankVariablesAreUnset(_ blank: String) {
        let neither = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET": blank, "LIBTMUX_SOCKET_PATH": blank])
        #expect(neither.errors.isEmpty)
        #expect(neither.socketPath == nil)
        #expect(neither.socketName == nil)

        // A blank path does not hide a name that is set, nor the other way round.
        let name = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET_PATH": blank, "LIBTMUX_SOCKET": "libtmux-swift-n"])
        #expect(name.errors.isEmpty)
        #expect(name.socketName == "libtmux-swift-n")
        let path = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET": blank, "LIBTMUX_SOCKET_PATH": "/tmp/mcp.sock"])
        #expect(path.errors.isEmpty)
        #expect(path.socketPath == "/tmp/mcp.sock")
    }

    @Test("a relative path is refused, naming the variable and not the value")
    func aRelativePathIsRefusedWithoutBeingRepeated() {
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET_PATH": "private-directory/relative.sock"])
        #expect(configuration.errors == ["LIBTMUX_SOCKET_PATH must be an absolute path"])
    }

    @Test("the dedicated libtmux-mcp socket and its bundled configuration are gone")
    func noDedicatedDefault() {
        let configuration = ServerConfiguration(environment: [:])
        #expect(configuration.socketName != "libtmux-mcp")
        #expect(configuration.tmuxConfigurationFile == nil)
        #expect(!configuration.authority.toolsets.contains(.teardown))
    }

    // MARK: What the pin reports, against a real tmux

    @Test("a server the environment names reports that it was chosen by path")
    func aPathIsReportedAsAPath() async throws {
        try await withTmuxServer { running in
            let incarnation = try await running.incarnation()
            let configuration = ServerConfiguration(
                environment: [
                    "LIBTMUX_SOCKET_PATH": incarnation.socketPath,
                    "LIBTMUX_TMUX_BIN": running.tmuxExecutable,
                ])
            let pin = try await configuration.pinForStartup()
            #expect(pin.provenance.selectionProvenance == "socket-path")
            #expect(pin.provenance.selector == "path:\(incarnation.socketPath)")
            #expect(pin.provenance.serverState == "existing")
            #expect(pin.provenance.resolvedSocketPath == incarnation.socketPath)
            #expect(pin.provenance.attachCommand?.contains(" -N -S ") == true)
        }
    }

    @Test("a socket name reports that it was chosen by name")
    func aNameIsReportedAsAName() async throws {
        let name = "libtmux-swift-mcp-\(UUID().uuidString.prefix(8))"
        let configuration = ServerConfiguration(
            environment: ["LIBTMUX_SOCKET": name, "LIBTMUX_TMUX_BIN": tmuxExecutablePath()])
        let pin = try await configuration.pinForStartup()
        #expect(pin.provenance.selectionProvenance == "socket-name")
        #expect(pin.provenance.selector == "name:\(name)")
        #expect(pin.provenance.serverState == "absent")
        #expect(pin.provenance.attachCommand?.contains(" -N -L ") == true)
        // Looking at a server that is not there does not start it.
        #expect(try await pin.server.isRunning() == false)
    }

    @Test("a server tmux picks reports its choice, and the server it picked when one runs")
    func aChoiceIsReportedAsAChoice() async throws {
        try await withTmuxServer { surrounding in
            let incarnation = try await surrounding.incarnation()
            let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
                .appendingPathComponent("mcp-pin-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let configuration = ServerConfiguration(
                environment: ["LIBTMUX_TMUX_BIN": surrounding.tmuxExecutable])

            let inside = Server(
                endpoint: .tmuxChoice, tmuxExecutable: surrounding.tmuxExecutable,
                transport: PaneTransport(
                    tmuxTemporaryDirectory: directory.path,
                    tmux: "\(incarnation.socketPath),\(incarnation.processID),0"))
            let pinned = try await configuration.pinForStartup(server: inside)
            #expect(pinned.provenance.selectionProvenance == "tmux-choice")
            #expect(pinned.provenance.selector == "tmux-choice")
            #expect(pinned.provenance.serverState == "existing")
            #expect(pinned.provenance.resolvedSocketPath == incarnation.socketPath)
            // Named by the socket it reached, since the shell the command is
            // pasted into may pick another server.
            #expect(
                pinned.provenance.attachCommand?.hasSuffix(
                    " -N -S '\(incarnation.socketPath)' attach") == true)

            // The control: outside any pane the same configuration finds no
            // server, so the answer above came from `TMUX`.
            let outside = Server(
                endpoint: .tmuxChoice, tmuxExecutable: surrounding.tmuxExecutable,
                transport: PaneTransport(tmuxTemporaryDirectory: directory.path, tmux: nil))
            let absent = try await configuration.pinForStartup(server: outside)
            #expect(absent.provenance.selectionProvenance == "tmux-choice")
            #expect(absent.provenance.serverState == "absent")
            #expect(absent.provenance.resolvedSocketPath == nil)
            #expect(absent.provenance.attachCommand?.hasSuffix(" -N attach") == true)
        }
    }
}

/// A real tmux, started the way a process in a pane would start it: with the
/// `TMUX_TMPDIR` the test chooses, and a `TMUX` when the test says it is inside
/// tmux. It drops every other selector.
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
