import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("captured endpoint defaults", .timeLimit(.minutes(5)))
struct EndpointDefaultsTests {
    private let path = "/tmp/libtmux-swift-test/default-selected"

    @Test("ordinary construction selects the named default without connecting")
    func ordinaryDefaultIsPure() throws {
        let server = try Server(environment: [:])
        #expect(server.endpoint == .socketPath("/tmp/tmux-\(getuid())/default"))
        let empty = try Server(environment: [
            "LIBTMUX_SOCKET_PATH": "", "LIBTMUX_SOCKET_NAME": "", "TMUX": "", "TMUX_TMPDIR": "",
        ])
        #expect(empty.endpoint == server.endpoint)
    }

    @Test("explicit selectors and path environment ignore lower invalid selectors")
    func selectionPrecedence() throws {
        let invalid = [
            "LIBTMUX_SOCKET_PATH": "relative", "LIBTMUX_SOCKET_NAME": "..", "TMUX": "invalid",
            "TMUX_TMPDIR": "relative",
        ]
        #expect(try Server(socketPath: path, environment: invalid).endpoint == .socketPath(path))
        var environment = invalid
        environment["TMUX_TMPDIR"] = "/tmp/libtmux-swift-test/root"
        let named = try Server(socketName: "chosen", environment: environment)
        #expect(
            named.endpoint == .socketPath("/tmp/libtmux-swift-test/root/tmux-\(getuid())/chosen"))
        environment["LIBTMUX_SOCKET_PATH"] = path
        #expect(try Server(environment: environment).endpoint == .socketPath(path))
        environment["LIBTMUX_SOCKET_PATH"] = ""
        environment["LIBTMUX_SOCKET_NAME"] = "chosen"
        #expect(try Server(environment: environment).endpoint == named.endpoint)
        environment["LIBTMUX_SOCKET_NAME"] = ""
        environment["TMUX"] = "\(path),with comma,001,$002"
        #expect(try Server(environment: environment).endpoint == .socketPath("\(path),with comma"))
        #expect(TmuxContext(parsing: "\(path),001,$002")?.sessionID == "$2")
        #expect(TmuxContext(parsing: "\(path),1,-1")?.sessionID == nil)
    }

    @Test(
        "a selected invalid value fails without choosing a lower endpoint",
        arguments: [
            ["LIBTMUX_SOCKET_PATH": "relative", "LIBTMUX_SOCKET_NAME": "valid"],
            ["LIBTMUX_SOCKET_NAME": "..", "TMUX": "/tmp/ok,1,0"],
            ["TMUX": "/tmp/ok,0,0"], ["TMUX": "/tmp/ok,1,$-1"],
            ["TMUX": "/tmp/ok,1,1x"], ["TMUX": "/tmp/ok,1,1 "],
            ["TMUX": "/tmp/ok,1,١"], ["TMUX_TMPDIR": "relative"],
            ["TMUX_TMPDIR": "/tmp/a\0b"],
        ]
    )
    func invalidSelectionFails(_ environment: [String: String]) {
        #expect(throws: TmuxError.self) { try Server(environment: environment) }
    }

    @Test("public constructors validate raw enum cases and simultaneous selectors")
    func constructorsCannotBypassValidation() {
        for endpoint in [
            Endpoint.socketPath("relative"), .socketPath("/tmp/a\0b"),
            .socketName(""), .socketName(".."), .socketName("a/b"), .socketName("a\\b"),
        ] {
            #expect(throws: TmuxError.self) { try Server(endpoint: endpoint, environment: [:]) }
        }
        #expect(throws: TmuxError.invalidEndpoint(.conflictingSelectors)) {
            try Server(socketPath: path, socketName: "name", environment: [:])
        }
    }

    @Test("paths retain commas, whitespace and filesystem traversal spelling")
    func pathSpellingSurvives() throws {
        let path = "/tmp/libtmux-swift-test/a, b\t/../sock "
        #expect(
            try Server(environment: ["LIBTMUX_SOCKET_PATH": path]).endpoint == .socketPath(path))
        #expect(try Server(environment: ["TMUX": "\(path),1,-1"]).endpoint == .socketPath(path))
        let root = "/tmp/libtmux-swift-test/missing/../selected"
        #expect(
            try Server(environment: ["TMUX_TMPDIR": root]).endpoint
                == .socketPath("\(root)/tmux-\(getuid())/default"))
    }

    @Test("a value environment is captured and nested tmux context is removed")
    func environmentSnapshot() async throws {
        let transport = EndpointRecordingTransport()
        var environment = [
            "PATH": "/usr/bin:/bin", "SENTINEL": "first", "TMUX": "\(path),1,0",
            "TMUX_PANE": "%9", "LIBTMUX_SOCKET_PATH": path,
        ]
        let hostBefore = ProcessInfo.processInfo.environment
        let server = try Server(
            endpoint: .socketPath(path), environment: environment, transport: transport)
        environment["SENTINEL"] = "second"
        environment["LIBTMUX_SOCKET_PATH"] = "/tmp/libtmux-swift-test/other"
        _ = try await server.run(TmuxCommand("list-sessions"))
        let invocation = try #require(await transport.last)
        #expect(invocation.arguments == ["-u", "-S", path, "list-sessions"])
        #expect(invocation.environment["SENTINEL"] == "first")
        #expect(invocation.environment["TMUX"] == nil)
        #expect(invocation.environment["TMUX_PANE"] == nil)
        #expect(ProcessInfo.processInfo.environment == hostBefore)
    }

    @Test("a fresh named root creates only the private per-user directory")
    func freshNamedRootAndControlMode() async throws {
        try await withTmuxServer { host in
            let root = try directory(of: host)
            let selectedRoot = root + "/named"
            try FileManager.default.createDirectory(
                atPath: selectedRoot, withIntermediateDirectories: false)
            var environment = ProcessInfo.processInfo.environment
            environment["TMUX_TMPDIR"] = selectedRoot
            environment["LIBTMUX_SOCKET_NAME"] = "captured"
            environment["LIBTMUX_SOCKET_PATH"] = nil
            environment["TMUX"] = "invalid lower priority"
            environment["TMUX_PANE"] = "%99"
            environment["SENTINEL"] = "captured"
            let server = try Server(
                tmuxExecutable: tmuxExecutablePath(), configurationFile: "/dev/null",
                environment: environment)
            environment["TMUX_TMPDIR"] = root + "/unselected"
            environment["SENTINEL"] = "changed"
            try await server.withNewSession(named: "owned", shell: "sleep 300") { session in
                #expect(
                    try await server.incarnation().socketPath == selectedRoot
                        + "/tmux-\(getuid())/captured")
                #expect(try await server.environmentValue("SENTINEL") == "captured")
                try await server.connected(attachingTo: session.id.rawValue) {
                    connected, _ async throws -> Void in
                    #expect(try await connected.sessions().map(\.id) == [session.id])
                }
            }
            #expect(!(try await server.isRunning()))
            let attrs = try FileManager.default.attributesOfItem(
                atPath: selectedRoot + "/tmux-\(getuid())")
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try await host.isRunning())
        }
    }

    @Test("missing and removed roots fail before the process boundary")
    func missingRootsCannotFallBack() async throws {
        try await withTmuxServer { host in
            let root = try directory(of: host)
            try FileManager.default.createDirectory(
                atPath: root + "/selected", withIntermediateDirectories: false)
            for selected in [root + "/missing", root + "/missing/../selected"] {
                let transport = EndpointRecordingTransport()
                let server = try Server(
                    endpoint: .socketName("private"), environment: ["TMUX_TMPDIR": selected],
                    transport: transport)
                await #expect(throws: TmuxError.self) {
                    try await server.run(TmuxCommand("new-session", ["-d"]))
                }
                #expect(await transport.last == nil)
                #expect(!FileManager.default.fileExists(atPath: root + "/missing"))
            }
            let removed = root + "/removed"
            try FileManager.default.createDirectory(
                atPath: removed, withIntermediateDirectories: false)
            let server = try Server(socketName: "private", environment: ["TMUX_TMPDIR": removed])
            try FileManager.default.removeItem(atPath: removed)
            await #expect(throws: TmuxError.self) {
                try await server.withControlMode(attachingTo: "missing") { _ in }
            }
            #expect(!FileManager.default.fileExists(atPath: removed))
        }
    }

    @Test("a symlink followed by parent traversal follows the filesystem")
    func symlinkParentTraversal() async throws {
        try await withTmuxServer { host in
            let root = try directory(of: host)
            try FileManager.default.createDirectory(
                atPath: root + "/actual/child", withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                atPath: root + "/link", withDestinationPath: root + "/actual/child")
            let selectedRoot = root + "/link/.."
            let server = try Server(
                socketName: "private", tmuxExecutable: tmuxExecutablePath(),
                configurationFile: "/dev/null",
                environment: ["PATH": "/usr/bin:/bin", "TMUX_TMPDIR": selectedRoot])
            try await server.withNewSession(named: "owned", shell: "sleep 300") { _ in
                #expect(
                    FileManager.default.fileExists(
                        atPath: root + "/actual/tmux-\(getuid())/private"))
                #expect(!FileManager.default.fileExists(atPath: root + "/tmux-\(getuid())/private"))
            }
        }
    }

    @Test("the per-user directory allows group bits and refuses other-user bits or a symlink")
    func namedDirectoryChecks() async throws {
        try await withTmuxServer { host in
            let root = try directory(of: host)
            let directory = root + "/tmux-\(getuid())"
            let transport = EndpointRecordingTransport()
            let server = try Server(
                endpoint: .socketName("private"), environment: ["TMUX_TMPDIR": root],
                transport: transport)
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o770], ofItemAtPath: directory)
            _ = try await server.run(TmuxCommand("list-sessions"))
            #expect(await transport.last != nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o701], ofItemAtPath: directory)
            await #expect(throws: TmuxError.self) {
                try await server.run(TmuxCommand("list-sessions"))
            }
            try FileManager.default.removeItem(atPath: directory)
            try FileManager.default.createSymbolicLink(atPath: directory, withDestinationPath: root)
            await #expect(throws: TmuxError.self) {
                try await server.run(TmuxCommand("list-sessions"))
            }
        }
    }

    private func directory(of server: Server) throws -> String {
        guard case let .socketPath(path) = server.endpoint else {
            throw TestFailure.unexpectedEndpoint
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private enum TestFailure: Error { case unexpectedEndpoint }
}

private actor EndpointRecordingTransport: ProcessTransport {
    struct Invocation: Sendable {
        let arguments: [String]
        let environment: [String: String]
    }
    var last: Invocation?

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        last = Invocation(arguments: arguments, environment: environment)
        return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
    }
}
