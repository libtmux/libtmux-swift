import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

private actor RecordedProtocolLines {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@Suite("retained MCP behavior", .timeLimit(.minutes(2)))
struct RetainedMCPBehaviorTests {
    private func tools(_ server: Server) -> TmuxTools {
        TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: [.inspect, .manage, .execute, .teardown]),
            caller: nil
        )
    }

    private func withProbeServer(
        _ body: (
            _ fixture: Server,
            _ server: Server,
            _ pane: Pane,
            _ transport: RetainedProbeFailureTransport
        ) async throws -> Void
    ) async throws {
        try await withTmuxServer { fixture in
            let transport = RetainedProbeFailureTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try #require(try await server.panes().first)
            try await body(fixture, server, pane, transport)
        }
    }

    private func expectReleased(_ pane: Pane) async throws {
        #expect(
            try await waitUntil {
                !(await TmuxTools.paneRuns.isHeld(pane))
            }
        )
    }

    private func retainRun(
        on pane: Pane,
        using server: Server,
        controlledBy fixture: Server,
        interruption: RetainedRunInterruption,
        beforeInterruption: (@Sendable () async throws -> Void)? = nil
    ) async throws -> String {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let started = "libtmux-swift-run-started-\(nonce)"
        let release = "libtmux-swift-run-release-\(nonce)"
        let tmux = fixture.shellInvocation
        let running = Task {
            try await tools(server).call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string(
                            "\(tmux) wait-for -S \(started); "
                                + "\(tmux) wait-for \(release)"
                        ),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(interruption == .timeout ? 2_000 : 20_000),
                    ])
                )
            )
        }

        try await fixture.wait(for: started)
        try await beforeInterruption?()
        switch interruption {
        case .cancel:
            running.cancel()
            await #expect(throws: ToolError.tmux(.cancelled)) {
                _ = try await running.value
            }
        case .timeout:
            let outcome = try await running.value
            #expect(outcome.structured["timedOut"]?.boolValue == true)
        }
        #expect(await TmuxTools.paneRuns.isHeld(pane))
        return release
    }

    @Test("protocol preserves ids and distinguishes malformed, invalid, and notifications")
    func protocolPreservesIDsAndErrors() async throws {
        let handler = MCPRequestHandler(
            tools: TmuxTools(
                server: try Server(
                    socketPath: "/tmp/libtmux-swift-test/protocol-retained-unstarted"),
                authority: ToolAuthority(toolsets: [.inspect]),
                caller: nil
            )
        )
        let cases: [(String, JSONValue)] = [
            (#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#, .integer(7)),
            (
                #"{"jsonrpc":"2.0","id":9223372036854775808,"method":"ping"}"#,
                .unsignedInteger(9_223_372_036_854_775_808)
            ),
            (#"{"jsonrpc":"2.0","id":"request-seven","method":"ping"}"#, .string("request-seven")),
        ]
        for (request, expectedID) in cases {
            let response = try #require(await handler.respond(to: request))
            let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
            #expect(decoded["id"] == expectedID)
            #expect(decoded["result"] == .object([:]))
        }

        let malformed = try #require(await handler.respond(to: "{"))
        let malformedValue = try JSONDecoder().decode(
            JSONValue.self, from: Data(malformed.utf8))
        #expect(malformedValue["id"]?.isNull == true)
        #expect(malformedValue["error"]?["code"]?.intValue == -32700)

        let invalid = try #require(
            await handler.respond(to: #"{"jsonrpc":"1.0","id":9,"method":"ping"}"#)
        )
        let invalidValue = try JSONDecoder().decode(JSONValue.self, from: Data(invalid.utf8))
        #expect(invalidValue["id"]?.isNull == true)
        #expect(invalidValue["error"]?["code"]?.intValue == -32600)
        #expect(await handler.respond(to: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil)
    }

    @Test("an oversized request id is rejected before tool dispatch")
    func oversizedRequestIdFailsBeforeDispatch() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/oversized-id-\(UUID().uuidString)"
        )
        let handler = MCPRequestHandler(tools: tools(server))
        let identifier = String(repeating: "i", count: 1_000_000)
        let requestValue: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .string(identifier),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("create_session"),
                "arguments": .object(["name": .string("must-not-exist")]),
            ]),
        ])
        let request = String(
            decoding: try JSONEncoder().encode(requestValue),
            as: UTF8.self
        )

        let response = await handler.respond(to: request)
        let running = try await server.isRunning()
        if running { try? await server.killServer() }

        let reply = try #require(response)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
        #expect(decoded["id"]?.isNull == true)
        #expect(decoded["error"]?["code"]?.intValue == -32600)
        #expect(reply.utf8.count + 1 <= MCPRequestHandler.maximumResponseBytes)
        #expect(!running)
    }

    @Test("service cancellation stops a wait without answering it")
    func serviceCancellationStopsWait() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let service = MCPService(handler: MCPRequestHandler(tools: tools(server)))
            let answers = RecordedProtocolLines()
            let started = ContinuousClock.now
            let lines = AsyncStream<String> { continuation in
                continuation.yield(
                    #"{"jsonrpc":"2.0","id":"wait","method":"tools/call","params":{"name":"wait_for_text","arguments":{"paneId":"\#(pane.id.rawValue)","patterns":["never-arrives"],"timeoutMs":4000}}}"#
                )
                continuation.yield(
                    #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"wait"}}"#
                )
                continuation.finish()
            }

            await service.serve(lines) { await answers.append($0) }

            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(await answers.values.isEmpty)
        }
    }

    @Test("request capacity includes a response waiting on backpressure")
    func requestCapacityIncludesPendingWrite() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/service-capacity-unstarted")
        let service = MCPService(
            handler: MCPRequestHandler(
                tools: TmuxTools(
                    server: server,
                    authority: ToolAuthority(toolsets: [.inspect]),
                    caller: nil
                )
            ),
            maximumInFlightRequests: 1
        )
        let answers = RecordedProtocolLines()
        let (lines, input) = AsyncStream<String>.makeStream()
        input.yield(#"{"jsonrpc":"2.0","id":"first","method":"ping"}"#)

        await service.serve(lines) { line in
            if line.contains(#""id":"first""#) {
                input.yield(#"{"jsonrpc":"2.0","id":"second","method":"ping"}"#)
                input.finish()
                try? await Task.sleep(for: .milliseconds(100))
            }
            await answers.append(line)
        }

        let decoded = try await answers.values.map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        let second = try #require(decoded.first { $0["id"] == .string("second") })
        #expect(second["error"]?["code"]?.intValue == -32000)
    }

    @Test("a cancelled pane command blocks all input until it finishes")
    func cancelledRunKeepsPaneLease() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let started = "libtmux-swift-run-started-\(nonce)"
            let release = "libtmux-swift-run-release-\(nonce)"
            let tmux = server.shellInvocation
            let running = Task {
                try await surface.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string(
                                "\(tmux) wait-for -S \(started); "
                                    + "\(tmux) wait-for \(release); "
                                    + "printf 'cancelled-command-finished\\n'"
                            ),
                            "paneId": .string(pane.id.rawValue),
                            "timeoutMs": .integer(20_000),
                        ])
                    )
                )
            }

            try await server.wait(for: started)
            running.cancel()
            await #expect(throws: ToolError.tmux(.cancelled)) {
                _ = try await running.value
            }
            #expect(await TmuxTools.paneRuns.isHeld(pane))
            let refusedAt = ContinuousClock.now
            await #expect(throws: ToolError.self) {
                _ = try await surface.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string("printf 'must-not-overlap\\n'"),
                            "paneId": .string(pane.id.rawValue),
                            "timeoutMs": .integer(20_000),
                        ])
                    )
                )
            }
            #expect(ContinuousClock.now - refusedAt < .seconds(1))

            for name in ["send_keys", "paste_text"] {
                let arguments: JSONValue =
                    name == "send_keys"
                    ? .object([
                        "force": .bool(true), "keys": .array([.string("must-not-overlap")]),
                        "literal": .bool(true), "paneId": .string(pane.id.rawValue),
                    ])
                    : .object([
                        "force": .bool(true), "paneId": .string(pane.id.rawValue),
                        "text": .string("must-not-overlap"),
                    ])
                await #expect(throws: ToolError.self) {
                    _ = try await surface.call(ToolCall(name: name, arguments: arguments))
                }
            }
            let batch = try await surface.call(
                ToolCall(
                    name: "send_keys_batch",
                    arguments: .object([
                        "operations": .array([
                            .object([
                                "force": .bool(true),
                                "keys": .array([.string("must-not-overlap")]),
                                "literal": .bool(true),
                                "paneId": .string(pane.id.rawValue),
                            ])
                        ])
                    ])
                )
            )
            #expect(batch.structured["completed"]?.intValue == 0)
            #expect(batch.structured["failures"]?.arrayValue?.count == 1)
            #expect(
                try await server.buffers().contains { $0.name.hasPrefix("libtmux-mcp-") }
                    == false)

            try await server.signal(release)
            #expect(
                try await waitUntil {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                }
            )
            let after = try await surface.call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("printf 'after-cleanup\\n'"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(5_000),
                    ])
                )
            )
            #expect(after.structured["exitStatus"]?.intValue == 0)
            #expect(
                after.structured["output"]?.arrayValue?.compactMap(\.stringValue)
                    .contains("after-cleanup") == true
            )
        }
    }

    @Test(
        "an ambiguous retained-run probe keeps the pane lease",
        arguments: RetainedRunInterruption.allCases,
        RetainedProbeFailure.allCases
    )
    func ambiguousRunProbeKeepsPaneLease(
        _ interruption: RetainedRunInterruption,
        _ failure: RetainedProbeFailure
    ) async throws {
        try await withProbeServer { fixture, server, pane, transport in
            let release = try await retainRun(
                on: pane,
                using: server,
                controlledBy: fixture,
                interruption: interruption
            )

            await transport.arm(failure)
            #expect(try await waitUntil { await transport.failureWasInjected })
            try await Task.sleep(for: .milliseconds(200))
            #expect(await TmuxTools.paneRuns.isHeld(pane))

            try await fixture.signal(release)
            try await expectReleased(pane)
        }
    }

    @Test("a status-less completion signal keeps the pane lease")
    func statuslessCompletionSignalKeepsPaneLease() async throws {
        try await withProbeServer { fixture, server, pane, transport in
            await transport.returnFirstWaitEarly()
            let beforeInterruption: @Sendable () async throws -> Void = {
                let returned = try await waitUntil {
                    await transport.earlyWaitReturned
                }
                #expect(returned)
                try await Task.sleep(for: .milliseconds(100))
            }
            let release = try await retainRun(
                on: pane,
                using: server,
                controlledBy: fixture,
                interruption: .cancel,
                beforeInterruption: beforeInterruption
            )

            #expect(try await waitUntil { await transport.earlyWaitReturned })
            try await Task.sleep(for: .milliseconds(200))
            #expect(await TmuxTools.paneRuns.isHeld(pane))

            try await fixture.signal(release)
            try await expectReleased(pane)
        }
    }

    @Test(
        "a noncanonical retained status keeps the pane lease",
        arguments: ["01", "+1", "١", "256"]
    )
    func noncanonicalRetainedStatusKeepsPaneLease(_ status: String) async throws {
        try await withProbeServer { fixture, server, pane, transport in
            await transport.overrideRetainedStatus(with: status)
            let release = try await retainRun(
                on: pane,
                using: server,
                controlledBy: fixture,
                interruption: .cancel
            )

            try await fixture.signal(release)
            #expect(try await waitUntil { await transport.statusOverrideWasReturned })
            try await Task.sleep(for: .milliseconds(200))
            let retained = await TmuxTools.paneRuns.isHeld(pane)
            await transport.allowRealStatus()
            #expect(retained)
            try await expectReleased(pane)
        }
    }

    @Test(
        "a retained run releases only after authenticated disappearance",
        arguments: RetainedRunEndProof.allCases
    )
    func retainedRunReleasesAfterAuthenticatedEnd(_ proof: RetainedRunEndProof) async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            _ = try await server.split(pane, direction: .right)
            _ = try await retainRun(
                on: pane,
                using: server,
                controlledBy: server,
                interruption: .cancel
            )

            switch proof {
            case .paneMissing:
                try await server.kill(pane)
            case .paneDead:
                _ = try await server.run(
                    TmuxCommand(
                        "set-option", ["-p", "-t", pane.id.rawValue, "remain-on-exit", "on"]
                    )
                )
                try await server.respawn(pane, running: ["false"])
                #expect(
                    try await waitUntil {
                        try await server.format("#{pane_dead}", addressing: pane.id.rawValue) == "1"
                    }
                )
            case .daemonEnd:
                try await server.killServer()
            case .daemonReplacement:
                try await server.killServer()
                let root = URL(fileURLWithPath: pane.incarnation.socketPath)
                    .deletingLastPathComponent()
                let reply = try await server.run(
                    TmuxCommandList([
                        TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
                        TmuxCommand("set-environment", ["-g", "ENV", ""]),
                        TmuxCommand("set-option", ["-g", "default-command", "exec sh"]),
                        TmuxCommand("new-session", ["-d", "-s", "replacement"]),
                        try reaperCommand(root: root),
                    ])
                )
                #expect(reply.isSuccess)
                #expect(try await server.incarnation() != pane.incarnation)
            }

            try await expectReleased(pane)
        }
    }

    @Test("retained pane snapshots require complete consistent rows")
    func retainedPaneSnapshotsRequireConsistency() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let prefix = "\(pane.id.rawValue)\t\(pane.windowID.rawValue)\t"
            let dead = "\(prefix)1\n"
            let live = "\(prefix)0\n"

            #expect(TmuxTools.retainedPaneEnded(pane, listing: ""))
            #expect(TmuxTools.retainedPaneEnded(pane, listing: dead + dead))
            #expect(!TmuxTools.retainedPaneEnded(pane, listing: live))
            #expect(!TmuxTools.retainedPaneEnded(pane, listing: dead + live))
            #expect(!TmuxTools.retainedPaneEnded(pane, listing: "\(pane.id.rawValue)\t@999\t1\n"))
            for malformed in [
                "\(prefix)unknown\n", "%01\t\(pane.windowID.rawValue)\t1\n",
                "%4294967296\t\(pane.windowID.rawValue)\t1\n",
                "\(pane.id.rawValue)\t@01\t1\n", "\(pane.id.rawValue)\t@4294967296\t1\n",
            ] {
                #expect(!TmuxTools.retainedPaneEnded(pane, listing: malformed))
            }
        }
    }

    @Test("capture cursors send only new output and channel waits remain bounded")
    func captureCursorAndChannelWait() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            let first = try await surface.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["paneId": .string(pane.id.rawValue)])
                )
            )
            #expect(first.structured["lines"]?.arrayValue?.isEmpty == true)
            var cursor = try #require(first.structured["cursor"]?.stringValue)

            try await server.run("printf 'incremental-retained-marker\\n'", in: pane)
            var newLines: [String] = []
            for _ in 0..<20 {
                let next = try await surface.call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "cursor": .string(cursor),
                            "paneId": .string(pane.id.rawValue),
                        ])
                    )
                )
                cursor = try #require(next.structured["cursor"]?.stringValue)
                newLines = next.structured["lines"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !newLines.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(newLines.contains("incremental-retained-marker"))

            async let released = surface.call(
                ToolCall(
                    name: "wait_for_channel",
                    arguments: .object([
                        "channel": .string("retained-gate"),
                        "timeoutMs": .integer(2_000),
                    ])
                )
            )
            try await Task.sleep(for: .milliseconds(100))
            _ = try await surface.call(
                ToolCall(
                    name: "signal_channel",
                    arguments: .object(["channel": .string("retained-gate")])
                )
            )
            #expect(try await released.structured["released"]?.boolValue == true)
        }
    }
}

enum RetainedProbeFailure: String, CaseIterable, Sendable {
    case commandFailed
    case invocationFailed

    var error: TmuxError {
        switch self {
        case .commandFailed:
            .commandFailed(command: "display-message", exitCode: 1, reason: "ambiguous probe")
        case .invocationFailed:
            .invocationFailed(reason: "ambiguous probe")
        }
    }
}

enum RetainedRunInterruption: String, CaseIterable, Sendable {
    case cancel
    case timeout
}

enum RetainedRunEndProof: String, CaseIterable, Sendable {
    case paneMissing
    case paneDead
    case daemonEnd
    case daemonReplacement
}

private actor RetainedProbeFailureTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private var armedFailure: RetainedProbeFailure?
    private var doneWaitCount = 0
    private var returnsFirstWaitEarly = false
    private var statusOverride: String?
    private var useRealStatus = false
    private(set) var failureWasInjected = false
    private(set) var earlyWaitReturned = false
    private(set) var statusOverrideWasReturned = false

    func arm(_ failure: RetainedProbeFailure) {
        armedFailure = failure
    }

    func returnFirstWaitEarly() {
        returnsFirstWaitEarly = true
    }

    func overrideRetainedStatus(with value: String) {
        statusOverride = value
    }

    func allowRealStatus() {
        useRealStatus = true
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if let waitIndex = arguments.firstIndex(of: "wait-for"),
            arguments[waitIndex...].contains(where: { $0.hasPrefix("libtmux-mcp-done-") })
        {
            doneWaitCount += 1
            if returnsFirstWaitEarly, doneWaitCount == 1 {
                earlyWaitReturned = true
                return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
            }
        }
        if let failure = armedFailure,
            arguments.contains("display-message"),
            arguments.contains(where: {
                $0.contains("#{socket_path}") && $0.contains("#{start_time}")
            })
        {
            armedFailure = nil
            failureWasInjected = true
            throw failure.error
        }
        if let statusOverride,
            !useRealStatus,
            arguments.contains(where: {
                $0.contains("show-options") && $0.contains("-v")
                    && $0.contains("@libtmux_mcp_") && $0.contains("_status")
            })
        {
            let reply = try await underlying.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                perStreamOutputLimit: perStreamOutputLimit
            )
            var lines = reply.text.split(separator: "\n", omittingEmptySubsequences: false).map(
                String.init
            )
            guard
                let index = lines.firstIndex(
                    where: { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
                )
            else { return reply }
            statusOverrideWasReturned = true
            lines[index] = statusOverride
            return TmuxReply(
                standardOutput: Array(lines.joined(separator: "\n").utf8),
                standardError: reply.standardError,
                exitCode: reply.exitCode
            )
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}
