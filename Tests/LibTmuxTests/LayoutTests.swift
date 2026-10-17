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

    @Test("a 3.8 layout document is judged by structure, and only from its candidates")
    func jsonLayoutsStartAtThreeEight() {
        func pane(_ id: Int) -> String { #"{"t":"p","w":40,"h":24,"x":0,"y":0,"i":\#(id)}"# }
        let split =
            #"{"V":2,"L":{"t":"v","w":80,"h":24,"x":0,"y":0,"c":["#
            + pane(0) + "," + pane(1) + "]}}"
        let single = #"{"V":2,"L":"# + pane(0) + "}"
        let release = TmuxVersion(major: 3, minor: 8)
        #expect(LayoutSyntax.accepts(split, version: release, panes: 2))
        #expect(LayoutSyntax.accepts(single, version: release, panes: 1))
        // Not enough cells, wrong version of the document, a container with
        // no children, an unknown node kind and plain malformed text.
        #expect(!LayoutSyntax.accepts(single, version: release, panes: 2))
        #expect(
            !LayoutSyntax.accepts(
                split.replacingOccurrences(of: #""V":2"#, with: #""V":1"#), version: release,
                panes: 2))
        #expect(!LayoutSyntax.accepts(#"{"V":2,"L":{"t":"v","c":[]}}"#, version: release, panes: 1))
        #expect(!LayoutSyntax.accepts(#"{"V":2,"L":{"t":"x"}}"#, version: release, panes: 1))
        #expect(!LayoutSyntax.accepts("{not json", version: release, panes: 1))
        // Earlier releases refuse the document; the candidates and later builds
        // of 3.8 take it.
        #expect(!LayoutSyntax.accepts(split, version: TmuxVersion(major: 3, minor: 7), panes: 2))
        #expect(!LayoutSyntax.accepts(split, version: TmuxVersion(parsing: "next-3.8")!, panes: 2))
        #expect(LayoutSyntax.accepts(split, version: TmuxVersion(parsing: "3.8-rc2")!, panes: 2))
        #expect(LayoutSyntax.accepts(split, version: TmuxVersion(parsing: "next-3.9")!, panes: 2))
        #expect(acceptsLayoutSyntax(split, panes: 2))
        #expect(!acceptsLayoutSyntax(split, panes: 3))
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
            // A 3.8 document has no checksum to respell.
            let uppercase =
                layout.hasPrefix("{") ? layout : layout.prefix(4).uppercased() + layout.dropFirst(4)
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

    @Test("a layout for a captured window is refused when no version can be read")
    func capturedWindowWithoutVersionIsRefused() async throws {
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
        #expect(!calls.isEmpty)
        #expect(!calls.contains { $0.contains("select-layout") })
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

    @Test(
        "versioned layouts remain on the selected control connection",
        .enabled(if: laneSupportsControl, "control mode needs tmux 3.7"))
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
            // The release was read before the connection opened and is kept
            // for the endpoint, so a closed connection neither answers
            // differently nor spawns a process to find out.
            try await closed.validateLayouts([(layout, 1)])
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
