import Testing
import TmuxFixture

@testable import LibTmux

@Suite("layout preflight", .timeLimit(.minutes(1)))
struct LayoutTests {
    @Test("saved syntax bounds numbers and depth without limiting input length")
    func savedSyntaxBounds() {
        let version = TmuxVersion(major: 3, minor: 7)
        func saved(_ body: String) -> String {
            let checksum = body.utf8.reduce(UInt16(0)) { sum, byte in
                ((sum >> 1) | (sum << 15)) &+ UInt16(byte)
            }
            let hex = String(checksum, radix: 16)
            return String(repeating: "0", count: 4 - hex.count) + hex + "," + body
        }
        let root = "80x24,0,0"
        for (depth, expected) in [(256, true), (257, false)] {
            let body =
                String(repeating: root + "{", count: depth) + root
                + String(repeating: "}", count: depth)
            #expect(LayoutSyntax.accepts(saved(body), version: version, panes: 1) == expected)
        }
        let large = root + "{" + Array(repeating: root, count: 1_000).joined(separator: ",") + "}"
        #expect(large.utf8.count > 8_192)
        #expect(LayoutSyntax.accepts(saved(large), version: version, panes: 1_000))
        #expect(LayoutSyntax.accepts(saved("4294967295x24,0,0"), version: version, panes: 1))
        #expect(!LayoutSyntax.accepts(saved("4294967296x24,0,0"), version: version, panes: 1))
        #expect(!LayoutSyntax.accepts(saved("80x24,0,0,4294967296"), version: version, panes: 1))
    }

    @Test("saved layouts do not treat captured pane counts as live capacity")
    func capturedPaneCountIsNotLive() async throws {
        try await withTmuxServer { server in
            let identity = try await server.incarnation()
            let first = try #require(try await server.windows().first)
            let extra = try await server.splitWindow(first)
            let captured = try #require(try await server.window(first.id))
            try #require(captured.paneCount == 2)
            try await server.kill(extra)
            let link = try #require(try await server.windowLinks().first)
            let layout = try #require(try await server.format("#{window_layout}", for: link))
            let uppercase = layout.prefix(4).uppercased() + layout.dropFirst(4)
            try await server.selectLayout(captured, uppercase)
            #expect(try await server.window(first.id)?.paneCount == 1)
            #expect(try await server.incarnation() == identity)
        }
    }

    @Test("all static layouts and pane counts are checked before version I/O")
    func allInputsBeforeVersion() async throws {
        let transport = LayoutProbeTransport()
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-batch/socket"),
            transport: transport)
        try await server.validateLayouts([])
        try await server.validateLayouts([("even-h", 2), ("B25D,80x24,0,0,0", 1)])
        for invalid in [("", 1), ("tiled", 0), ("b25d,80x24,0,0,0", 2)] {
            await #expect(throws: TmuxError.self) {
                try await server.validateLayouts([("main-h", 1), invalid])
            }
        }
        #expect(await transport.arguments.isEmpty)
    }

    @Test("cancelled layout validation preserves cancellation without I/O")
    func cancellationBeforeIO() async throws {
        let transport = LayoutProbeTransport()
        let server = Server(
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/layout-cancel/socket"),
            transport: transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await server.validateLayouts([])
        }
        await #expect(throws: TmuxError.cancelled) { try await task.value }
        #expect(await transport.arguments.isEmpty)
    }

    @Test("a captured window never falls back to a cold client version")
    func capturedWindowRefusesColdFallback() async throws {
        let path = "/tmp/libtmux-swift-test/layout-bound/socket"
        let endpoint = try Endpoint(socketPath: path)
        let transport = LayoutProbeTransport()
        let server = Server(endpoint: endpoint, transport: transport)
        let window = Window(
            id: "@1", name: "keeper", paneCount: 1, width: 80, height: 24,
            incarnation: ServerIncarnation(
                endpoint: endpoint, socketPath: path, processID: 123, startedAt: 456))
        await #expect(throws: TmuxError.self) {
            try await server.selectLayout(window, "main-horizontal-mirrored")
        }
        let calls = await transport.arguments
        #expect(calls.count == 1)
        #expect(!calls.contains { $0.contains("-V") })
    }

    @Test("a running daemon is asked its version once per endpoint")
    func daemonVersionIsAskedOnce() async throws {
        try await withTmuxServer { fixture in
            let version = try await fixture.version()
            let layout =
                version < TmuxVersion(major: 3, minor: 5)
                ? "main-h" : "main-horizontal-mirrored"
            let transport = LayoutProbeTransport(forward: true)
            let server = Server(
                endpoint: fixture.endpoint, tmuxExecutable: fixture.tmuxExecutable,
                transport: transport)
            let window = try #require(try await server.windows().first)
            let before = await transport.arguments.count
            for _ in 0..<3 {
                try await server.validateLayouts([(layout, 1)])
                try await server.selectLayout(window, layout)
            }
            let probes = await transport.arguments.filter {
                $0.contains { $0.contains("#{version}") }
            }
            #expect(probes.count == 1)
            #expect(await transport.arguments.count > before)
        }
    }

    @Test("versioned layouts remain on the selected control connection")
    func controlRouteAndClosedConnection() async throws {
        try await withTmuxServer { fixture in
            let identity = try await fixture.incarnation()
            let version = try await fixture.version()
            let layout =
                version < TmuxVersion(major: 3, minor: 5)
                ? "main-h" : "main-horizontal-mirrored"
            let transport = LayoutProbeTransport(forward: true)
            let server = Server(
                endpoint: fixture.endpoint, tmuxExecutable: fixture.tmuxExecutable,
                transport: transport)
            let closed = try await server.using(.connected(to: "bootstrap")) { connected in
                let window = try #require(try await connected.windows().first)
                let before = await transport.arguments.count
                try await connected.validateLayouts([(layout, 1)])
                try await connected.selectLayout(window, layout)
                #expect(await transport.arguments.count == before)
                return connected
            }
            let before = await transport.arguments.count
            await #expect(throws: TmuxError.self) {
                try await closed.validateLayouts([(layout, 1)])
            }
            #expect(await transport.arguments.count == before)
            #expect(try await fixture.incarnation() == identity)
        }
    }
}

private actor LayoutProbeTransport: ProcessTransport {
    let forward: Bool
    private(set) var arguments: [[String]] = []

    init(forward: Bool = false) { self.forward = forward }

    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        self.arguments.append(arguments)
        if forward {
            return try await SubprocessTransport().run(
                executable: executable, arguments: arguments, environment: environment,
                perStreamOutputLimit: perStreamOutputLimit)
        }
        return TmuxReply(
            standardOutput: [],
            standardError: Array(
                "no server running on /tmp/libtmux-swift-test/layout-bound/socket\n".utf8),
            exitCode: 1)
    }
}
