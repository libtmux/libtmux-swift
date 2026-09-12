import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import TmuxWorkspace

@Suite("workspace layout syntax")
struct WorkspaceLayoutTests {
    @Test(
        "layout preflight delegates geometry from the tmux corpus",
        arguments: ["3.2a", "3.3a", "3.7c"])
    func observedLayouts(version: String) throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "layout-preflight", withExtension: "json", subdirectory: "Fixtures"))
        let cases = try JSONDecoder().decode([LayoutCase].self, from: Data(contentsOf: url))
        let release = try #require(TmuxVersion(parsing: version))
        for item in cases {
            // These layouts are structurally safe; tmux rejects their geometry.
            let delegatesGeometry = [
                "bad-inner-size", "nested-invalid-width", "nested-short-parent",
            ].contains(item.id)
            #expect(
                WorkspaceLayout.accepts(item.layout, version: release, panes: item.panes)
                    == (item.accepts[version] == true || delegatesGeometry),
                Comment(rawValue: "\(item.id), tmux \(version)"))
        }
    }

    @Test("mirrored names change prefix resolution starting with tmux 3.5")
    func mirroredNameBoundary() {
        let before = TmuxVersion(major: 3, minor: 4)
        let after = TmuxVersion(major: 3, minor: 5)
        #expect(WorkspaceLayout.accepts("main-h", version: before, panes: 2))
        #expect(!WorkspaceLayout.accepts("main-h", version: after, panes: 2))
        #expect(!WorkspaceLayout.accepts("main-horizontal-mirrored", version: before, panes: 2))
        #expect(WorkspaceLayout.accepts("main-horizontal-mirrored", version: after, panes: 2))
        #expect(WorkspaceLayout.accepts("main-horizontal", version: after, panes: 2))
        #expect(WorkspaceLayout.accepts("", version: before, panes: 1))
    }

    @Test("layout names follow the daemon even when it has no sessions")
    func daemonVersionWins() async throws {
        let transport = LayoutVersionTransport(daemonVersion: "3.3a")
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-version/socket"),
            transport: transport)
        try await WorkspaceLayout.validate(
            [
                Workspace(
                    sessionName: "layout",
                    windows: [WindowPlan(layout: "main-h", panes: [PanePlan()])])
            ], on: server)
        let calls = await transport.arguments
        #expect(calls.count == 1)
        #expect(calls.first?.contains("display-message") == true)
        #expect(await transport.locales == ["C"])
    }

    @Test("layout version probes handle real cold and empty endpoints")
    func realDaemonVersionStates() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else { return }
            let version = try await server.version()
            let layout =
                version < TmuxVersion(major: 3, minor: 5)
                ? "main-h" : "main-horizontal-mirrored"
            let workspace = Workspace(
                sessionName: "layout", windows: [WindowPlan(layout: layout, panes: [PanePlan()])])
            let cold = try Server(socketPath: path + "-cold", tmuxExecutable: server.tmuxExecutable)
            try await WorkspaceLayout.validate([workspace], on: cold)
            #expect(!FileManager.default.fileExists(atPath: path + "-cold"))

            let identity = try await server.incarnation()
            let reply = try await server.run(
                TmuxCommand("set-option", ["-s", "exit-empty", "off"]))
            try #require(reply.isSuccess)
            for session in try await server.sessions() { try await server.kill(session) }
            #expect(try await server.sessions().isEmpty)
            try await WorkspaceLayout.validate([workspace], on: server)
            #expect(try await server.incarnation() == identity)
        }
    }

    @Test(
        "a cold endpoint uses the selected tmux executable version",
        arguments: [
            "no server running on /tmp/libtmux-swift-test/layout-version/socket",
            "error connecting to /tmp/libtmux-swift-test/layout-version/socket (No such file or directory)",
        ])
    func coldEndpointVersion(error: String) async throws {
        let transport = LayoutVersionTransport(daemonVersion: nil, error: error)
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-version/socket"),
            transport: transport)
        try await WorkspaceLayout.validate(
            [
                Workspace(
                    sessionName: "layout",
                    windows: [WindowPlan(layout: "main-horizontal-mirrored", panes: [PanePlan()])])
            ], on: server)
        #expect(await transport.arguments.contains { $0.contains("-V") })
    }

    @Test(
        "non-cold daemon failures do not use the client version",
        arguments: [
            "error connecting to /tmp/libtmux-swift-test/layout-version/socket (Permission denied)",
            "protocol version mismatch (client 8, server 7)",
            "server exited unexpectedly",
        ])
    func daemonVersionFailure(error: String) async throws {
        let transport = LayoutVersionTransport(daemonVersion: nil, error: error)
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-version/socket"),
            transport: transport)
        await #expect(
            throws: TmuxError.commandFailed(command: "display-message", exitCode: 1, reason: error)
        ) {
            try await WorkspaceLayout.validate(
                [
                    Workspace(
                        sessionName: "layout",
                        windows: [
                            WindowPlan(layout: "main-horizontal-mirrored", panes: [PanePlan()])
                        ])
                ], on: server)
        }
        #expect(await transport.arguments.count == 1)
    }

    @Test("an unreadable daemon version does not use the client version")
    func unreadableDaemonVersion() async throws {
        let transport = LayoutVersionTransport(daemonVersion: "unreadable")
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-version/socket"),
            transport: transport)
        await #expect(throws: TmuxError.self) {
            try await WorkspaceLayout.validate(
                [
                    Workspace(
                        sessionName: "layout",
                        windows: [
                            WindowPlan(layout: "main-horizontal-mirrored", panes: [PanePlan()])
                        ])
                ], on: server)
        }
        #expect(await transport.arguments.count == 1)
    }

    @Test("version-independent layouts do not probe tmux")
    func versionIndependentLayouts() async throws {
        let transport = LayoutVersionTransport(daemonVersion: nil)
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-version/socket"),
            transport: transport)
        try await WorkspaceLayout.validate(
            [
                Workspace(
                    sessionName: "layout",
                    windows: [WindowPlan(layout: "tiled", panes: [PanePlan()])])
            ], on: server)
        await #expect(throws: TmuxError.self) {
            try await WorkspaceLayout.validate(
                [
                    Workspace(
                        sessionName: "layout",
                        windows: [WindowPlan(layout: "not-a-layout", panes: [PanePlan()])])
                ], on: server)
        }
        #expect(await transport.arguments.isEmpty)
    }
}

private struct LayoutCase: Decodable {
    let id: String
    let layout: String
    let panes: Int
    let accepts: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case id, layout
        case panes = "pane_count"
        case accepts = "expected_valid"
    }
}

private actor LayoutVersionTransport: ProcessTransport {
    let daemonVersion: String?
    let error: String
    private(set) var arguments: [[String]] = []
    private(set) var locales: [String] = []

    init(
        daemonVersion: String?,
        error: String = "no server running on /tmp/libtmux-swift-test/layout-version/socket"
    ) {
        self.daemonVersion = daemonVersion
        self.error = error
    }

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        self.arguments.append(arguments)
        if let locale = environment["LC_ALL"] { locales.append(locale) }
        if arguments.contains("list-sessions"), daemonVersion != nil {
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        }
        if arguments.contains("display-message"), let daemonVersion {
            return TmuxReply(
                standardOutput: Array("\(daemonVersion)\n".utf8), standardError: [], exitCode: 0)
        }
        if arguments.contains("-V") {
            return TmuxReply(
                standardOutput: Array("tmux 3.7c\n".utf8), standardError: [], exitCode: 0)
        }
        return TmuxReply(standardOutput: [], standardError: Array("\(error)\n".utf8), exitCode: 1)
    }
}
