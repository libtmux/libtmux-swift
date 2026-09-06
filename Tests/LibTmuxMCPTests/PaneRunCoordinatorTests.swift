import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane input reservations", .timeLimit(.minutes(1)))
struct PaneRunCoordinatorTests {
    private func pane(
        _ id: PaneID,
        socketPath: String,
        processID: Int = 42,
        startedAt: Int? = nil
    ) -> Pane {
        return Pane(
            id: id,
            index: 0,
            width: 80,
            height: 24,
            isActive: true,
            isDead: false,
            isInputOff: false,
            modeCount: 0,
            isSynchronized: false,
            currentCommand: "sh",
            currentPath: "/tmp",
            windowID: "@1",
            incarnation: ServerIncarnation(
                endpoint: try! Endpoint(socketPath: socketPath),
                socketPath: socketPath,
                processID: processID,
                startedAt: startedAt ?? processID
            )
        )
    }

    @Test("reservations are atomic, nonqueueing, and token-owned")
    func atomicTokenOwnership() async throws {
        let socket = socketIdentityPath()
        defer { try? FileManager.default.removeItem(atPath: socket) }
        let coordinator = PaneRunCoordinator()
        let first = pane("%1", socketPath: socket)
        let second = pane("%2", socketPath: socket)
        let owner = try #require(await coordinator.reserve([first, second]))

        #expect(await coordinator.reserve([second]) == nil)
        #expect(await coordinator.permits([first, second], owner: owner))
        await coordinator.release(owner)

        let replacement = try #require(await coordinator.reserve([first, second]))
        #expect(!(await coordinator.permits([first, second], owner: owner)))
        await coordinator.release(replacement)
        #expect(!(await coordinator.isHeld(first)))
        #expect(!(await coordinator.isHeld(second)))
    }

    @Test("daemon generations own independent pane reservations")
    func daemonIncarnationAndPaneAreTheReservationKey() async throws {
        let shared = socketIdentityPath()
        let otherPath = socketIdentityPath()
        defer {
            try? FileManager.default.removeItem(atPath: shared)
            try? FileManager.default.removeItem(atPath: otherPath)
        }
        let coordinator = PaneRunCoordinator()
        let original = pane("%1", socketPath: shared, processID: 42)
        let replacement = pane("%1", socketPath: shared, startedAt: 43)
        let otherEndpoint = pane("%1", socketPath: otherPath, processID: 43)
        let owner = try #require(await coordinator.reserve([original]))

        let replacementOwner = try #require(await coordinator.reserve([replacement]))
        let otherOwner = try #require(await coordinator.reserve([otherEndpoint]))
        await coordinator.release(otherOwner)
        await coordinator.release(replacementOwner)
        await coordinator.release(owner)
    }

    private func socketIdentityPath() -> String {
        let path = "/tmp/libtmux-swift-test/coordinator-\(UUID().uuidString)"
        precondition(FileManager.default.createFile(atPath: path, contents: Data()))
        return path
    }

    @Test(
        "physical socket aliases share one pane reservation",
        arguments: SocketAliasKind.allCases
    )
    func physicalSocketAliasesConflict(_ kind: SocketAliasKind) async throws {
        try await withTmuxServer { fixture in
            let original = try #require(try await fixture.panes().first)
            let aliasPath = "\(original.incarnation.socketPath).\(kind.rawValue)"
            switch kind {
            case .symbolic:
                try FileManager.default.createSymbolicLink(
                    atPath: aliasPath,
                    withDestinationPath: original.incarnation.socketPath
                )
            case .hard:
                try FileManager.default.linkItem(
                    atPath: original.incarnation.socketPath,
                    toPath: aliasPath
                )
            }
            defer { try? FileManager.default.removeItem(atPath: aliasPath) }

            let aliasServer = try Server(
                socketPath: aliasPath,
                tmuxExecutable: fixture.tmuxExecutable
            )
            let alias = try #require(try await aliasServer.panes().first)
            #expect(alias.id == original.id)
            #expect(alias.incarnation.processID == original.incarnation.processID)
            #expect(alias.incarnation.startedAt == original.incarnation.startedAt)

            let coordinator = PaneRunCoordinator()
            let owner = try #require(await coordinator.reserve([original]))
            #expect(await coordinator.reserve([alias]) == nil)
            await coordinator.release(owner)
        }
    }

    @Test(
        "send, batch, and paste reserve their dispatch",
        arguments: ReservedInput.allCases
    )
    func toolsReserveDispatch(_ operation: ReservedInput) async throws {
        try await assertReservation(for: operation, through: .dispatch)
    }

    @Test(
        "pane writers reserve before setup and through final preflight",
        arguments: ReservedInput.allCases
    )
    func toolsReserveBeforeDispatch(_ operation: ReservedInput) async throws {
        let checkpoint: InputReservationCheckpoint =
            operation == .paste ? .bufferSetup : .finalPreflight
        try await assertReservation(for: operation, through: checkpoint)
    }

    private func assertReservation(
        for operation: ReservedInput,
        through checkpoint: InputReservationCheckpoint
    ) async throws {
        try await withTmuxServer { fixture in
            let source = try #require(try await fixture.panes().first)
            let peer = try await fixture.split(source, direction: .right)
            for pane in [source, peer] {
                _ = try await fixture.run(
                    TmuxCommand(
                        "set-option",
                        ["-p", "-t", pane.id.rawValue, "synchronize-panes", "on"]
                    )
                )
            }
            let gate = InputDispatchGate()
            let transport = ReservationGateTransport(
                operation: operation,
                checkpoint: checkpoint,
                gate: gate
            )
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.execute]),
                caller: nil
            )
            let first = Task { try await tools.call(operation.call(for: source)) }
            for _ in 0..<200 where !(await gate.isBlocked) {
                try await Task.sleep(for: .milliseconds(5))
            }
            let reachedCheckpoint = await gate.isBlocked
            if !reachedCheckpoint { await gate.open() }

            let competing = operation == .paste ? ReservedInput.send : .paste
            let competingPane = operation == .paste ? source : peer
            let refused: Bool
            do {
                _ = try await tools.call(competing.call(for: competingPane, force: true))
                refused = false
            } catch let error as ToolError {
                refused = error.description.contains("another pane input operation is active")
            }
            await gate.open()
            _ = try await first.value

            #expect(reachedCheckpoint)
            #expect(refused)
            #expect(!(await TmuxTools.paneRuns.isHeld(source)))
            #expect(!(await TmuxTools.paneRuns.isHeld(peer)))
            #expect(
                try await fixture.buffers().contains { $0.name.hasPrefix("libtmux-mcp-") }
                    == false)
        }
    }
}

enum SocketAliasKind: String, CaseIterable, Sendable {
    case symbolic = "symlink"
    case hard = "hardlink"
}

enum ReservedInput: String, CaseIterable, Sendable {
    case send
    case batch
    case paste

    func call(for pane: Pane, force: Bool = false) -> ToolCall {
        let arguments: JSONValue
        switch self {
        case .send:
            arguments = .object([
                "force": .bool(force), "keys": .array([.string("x")]),
                "literal": .bool(true), "paneId": .string(pane.id.rawValue),
            ])
        case .batch:
            arguments = .object([
                "operations": .array([
                    .object([
                        "force": .bool(force), "keys": .array([.string("x")]),
                        "literal": .bool(true), "paneId": .string(pane.id.rawValue),
                    ])
                ])
            ])
        case .paste:
            arguments = .object([
                "force": .bool(force), "paneId": .string(pane.id.rawValue),
                "text": .string("x"),
            ])
        }
        let name =
            switch self {
            case .send: "send_keys"
            case .batch: "send_keys_batch"
            case .paste: "paste_text"
            }
        return ToolCall(name: name, arguments: arguments)
    }
}

private actor InputDispatchGate {
    private(set) var isBlocked = false
    private var isOpen = false

    func block() async {
        isBlocked = true
        while !isOpen { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func open() { isOpen = true }
}

private enum InputReservationCheckpoint: Sendable {
    case bufferSetup
    case finalPreflight
    case dispatch
}

private actor ReservationGateTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let operation: ReservedInput
    private let checkpoint: InputReservationCheckpoint
    private let gate: InputDispatchGate
    private var listPaneCount = 0

    init(
        operation: ReservedInput,
        checkpoint: InputReservationCheckpoint,
        gate: InputDispatchGate
    ) {
        self.operation = operation
        self.checkpoint = checkpoint
        self.gate = gate
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if checkpoint == .finalPreflight, arguments.contains("list-panes") {
            listPaneCount += 1
            if listPaneCount == 2 { await gate.block() }
        } else if checkpoint == .bufferSetup, arguments.contains("set-buffer") {
            await gate.block()
        } else if checkpoint == .dispatch {
            let command = operation == .paste ? "paste-buffer" : "send-keys"
            if arguments.contains(where: { $0.contains(command) }) { await gate.block() }
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}
