import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane echo contract", .hangLimit)
struct PaneEchoContractTests {
    private func tools(_ server: Server) -> TmuxTools {
        TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: [.inspect, .manage, .execute, .teardown]),
            caller: nil
        )
    }

    private func send(_ surface: TmuxTools, _ pane: Pane, _ keys: [String]) async throws {
        _ = try await surface.call(
            ToolCall(
                name: "send_keys",
                arguments: .object([
                    "paneId": .string(pane.id.rawValue), "keys": .array(keys.map(JSONValue.string)),
                ]))
        )
    }

    private func wait(
        _ surface: TmuxTools, _ pane: Pane, _ marker: String, cursor: String? = nil,
        timeout: Int64 = 1_000
    ) async throws -> ToolOutcome {
        var arguments: [String: JSONValue] = [
            "paneId": .string(pane.id.rawValue), "patterns": .array([.string(marker)]),
            "timeoutMs": .integer(timeout),
        ]
        if let cursor { arguments["cursor"] = .string(cursor) }
        return try await surface.call(
            ToolCall(name: "wait_for_text", arguments: .object(arguments)))
    }

    @Test(
        "submitted commands match their output with either cursor order", arguments: [false, true])
    func submittedEcho(cursorBeforeSend: Bool) async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            var cursor: String?
            if cursorBeforeSend {
                let capture = try await surface.call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "paneId": .string(pane.id.rawValue)
                        ]))
                )
                cursor = try #require(capture.structured["cursor"]?.stringValue)
            }
            try await send(surface, pane, ["sleep 0.1; echo MARKER", "Enter"])
            let result = try await wait(surface, pane, "MARKER", cursor: cursor)
            #expect(
                result.structured["matchedLine"]?.stringValue?.trimmingCharacters(in: .whitespaces)
                    == "MARKER")
            #expect(result.structured["matchedAtEntry"]?.boolValue == false)
        }
    }

    @Test("unsubmitted input cannot satisfy a pattern")
    func unsubmittedEcho() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            try await send(surface, pane, ["echo MARKER"])
            let result = try await wait(surface, pane, "MARKER", timeout: 150)
            #expect(result.structured["outcome"]?.stringValue == "timedOut")
            #expect(result.structured["matchedLine"]?.stringValue == nil)
        }
    }

    @Test("editing across calls does not turn echo into output")
    func editedEcho() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            try await send(surface, pane, ["xMARKER"])
            try await send(surface, pane, Array(repeating: "BSpace", count: 7))
            try await send(surface, pane, ["sleep 0.1; echo MARKER", "Enter"])
            let result = try await wait(surface, pane, "MARKER")
            #expect(
                result.structured["matchedLine"]?.stringValue?.trimmingCharacters(in: .whitespaces)
                    == "MARKER")
        }
    }

    @Test("a pasted command can produce output without a newline")
    func noNewline() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            _ = try await surface.call(
                ToolCall(
                    name: "paste_text",
                    arguments: .object([
                        "paneId": .string(pane.id.rawValue),
                        "text": .string("sleep 0.1; printf NO; printf LINE"), "enter": .bool(true),
                    ]))
            )
            let result = try await wait(surface, pane, "NOLINE")
            #expect(result.structured["matchedLine"]?.stringValue?.hasPrefix("NOLINE") == true)
        }
    }

    @Test("input sent before the shell starts is not accepted as output")
    func coldShell() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.respawn(pane, running: ["read gate; PS1='' exec sh"])
            let surface = tools(server)
            try await send(surface, pane, ["echo MARKER", "Enter"])
            let rejected = try await wait(surface, pane, "MARKER", timeout: 150)
            #expect(rejected.structured["outcome"]?.stringValue == "timedOut")
            try await send(surface, pane, ["echo MARKER", "Enter"])
            let result = try await wait(surface, pane, "MARKER")
            #expect(
                result.structured["matchedLine"]?.stringValue?.trimmingCharacters(in: .whitespaces)
                    == "MARKER")
        }
    }

    @Test("discounting preserves the raw matched row")
    func rawMatchedLine() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'y ready\\n'", in: pane)
            let result = try await server.waitForOutput(
                in: pane, matching: [try RegexPattern("ready *$")], timeout: .seconds(1),
                discounting: {
                    OutputWaitDiscount(
                        transform: { PaneEchoMask.mask($0, echoes: ["y"]) },
                        cursorRowUnsettled: false
                    )
                }
            )
            #expect(result.matchedLine?.trimmingCharacters(in: .whitespaces) == "y ready")
        }
    }

    @Test("short pending input does not hide output containing it")
    func shortInput() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            try await send(surface, pane, ["y"])
            let tty = try #require(
                try await server.format("#{pane_tty}", addressing: pane.id.rawValue)
            )
            _ = try await server.run(
                TmuxCommand("run-shell", ["printf '\\r\\nready\\r\\n' > '\(tty)'"])
            )
            let result = try await wait(surface, pane, "ready")
            #expect(
                result.structured["matchedLine"]?.stringValue?.trimmingCharacters(in: .whitespaces)
                    == "ready")
        }
    }

    @Test("unknown editing keys leave current input untracked")
    func unknownKey() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            try await send(surface, pane, ["MARKER", "Left"])
            let result = try await wait(surface, pane, "MARKER")
            #expect(result.structured["matched"]?.stringValue == "MARKER")
        }
    }

    @Test("window reflow preserves real output", arguments: [false, true])
    func resize(resize: Bool) async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            try await send(surface, pane, ["sleep 0.1; echo MARKER", "Enter"])
            if resize {
                _ = try await server.run(
                    TmuxCommand("resize-window", ["-t", pane.windowID.rawValue, "-x", "100"])
                )
            }
            let result = try await wait(surface, pane, "MARKER")
            #expect(
                result.structured["matchedLine"]?.stringValue?.trimmingCharacters(in: .whitespaces)
                    == "MARKER")
        }
    }

    @Test("a dispatch during capture is discounted before matching that capture")
    func dispatchDuringCapture() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let command = fixture.shellInvocation
            try await fixture.respawn(
                pane,
                running: [
                    "printf '\\033c'; \(command) wait-for -S echo-ready; "
                        + "\(command) wait-for echo-start; "
                        + "printf 'ECHO_TARGET\\nOUTPUT_DONE\\n'; "
                        + "\(command) wait-for -S echo-done; "
                        + "\(command) wait-for echo-release"
                ]
            )
            try await fixture.wait(for: "echo-ready")
            let cursor = try await fixture.capture(pane, since: nil).cursor
            let echoes = PaneEchoes()
            let key = PaneEchoes.Key(incarnation: pane.incarnation, pane: pane.id)
            let wait = PaneEchoes.Wait(key: key, source: echoes)
            let transport = EchoCaptureTransport {
                let update = await echoes.apply(.literal(["ECHO_TARGET"], enter: true), to: [key])
                await echoes.commit(update)
                try await fixture.signal("echo-start")
                try await fixture.wait(for: "echo-done")
            }
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )

            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("ECHO_TARGET"), try RegexPattern("OUTPUT_DONE")],
                requiringFreshOutput: true,
                startingAt: cursor,
                timeout: .seconds(1),
                discounting: { await wait.discount() }
            )

            #expect(result.outcome == .matched)
            #expect(result.matchedIndex == 1)
            #expect(result.matchedLine?.trimmingCharacters(in: .whitespaces) == "OUTPUT_DONE")
            #expect(
                result.tail.contains { $0.trimmingCharacters(in: .whitespaces) == "ECHO_TARGET" })
            try await fixture.signal("echo-release")
        }
    }
}

private actor EchoCaptureTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private var beforeCapture: (@Sendable () async throws -> Void)?

    init(_ beforeCapture: @escaping @Sendable () async throws -> Void) {
        self.beforeCapture = beforeCapture
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains(where: { $0.contains("capture-pane") }), let action = beforeCapture {
            beforeCapture = nil
            do { try await action() } catch let error as TmuxError { throw error } catch {
                throw .invocationFailed(reason: String(describing: error))
            }
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}
