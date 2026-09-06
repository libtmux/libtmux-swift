import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane input reservations", .timeLimit(.minutes(1)))
struct PaneRunCoordinatorTests {
    private func pane(_ id: PaneID, processID: Int = 42, socket: String = "shared") -> Pane {
        let path = "/tmp/libtmux-swift-test/\(socket)"
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
                endpoint: try! Endpoint(socketPath: path),
                socketPath: path,
                processID: processID,
                startedAt: processID
            )
        )
    }

    @Test("reservations are atomic, nonqueueing, and token-owned")
    func atomicTokenOwnership() async throws {
        let coordinator = PaneRunCoordinator()
        let first = pane("%1")
        let second = pane("%2")
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

    @Test("one endpoint and pane stay reserved across daemon replacement")
    func endpointAndPaneAreTheReservationKey() async throws {
        let coordinator = PaneRunCoordinator()
        let original = pane("%1", processID: 42)
        let replacement = pane("%1", processID: 43)
        let otherEndpoint = pane("%1", processID: 43, socket: "other")
        let owner = try #require(await coordinator.reserve([original]))

        #expect(await coordinator.reserve([replacement]) == nil)
        let other = try #require(await coordinator.reserve([otherEndpoint]))
        await coordinator.release(other)
        await coordinator.release(owner)
    }

    @Test(
        "send, batch, and paste reserve their dispatch",
        arguments: ReservedInput.allCases
    )
    func toolsReserveDispatch(_ operation: ReservedInput) async throws {
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
            let transport = BlockingInputTransport(operation: operation, gate: gate)
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
            let reachedDispatch = await gate.isBlocked

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

            #expect(reachedDispatch)
            #expect(refused)
            #expect(!(await TmuxTools.paneRuns.isHeld(source)))
            #expect(!(await TmuxTools.paneRuns.isHeld(peer)))
            #expect(
                try await fixture.buffers().contains { $0.name.hasPrefix("libtmux-mcp-") }
                    == false)
        }
    }
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

private actor BlockingInputTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let operation: ReservedInput
    private let gate: InputDispatchGate

    init(operation: ReservedInput, gate: InputDispatchGate) {
        self.operation = operation
        self.gate = gate
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let command = operation == .paste ? "paste-buffer" : "send-keys"
        if arguments.contains(where: { $0.contains(command) }) { await gate.block() }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}
