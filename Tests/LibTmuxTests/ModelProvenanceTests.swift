import Testing

@testable import LibTmux

@Suite("model provenance")
struct ModelProvenanceTests {
    @Test(
        "foreign endpoints fail before invoking tmux",
        arguments: ModelOperation.all
    )
    func foreignEndpointsFailBeforeTmux(operation: ModelOperation) async throws {
        let local = try ProvenanceFixture(path: "local")
        let foreign = try ProvenanceFixture(path: "foreign")
        let transport = GuardProbeTransport(expected: local.values.incarnation)
        let server = Server(endpoint: local.endpoint, transport: transport)

        await #expect(throws: TmuxError.foreignServerValue) {
            try await operation.call(server, foreign.values)
        }
        #expect(await transport.invocationCount == 0)
    }

    @Test(
        "mutations use a queued incarnation guard",
        arguments: ModelOperation.mutations
    )
    func mutationsUseQueuedGuard(operation: ModelOperation) async throws {
        let fixture = try ProvenanceFixture(path: "guarded")
        let transport = GuardProbeTransport(expected: fixture.values.incarnation)
        let server = Server(endpoint: fixture.endpoint, transport: transport)

        await #expect(throws: TmuxError.serverRestarted) {
            try await operation.call(server, fixture.values)
        }
        #expect(await transport.guardedRequestCount == 1)
        #expect(await transport.unguardedMutationCount == 0)
    }

    @Test(
        "reads use a queued incarnation guard",
        arguments: ModelOperation.reads
    )
    func readsUseQueuedGuard(operation: ModelOperation) async throws {
        let fixture = try ProvenanceFixture(path: "read")
        let transport = GuardProbeTransport(expected: fixture.values.incarnation)
        let server = Server(endpoint: fixture.endpoint, transport: transport)

        await #expect(throws: TmuxError.serverRestarted) {
            try await operation.call(server, fixture.values)
        }
        #expect(await transport.invocationCount == 1)
        #expect(await transport.guardedRequestCount == 1)
    }

    @Test("a local no-op does not probe provenance")
    func localNoOpDoesNotProbeProvenance() async throws {
        let local = try ProvenanceFixture(path: "noop-local")
        let foreign = try ProvenanceFixture(path: "noop-foreign")
        let transport = GuardProbeTransport(expected: local.values.incarnation)
        let server = Server(endpoint: local.endpoint, transport: transport)

        try await server.resize(foreign.values.pane)

        #expect(await transport.invocationCount == 0)
    }

    @Test("guard markers preserve arbitrary action bytes")
    func guardMarkersPreserveArbitraryActionBytes() throws {
        let fixture = try ProvenanceFixture(path: "bytes")
        let request = GuardedRequest(
            command: TmuxCommand("display-message", ["-p", "held"]),
            incarnation: fixture.values.incarnation,
            targets: []
        )
        let base = request.fenceMarker.dropLast("_fence".count)
        let trueMarker = "\(base)_true"
        let actionBytes: [UInt8] = [0xff, 0x0a, 0xfe, 0x00, 0x0a]
        let reply = TmuxReply(
            standardOutput: actionBytes + Array("\(trueMarker)\n\(request.fenceMarker)\n".utf8),
            standardError: [],
            exitCode: 0
        )

        let validated = try request.validate(reply)

        #expect(validated.standardOutput == actionBytes)
    }
}

struct ModelOperation: Sendable, CustomStringConvertible {
    enum Kind: Sendable { case mutation, read }

    let name: String
    let kind: Kind
    let call: @Sendable (Server, ProvenanceValues) async throws -> Void
    var description: String { name }

    static let all: [ModelOperation] = [
        mutation("newWindowInSession") { s, v in _ = try await s.newWindow(in: v.session) },
        mutation("newWindowBesideWindow") { s, v in
            _ = try await s.newWindow(.after, v.windowLink)
        },
        mutation("splitWindow") { s, v in _ = try await s.splitWindow(v.window) },
        mutation("splitPane") { s, v in _ = try await s.split(v.pane) },
        mutation("renameSession") { s, v in try await s.rename(v.session, to: "renamed") },
        mutation("renameWindow") { s, v in try await s.rename(v.window, to: "renamed") },
        mutation("selectLayout") { s, v in try await s.selectLayout(v.window, "tiled") },
        mutation("resizePane") { s, v in try await s.resize(v.pane, width: 72) },
        mutation("resizePaneByCells") { s, v in
            try await s.resize(v.pane, by: 1, toward: .up)
        },
        mutation("killSession") { s, v in try await s.kill(v.session) },
        mutation("killWindow") { s, v in try await s.kill(v.window) },
        mutation("killPane") { s, v in try await s.kill(v.pane) },
        mutation("sendKeys") { s, v in
            try await s.sendKeys(["x"], to: v.pane, literally: true)
        },
        mutation("runInPane") { s, v in try await s.run("true", in: v.pane) },
        mutation("selectWindow") { s, v in try await s.select(v.windowLink) },
        mutation("selectPane") { s, v in try await s.select(v.pane) },
        mutation("selectNextWindow") { s, v in
            try await s.selectNextWindow(in: v.session)
        },
        mutation("selectPreviousWindow") { s, v in
            try await s.selectPreviousWindow(in: v.session)
        },
        mutation("selectLastWindow") { s, v in
            try await s.selectLastWindow(in: v.session)
        },
        mutation("selectLastPane") { s, v in try await s.selectLastPane(in: v.window) },
        mutation("swapWindows") { s, v in
            try await s.swap(v.windowLink, with: v.otherWindowLink)
        },
        mutation("swapPanes") { s, v in try await s.swap(v.pane, with: v.otherPane) },
        mutation("rotateWindow") { s, v in try await s.rotate(v.window) },
        mutation("nextLayout") { s, v in try await s.nextLayout(v.window) },
        mutation("previousLayout") { s, v in try await s.previousLayout(v.window) },
        mutation("breakPane") { s, v in
            _ = try await s.breakPane(v.pane, from: v.windowLink)
        },
        mutation("joinPane") { s, v in try await s.join(v.pane, into: v.window) },
        mutation("clearHistory") { s, v in try await s.clearHistory(v.pane) },
        mutation("setPaneTitle") { s, v in try await s.setTitle("held", of: v.pane) },
        mutation("pasteBuffer") { s, v in try await s.paste(into: v.pane) },
        mutation("detachClient") { s, v in try await s.detach(v.client) },
        mutation("detachClients") { s, v in try await s.detachClients(from: v.session) },
        mutation("respawnPane") { s, v in try await s.respawn(v.pane) },
        mutation("respawnWindow") { s, v in try await s.respawn(v.window) },
        mutation("pipePane") { s, v in try await s.pipe(v.pane) },
        mutation("moveWindow") { s, v in
            _ = try await s.move(v.windowLink, to: v.otherSession)
        },
        mutation("linkWindow") { s, v in
            _ = try await s.link(v.window, into: v.session)
        },
        mutation("setWindowOption") { s, v in
            _ = try await s.setOption(
                "automatic-rename", to: "off", scope: .window(v.window))
        },
        read("formatSession") { s, v in
            _ = try await s.format("#{session_name}", for: v.session)
        },
        read("formatWindow") { s, v in
            _ = try await s.format("#{window_name}", for: v.windowLink)
        },
        read("formatPane") { s, v in
            _ = try await s.format("#{pane_id}", for: v.pane, through: v.windowLink)
        },
        read("readWindowOption") { s, v in
            _ = try await s.option("automatic-rename", scope: .window(v.window))
        },
        read("capturePane") { s, v in _ = try await s.capture(v.pane) },
        read("capturePaneIncrementally") { s, v in
            _ = try await s.capture(v.pane, since: nil)
        },
        read("waitForPaneOutput") { s, v in
            do {
                _ = try await s.waitForOutput(in: v.pane, timeout: .zero)
            } catch let waitError as OutputWaitError {
                if case let .tmux(error) = waitError { throw error }
                throw waitError
            }
        },
    ]

    static var mutations: [ModelOperation] { all.filter { $0.kind == .mutation } }
    static var reads: [ModelOperation] { all.filter { $0.kind == .read } }

    private static func mutation(
        _ name: String,
        _ call: @escaping @Sendable (Server, ProvenanceValues) async throws -> Void
    ) -> ModelOperation {
        ModelOperation(name: name, kind: .mutation, call: call)
    }

    private static func read(
        _ name: String,
        _ call: @escaping @Sendable (Server, ProvenanceValues) async throws -> Void
    ) -> ModelOperation {
        ModelOperation(name: name, kind: .read, call: call)
    }
}

private struct ProvenanceFixture {
    let endpoint: Endpoint
    let values: ProvenanceValues

    init(path: String) throws {
        let socketPath = "/tmp/libtmux-swift-test/provenance-\(path)"
        endpoint = try Endpoint(socketPath: socketPath)
        values = ProvenanceValues(
            incarnation: ServerIncarnation(
                endpoint: endpoint,
                socketPath: socketPath,
                processID: 101,
                startedAt: 1_700_000_000
            )
        )
    }
}

struct ProvenanceValues: Sendable {
    let incarnation: ServerIncarnation
    let session: Session
    let otherSession: Session
    let window: Window
    let otherWindow: Window
    let windowLink: WindowLink
    let otherWindowLink: WindowLink
    let pane: Pane
    let otherPane: Pane
    let client: Client

    init(incarnation: ServerIncarnation) {
        self.incarnation = incarnation
        session = Session(
            id: "$1", name: "held", windowCount: 2, isAttached: true,
            createdAt: 1_700_000_001, incarnation: incarnation
        )
        otherSession = Session(
            id: "$2", name: "other", windowCount: 1, isAttached: false,
            createdAt: 1_700_000_002, incarnation: incarnation
        )
        window = Window(
            id: "@1", name: "held", paneCount: 2, width: 80, height: 24,
            incarnation: incarnation
        )
        otherWindow = Window(
            id: "@2", name: "other", paneCount: 1, width: 80, height: 24,
            incarnation: incarnation
        )
        windowLink = WindowLink(
            sessionID: "$1", windowID: "@1", index: 0, isActive: true,
            incarnation: incarnation
        )
        otherWindowLink = WindowLink(
            sessionID: "$1", windowID: "@2", index: 1, isActive: false,
            incarnation: incarnation
        )
        pane = Self.pane(id: "%1", index: 0, active: true, incarnation: incarnation)
        otherPane = Self.pane(id: "%2", index: 1, active: false, incarnation: incarnation)
        client = Client(
            name: "/dev/pts/provenance", tty: "/dev/pts/provenance", processID: 303,
            width: 80, height: 24, isControlMode: false, sessionID: "$1",
            incarnation: incarnation
        )
    }

    private static func pane(
        id: PaneID,
        index: Int,
        active: Bool,
        incarnation: ServerIncarnation
    ) -> Pane {
        Pane(
            id: id, index: index, width: 80, height: 12, isActive: active,
            currentCommand: "sh", currentPath: "/tmp", windowID: "@1",
            incarnation: incarnation
        )
    }
}

private actor GuardProbeTransport: ProcessTransport {
    let expected: ServerIncarnation
    private(set) var invocationCount = 0
    private(set) var guardedRequestCount = 0
    private(set) var unguardedMutationCount = 0

    init(expected: ServerIncarnation) { self.expected = expected }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        invocationCount += 1
        switch arguments.dropFirst(3).first {
        case "display-message":
            return incarnationReply()
        case "list-windows":
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        case "list-clients":
            return clientReply()
        case "if-shell":
            guardedRequestCount += 1
            guard let fence = arguments.first(where: { $0.hasSuffix("_fence") }) else {
                throw .invocationFailed(reason: "guarded request has no final marker")
            }
            let restarted = String(fence.dropLast("_fence".count)) + "_restarted"
            return TmuxReply(
                standardOutput: Array("\(restarted)\n\(fence)\n".utf8),
                standardError: [],
                exitCode: 0
            )
        default:
            unguardedMutationCount += 1
            throw .invocationFailed(reason: "model operation was sent without a queue guard")
        }
    }

    private func incarnationReply() -> TmuxReply {
        reply([
            expected.socketPath, String(expected.processID), String(expected.startedAt),
        ])
    }

    private func clientReply() -> TmuxReply {
        reply([
            "/dev/pts/provenance", "/dev/pts/provenance", "303", "80", "24", "0", "$1",
            expected.socketPath, String(expected.processID), String(expected.startedAt),
        ])
    }

    private func reply(_ fields: [String]) -> TmuxReply {
        let row = fields.joined(separator: String(FormatProjection.separator))
        return TmuxReply(
            standardOutput: Array("\(row)\n".utf8),
            standardError: [],
            exitCode: 0
        )
    }
}
