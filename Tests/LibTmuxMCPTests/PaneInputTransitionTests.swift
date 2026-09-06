import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane input transitions", .timeLimit(.minutes(2)))
struct PaneInputTransitionTests {
    @Test("run rechecks once after setup and refuses every observed transition")
    func runRefusesPostSetupTransitions() async throws {
        for mutation in TransitionMutation.allCases where mutation != .none {
            try await withTmuxServer { fixture in
                let source = try #require(try await fixture.panes().first)
                let peer = try await fixture.split(source, direction: .right)
                let session = try #require(try await fixture.sessions().first)
                let transport = TransitionTransport(
                    fixture: fixture,
                    source: source,
                    peer: peer,
                    mutation: mutation
                )
                let server = Server(
                    endpoint: fixture.endpoint,
                    tmuxExecutable: fixture.tmuxExecutable,
                    transport: transport
                )
                let caller: CallerIdentity?
                if mutation == .callerJoins {
                    let incarnation = try await fixture.incarnation()
                    caller = CallerIdentity(
                        paneID: peer.id,
                        sessionID: session.id,
                        socketPath: incarnation.socketPath,
                        serverProcessID: incarnation.processID
                    )
                } else {
                    caller = nil
                }
                let tools = TmuxTools(
                    server: server,
                    authority: ToolAuthority(toolsets: [.execute]),
                    caller: caller
                )
                let marker = "transition-must-not-dispatch-\(mutation.rawValue)"
                do {
                    _ = try await tools.call(
                        ToolCall(
                            name: "run_shell_command",
                            arguments: .object([
                                "command": .string("/usr/bin/printf '\(marker)\\n'"),
                                "paneId": .string(source.id.rawValue),
                                "timeoutMs": .integer(2_000),
                            ])
                        )
                    )
                    Issue.record("\(mutation.rawValue) was accepted")
                } catch let error as ToolError {
                    #expect(
                        error.description.contains(
                            "run_shell_command pane state changed after setup; no input was sent"
                        ),
                        Comment(rawValue: "\(mutation.rawValue): \(error)")
                    )
                }

                #expect(await transport.listPaneCount == 2, Comment(rawValue: mutation.rawValue))
                #expect(
                    await transport.inputDispatchCount == 0, Comment(rawValue: mutation.rawValue))
                #expect(await transport.waitCount == 0, Comment(rawValue: mutation.rawValue))
                #expect(!(await TmuxTools.paneRuns.isHeld(source)))
                let surviving = try await fixture.panes()
                for pane in surviving {
                    #expect(
                        try await fixture.capture(pane).contains { $0.contains(marker) } == false,
                        Comment(rawValue: mutation.rawValue)
                    )
                }
                let options = try await fixture.run(
                    TmuxCommand("show-options", ["-p", "-t", surviving[0].id.rawValue])
                )
                #expect(!options.text.contains("@libtmux_mcp_"))
            }
        }
    }

    @Test("an initial mode refusal precedes run setup")
    func initialModeRefusalPrecedesSetup() async throws {
        try await withTmuxServer { fixture in
            let source = try #require(try await fixture.panes().first)
            try await fixture.enterCopyMode(source)
            let transport = TransitionTransport(
                fixture: fixture,
                source: source,
                peer: source,
                mutation: .none
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

            await #expect(throws: ToolError.self) {
                _ = try await tools.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string("true"),
                            "paneId": .string(source.id.rawValue),
                        ])
                    )
                )
            }
            #expect(await transport.listPaneCount == 1)
            #expect(await transport.captureCount == 0)
            #expect(await transport.inputDispatchCount == 0)
            #expect(!(await TmuxTools.paneRuns.isHeld(source)))
        }
    }

    @Test("paste rechecks after staging and removes its private buffer on refusal")
    func pasteTransitionCleansBuffer() async throws {
        try await withTmuxServer { fixture in
            let source = try #require(try await fixture.panes().first)
            let transport = TransitionTransport(
                fixture: fixture,
                source: source,
                peer: source,
                mutation: .mode
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

            do {
                _ = try await tools.call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "enter": .bool(true),
                            "paneId": .string(source.id.rawValue),
                            "text": .string("paste-must-not-dispatch"),
                        ])
                    )
                )
                Issue.record("paste transition was accepted")
            } catch let error as ToolError {
                #expect(
                    error.description.contains(
                        "paste_text pane state changed after setup; no input was sent"
                    )
                )
            }
            #expect(await transport.listPaneCount == 2)
            #expect(await transport.pasteDispatchCount == 0)
            #expect(!(await TmuxTools.paneRuns.isHeld(source)))
            #expect(
                try await fixture.buffers().contains { $0.name.hasPrefix("libtmux-mcp-") } == false)
            #expect(
                try await fixture.capture(source).contains {
                    $0.contains("paste-must-not-dispatch")
                }
                    == false
            )
        }
    }
}

private enum TransitionMutation: String, CaseIterable, Sendable {
    case mode
    case dead
    case shell
    case cohortWidens
    case callerJoins
    case clientAttends
    case sourceDisappears
    case none
}

private actor TransitionTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let fixture: Server
    private let source: Pane
    private let peer: Pane
    private let mutation: TransitionMutation
    private(set) var listPaneCount = 0
    private(set) var inputDispatchCount = 0
    private(set) var pasteDispatchCount = 0
    private(set) var waitCount = 0
    private(set) var captureCount = 0

    init(
        fixture: Server,
        source: Pane,
        peer: Pane,
        mutation: TransitionMutation
    ) {
        self.fixture = fixture
        self.source = source
        self.peer = peer
        self.mutation = mutation
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let commandLine = arguments.joined(separator: " ")
        if arguments.contains("list-panes") {
            listPaneCount += 1
            if listPaneCount == 2 { try await mutate() }
        }
        if commandLine.contains("send-keys") { inputDispatchCount += 1 }
        if commandLine.contains("paste-buffer") { pasteDispatchCount += 1 }
        if arguments.contains("wait-for") { waitCount += 1 }
        if commandLine.contains("capture-pane") { captureCount += 1 }
        let reply = try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
        if arguments.contains("list-clients"), listPaneCount == 2,
            mutation == .clientAttends
        {
            return try await attendedClientReply()
        }
        return reply
    }

    private func mutate() async throws(TmuxError) {
        switch mutation {
        case .mode:
            try await fixture.enterCopyMode(source)
        case .dead:
            _ = try await fixture.run(
                TmuxCommand("set-option", ["-p", "-t", source.id.rawValue, "remain-on-exit", "on"])
            )
            try await fixture.respawn(source, running: ["false"])
            try await waitForFormat("#{pane_dead}", toEqual: "1")
        case .shell:
            try await fixture.respawn(source, running: ["sleep", "30"])
            try await waitForFormat("#{pane_current_command}", toEqual: "sleep")
        case .cohortWidens, .callerJoins:
            for pane in [source, peer] {
                _ = try await fixture.run(
                    TmuxCommand(
                        "set-option",
                        ["-p", "-t", pane.id.rawValue, "synchronize-panes", "on"]
                    )
                )
            }
        case .sourceDisappears:
            try await fixture.kill(source)
        case .clientAttends, .none:
            break
        }
    }

    private func attendedClientReply() async throws(TmuxError) -> TmuxReply {
        guard let session = try await fixture.sessions().first else {
            throw .invocationFailed(reason: "fixture session disappeared")
        }
        let values = [
            "client_name": "/dev/pts/libtmux-test",
            "client_tty": "/dev/pts/libtmux-test",
            "client_pid": "77",
            "client_width": "80",
            "client_height": "24",
            "client_control_mode": "0",
            "session_id": session.id.rawValue,
            "pane_id": source.id.rawValue,
            "window_zoomed_flag": "1",
            "socket_path": source.incarnation.socketPath,
            "pid": String(source.incarnation.processID),
            "start_time": String(source.incarnation.startedAt),
        ]
        let separator = String(FormatProjection.separator)
        let row = Client.projection.fields.map { values[$0.name] ?? "" }
            .joined(separator: separator)
        return TmuxReply(
            standardOutput: Array("\(row)\n".utf8),
            standardError: [],
            exitCode: 0
        )
    }

    private func waitForFormat(_ format: String, toEqual expected: String) async throws(TmuxError) {
        for _ in 0..<100 {
            if try await fixture.format(format, addressing: source.id.rawValue) == expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw .invocationFailed(reason: "transition did not settle")
    }
}
