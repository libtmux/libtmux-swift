import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private actor RecordedProtocolLines {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

@Suite("retained MCP behavior", .hangLimit)
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
        afterRelease: String = ":",
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
                                + "\(tmux) wait-for \(release); \(afterRelease)"
                        ),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(interruption == .timeout ? 2_000 : 20_000),
                    ])
                )
            )
        }

        // Bounded, and reports the pane when it lapses. An unbounded wait-for
        // outlives the case's time limit, so a run that never reached the pane
        // reads as a timeout naming nothing -- which is what this cost on
        // Darwin before it said anything useful.
        let signalled = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await fixture.wait(for: started)
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        if !signalled {
            let held = await TmuxTools.paneRuns.isHeld(pane)
            let screen = (try? await fixture.capture(pane))?.joined(separator: " | ") ?? "<none>"
            Issue.record(
                """
                the framed run never signalled \(started) in \(pane.id.rawValue); \
                lease held: \(held); pane: \(screen)
                """
            )
            return release
        }
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
            socketPath: "/tmp/libtmux-swift-test/oversized-id-\(UUID().uuidString)",
            tmuxExecutable: tmuxExecutablePath()
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
        "retained cleanup retries release without replaying pane input",
        arguments: RetainedReleaseFailure.allCases
    )
    func retainedReleaseRetries(_ failure: RetainedReleaseFailure) async throws {
        try await withProbeServer { fixture, server, pane, transport in
            let output = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
                .appendingPathComponent("release-retry-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: output) }
            await transport.failRelease(with: failure)
            let release = try await retainRun(
                on: pane,
                using: server,
                controlledBy: fixture,
                interruption: .cancel,
                afterRelease: "printf x >> \(shellQuoted(output.path))"
            )
            try await fixture.signal(release)
            try #require(try await waitUntil { await transport.releaseFailureWasInjected })
            let channel = try #require(await transport.releaseChannel)
            let nonce = String(channel.dropFirst("libtmux-mcp-release-".count))
            let status = "@libtmux_mcp_\(nonce)_status"
            let script = "/tmp/libtmux-mcp-run-\(nonce)"

            if failure != .replyLost {
                #expect(await TmuxTools.paneRuns.isHeld(pane))
                #expect(try await fixture.option(status, scope: .pane(pane)) == "0")
                #expect(FileManager.default.fileExists(atPath: script))
                await #expect(throws: ToolError.self) {
                    try await tools(server).call(
                        ToolCall(
                            name: "send_keys",
                            arguments: .object([
                                "force": .bool(true),
                                "keys": .array([.string("must-not-overlap")]),
                                "literal": .bool(true),
                                "paneId": .string(pane.id.rawValue),
                            ])
                        )
                    )
                }
                await transport.allowRelease()
                try #require(
                    try await waitUntil(within: .seconds(3)) {
                        await transport.releaseAttempts > 1
                    }
                )
            }

            try #require(
                try await waitUntil {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                        && !FileManager.default.fileExists(atPath: script)
                }
            )
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            #expect(try String(contentsOf: output, encoding: .utf8) == "x")
            #expect(await transport.inputDispatches == 1)
            let next = try await tools(server).call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("printf 'release-retry-recovered\\n'"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(5_000),
                    ])
                )
            )
            #expect(next.structured["exitStatus"]?.intValue == 0)
        }
    }

    @Test("a lost foreground release reply retains its cleanup proof")
    func foregroundReleaseReplyLost() async throws {
        try await withProbeServer { fixture, server, pane, transport in
            let output = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
                .appendingPathComponent("foreground-release-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: output) }
            await transport.failRelease(with: .replyLost)
            await transport.holdReleaseReply()
            let running = Task {
                try await tools(server).call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string("printf x >> \(shellQuoted(output.path))"),
                            "paneId": .string(pane.id.rawValue),
                            "timeoutMs": .integer(5_000),
                        ])
                    )
                )
            }
            defer {
                running.cancel()
                Task { await transport.allowReleaseReply() }
            }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    await transport.releaseWasDelivered
                }
            )
            let channel = try #require(await transport.releaseChannel)
            let nonce = String(channel.dropFirst("libtmux-mcp-release-".count))
            let status = "@libtmux_mcp_\(nonce)_status"
            let script = "/tmp/libtmux-mcp-run-\(nonce)"
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    let value = try await fixture.option(status, scope: .pane(pane))
                    return value == nil || value == "released"
                }
            )
            #expect(await TmuxTools.paneRuns.isHeld(pane))
            await transport.allowReleaseReply()
            // The command already completed: a lost release reply is retried
            // in the background rather than discarding the result the caller
            // is waiting on.
            let outcome = try await running.value
            #expect(outcome.structured["exitStatus"]?.intValue == 0)
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                        && !FileManager.default.fileExists(atPath: script)
                }
            )
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            #expect(try String(contentsOf: output, encoding: .utf8) == "x")
            #expect(await transport.inputDispatches == 1)
        }
    }

    @Test(
        "acknowledged cleanup retries without releasing pane input",
        arguments: [false, true],
        [RetainedReleaseFailure.notSubmitted, .replyLost]
    )
    func acknowledgedCleanupRetries(_ retained: Bool, _ failure: RetainedReleaseFailure)
        async throws
    {
        try await withProbeServer { fixture, server, pane, transport in
            await transport.failCleanup(with: failure)
            defer { Task { await transport.allowCleanup() } }
            let running: Task<ToolOutcome, any Error>?
            if retained {
                let release = try await retainRun(
                    on: pane, using: server, controlledBy: fixture, interruption: .cancel)
                try await fixture.signal(release)
                running = nil
            } else {
                running = Task {
                    try await tools(server).call(
                        ToolCall(
                            name: "run_shell_command",
                            arguments: .object([
                                "command": .string("printf 'foreground-cleanup\\n'"),
                                "paneId": .string(pane.id.rawValue),
                                "timeoutMs": .integer(5_000),
                            ])
                        )
                    )
                }
            }
            defer { running?.cancel() }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    await transport.cleanupFailureWasInjected
                }
            )
            if let running {
                // The foreground command already completed: a cleanup failure
                // after that is retried in the background rather than
                // discarding the result the caller is waiting on.
                let outcome = try await running.value
                #expect(outcome.structured["exitStatus"]?.intValue == 0)
            }
            let channel = try #require(await transport.releaseChannel)
            let nonce = String(channel.dropFirst("libtmux-mcp-release-".count))
            let status = "@libtmux_mcp_\(nonce)_status"
            let script = "/tmp/libtmux-mcp-run-\(nonce)"
            #expect(await TmuxTools.paneRuns.isHeld(pane))
            #expect(FileManager.default.fileExists(atPath: script))
            #expect(
                try await fixture.option(status, scope: .pane(pane))
                    == (failure == .notSubmitted ? "released" : nil)
            )
            await transport.allowCleanup()
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                        && !FileManager.default.fileExists(atPath: script)
                }
            )
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            #expect(await transport.inputDispatches == 1)
        }
    }

    @Test(
        "shell acknowledgment retries without replaying input or recreating cleared state",
        arguments: [nil, RetainedRunInterruption.cancel, .timeout],
        [RetainedReleaseFailure.notSubmitted, .replyLost]
    )
    func shellAcknowledgmentRetries(
        _ interruption: RetainedRunInterruption?, _ failure: RetainedReleaseFailure
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("release-acknowledgment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let injected = directory.appendingPathComponent("injected")
        let waiting = directory.appendingPathComponent("waiting")
        let retried = directory.appendingPathComponent("retried")
        let permit = directory.appendingPathComponent("permit")
        let output = directory.appendingPathComponent("output")
        let wrapper = directory.appendingPathComponent("tmux")
        try await withTmuxServer { fixture in
            let deliver =
                failure == .replyLost
                ? "\(shellQuoted(fixture.tmuxExecutable)) \"$@\" || exit $?" : ":"
            let script = """
                #!/bin/sh
                acknowledgment=0
                for argument do
                    case "$argument" in released|*' released') acknowledgment=1 ;; esac
                done
                if [ "$acknowledgment" = 1 ]; then
                    if [ ! -e \(shellQuoted(injected.path)) ]; then
                        : > \(shellQuoted(injected.path))
                        \(deliver)
                        exit 72
                    fi
                    : > \(shellQuoted(waiting.path))
                    while [ ! -e \(shellQuoted(permit.path)) ]; do sleep 0.01; done
                    \(shellQuoted(fixture.tmuxExecutable)) "$@"
                    result=$?
                    : > \(shellQuoted(retried.path))
                    exit "$result"
                fi
                exec \(shellQuoted(fixture.tmuxExecutable)) "$@"
                """
            try script.write(to: wrapper, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            defer { try? Data().write(to: permit) }
            let transport = RetainedProbeFailureTransport()
            let server = Server(
                endpoint: fixture.endpoint, tmuxExecutable: wrapper.path, transport: transport)
            let pane = try #require(try await server.panes().first)
            let command = "printf x >> \(shellQuoted(output.path))"
            let running: Task<ToolOutcome, any Error>?
            if let interruption {
                let release = try await retainRun(
                    on: pane, using: server, controlledBy: fixture,
                    interruption: interruption, afterRelease: command)
                try await fixture.signal(release)
                running = nil
            } else {
                running = Task {
                    try await tools(server).call(
                        ToolCall(
                            name: "run_shell_command",
                            arguments: .object([
                                "command": .string(command),
                                "paneId": .string(pane.id.rawValue),
                                "timeoutMs": .integer(5_000),
                            ])
                        )
                    )
                }
            }
            defer { running?.cancel() }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    FileManager.default.fileExists(atPath: injected.path)
                }
            )
            let channel = try #require(await transport.releaseChannel)
            let nonce = String(channel.dropFirst("libtmux-mcp-release-".count))
            let status = "@libtmux_mcp_\(nonce)_status"
            let staged = "/tmp/libtmux-mcp-run-\(nonce)"
            if failure == .notSubmitted {
                #expect(await TmuxTools.paneRuns.isHeld(pane))
                #expect(try await fixture.option(status, scope: .pane(pane)) == "releasing")
                #expect(FileManager.default.fileExists(atPath: staged))
                await #expect(throws: ToolError.self) {
                    try await tools(server).call(
                        ToolCall(
                            name: "send_keys",
                            arguments: .object([
                                "force": .bool(true),
                                "keys": .array([.string("must-not-overlap")]),
                                "literal": .bool(true),
                                "paneId": .string(pane.id.rawValue),
                            ])
                        )
                    )
                }
            } else {
                try #require(
                    try await waitUntil(within: .seconds(3)) {
                        !(await TmuxTools.paneRuns.isHeld(pane))
                            && !FileManager.default.fileExists(atPath: staged)
                    }
                )
                #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    FileManager.default.fileExists(atPath: waiting.path)
                }
            )
            try Data().write(to: permit)
            if let running {
                #expect(try await running.value.structured["exitStatus"]?.intValue == 0)
            }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                        && !FileManager.default.fileExists(atPath: staged)
                        && FileManager.default.fileExists(atPath: retried.path)
                }
            )
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            #expect(try String(contentsOf: output, encoding: .utf8) == "x")
            #expect(await transport.inputDispatches == 1)
            #expect(await transport.releaseAttempts == 1)
            let next = try await tools(server).call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("printf 'acknowledgment-recovered\\n'"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(5_000),
                    ])
                )
            )
            #expect(next.structured["exitStatus"]?.intValue == 0)
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
        }
    }

    @Test(
        "numeric publication retries preserve the exit status and later protocol states",
        arguments: [nil, RetainedRunInterruption.cancel, .timeout],
        [RetainedReleaseFailure.notSubmitted, .replyLost]
    )
    func numericPublicationRetries(
        _ interruption: RetainedRunInterruption?, _ failure: RetainedReleaseFailure
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("numeric-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let injected = directory.appendingPathComponent("injected")
        let waiting = directory.appendingPathComponent("waiting")
        let replay = directory.appendingPathComponent("replay")
        let permit = directory.appendingPathComponent("permit")
        let output = directory.appendingPathComponent("output")
        let wrapper = directory.appendingPathComponent("tmux")
        try await withTmuxServer { fixture in
            let native = shellQuoted(fixture.tmuxExecutable)
            let deliver = failure == .replyLost ? "\(native) \"$@\" || exit $?" : ":"
            let script = """
                #!/bin/sh
                previous=
                for argument do previous=$argument; done
                case "$previous" in
                    37|*' 37')
                        if [ ! -e \(shellQuoted(injected.path)) ]; then
                            printf '%s\\n' "$@" > \(shellQuoted(injected.path))
                            printf '%s ' 'exec' \(shellQuoted(native)) > \(shellQuoted(replay.path))
                            for argument do
                                printf "'%s' " "$argument" >> \(shellQuoted(replay.path))
                            done
                            \(deliver)
                            exit 72
                        fi
                        : > \(shellQuoted(waiting.path))
                        while [ ! -e \(shellQuoted(permit.path)) ]; do sleep 0.01; done ;;
                esac
                exec \(native) "$@"
                """
            try script.write(to: wrapper, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            defer { try? Data().write(to: permit) }
            let transport = RetainedProbeFailureTransport()
            let server = Server(
                endpoint: fixture.endpoint, tmuxExecutable: wrapper.path, transport: transport)
            let pane = try #require(try await server.panes().first)
            let command = "printf x >> \(shellQuoted(output.path)); exit 37"
            let running: Task<ToolOutcome, any Error>?
            if let interruption {
                let release = try await retainRun(
                    on: pane, using: server, controlledBy: fixture,
                    interruption: interruption, afterRelease: command)
                try await fixture.signal(release)
                running = nil
            } else {
                running = Task {
                    try await tools(server).call(
                        ToolCall(
                            name: "run_shell_command",
                            arguments: .object([
                                "command": .string(command),
                                "paneId": .string(pane.id.rawValue),
                                "timeoutMs": .integer(5_000),
                            ])
                        )
                    )
                }
            }
            defer { running?.cancel() }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    FileManager.default.fileExists(atPath: waiting.path)
                }
            )
            let arguments = try String(contentsOf: injected, encoding: .utf8)
            let range = try #require(
                arguments.range(of: "@libtmux_mcp_[a-f0-9]{32}_status", options: .regularExpression)
            )
            let status = String(arguments[range])
            let nonce = status.dropFirst("@libtmux_mcp_".count).dropLast("_status".count)
            let staged = "/tmp/libtmux-mcp-run-\(nonce)"
            #expect(await TmuxTools.paneRuns.isHeld(pane))
            #expect(FileManager.default.fileExists(atPath: staged))
            if failure == .notSubmitted {
                #expect(try await fixture.option(status, scope: .pane(pane)) == "pending")
            } else if interruption == nil {
                #expect(try await fixture.option(status, scope: .pane(pane)) == "37")
            } else {
                try #require(
                    try await waitUntil(within: .seconds(3)) {
                        try await fixture.option(status, scope: .pane(pane)) == "releasing"
                    }
                )
            }
            try Data().write(to: permit)
            if let running {
                #expect(try await running.value.structured["exitStatus"]?.intValue == 37)
            }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                        && !FileManager.default.fileExists(atPath: staged)
                }
            )
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            let delayed = try await SubprocessTransport().run(
                executable: "/bin/sh", arguments: [replay.path],
                environment: ProcessInfo.processInfo.environment, perStreamOutputLimit: 4_096)
            #expect(delayed.isSuccess)
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
            #expect(try String(contentsOf: output, encoding: .utf8) == "x")
            #expect(await transport.inputDispatches == 1)
            #expect(await transport.releaseAttempts == 1)
            let next = try await tools(server).call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("printf 'publication-recovered\\n'"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(5_000),
                    ])
                )
            )
            #expect(next.structured["exitStatus"]?.intValue == 0)
            #expect(try await fixture.option(status, scope: .pane(pane)) == nil)
        }
    }

    @Test(
        "shell protocol retries end with their original live pane",
        arguments: RetainedRunEndProof.allCases.flatMap { end in
            [(acknowledgment: false, end: end), (acknowledgment: true, end: end)]
        }, [false, true]
    )
    func shellRetriesEndWithDaemon(
        _ phase: (acknowledgment: Bool, end: RetainedRunEndProof), ignoreHUP: Bool
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("daemon-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let attempts = directory.appendingPathComponent("attempts")
        let ready = directory.appendingPathComponent("ready")
        let output = directory.appendingPathComponent("output")
        let traps = directory.appendingPathComponent("traps")
        let functionStatus = directory.appendingPathComponent("function-status")
        let permit = directory.appendingPathComponent("permit")
        let waiting = directory.appendingPathComponent("waiting")
        let wrapper = directory.appendingPathComponent("tmux")
        try await withTmuxServer { fixture in
            let pattern = phase.acknowledgment ? "*' released'" : "*'_status 0'"
            let secondAttempt =
                phase.end != .daemonEnd
                ? "if [ -e \(shellQuoted(attempts.path)) ]; then "
                    + ": > \(shellQuoted(waiting.path)); "
                    + "while [ ! -e \(shellQuoted(permit.path)) ]; do /bin/sleep 0.01; done; "
                    + "exec \(shellQuoted(fixture.tmuxExecutable)) \"$@\"; fi"
                : ":"
            let script = """
                #!/bin/sh
                previous=
                for argument do previous=$argument; done
                case "$previous" in
                    \(pattern))
                        \(secondAttempt)
                        printf '%s\\n' "$PPID" >> \(shellQuoted(attempts.path))
                        exit 72 ;;
                esac
                exec \(shellQuoted(fixture.tmuxExecutable)) "$@"
                """
            try script.write(to: wrapper, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            defer { try? Data().write(to: permit) }
            let server = Server(endpoint: fixture.endpoint, tmuxExecutable: wrapper.path)
            let pane = try #require(try await server.panes().first)
            if phase.end == .paneMissing || phase.end == .paneDead {
                let keepalive = try await fixture.run(
                    TmuxCommand("new-session", ["-d", "-s", "keepalive", "/bin/sh"]))
                try #require(keepalive.isSuccess)
            }
            let parentText = try #require(
                try await fixture.format("#{pane_pid}", addressing: pane.id.rawValue))
            let parent = try #require(Int32(parentText))
            try #require(parent > 0)
            defer { _ = kill(parent, SIGKILL) }
            let configure =
                "kill() { :; }; " + (ignoreHUP ? "trap '' HUP; " : "")
                + "printf ready > \(shellQuoted(ready.path))"
            try await fixture.send([.key(configure), .key("Enter")], to: pane)
            try #require(
                try await waitUntil {
                    FileManager.default.fileExists(atPath: ready.path)
                }
            )
            let running = Task {
                try await tools(server).call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string(
                                "trap > \(shellQuoted(traps.path)); "
                                    + "kill -0 2147483647; "
                                    + "printf '%s' \"$?\" > \(shellQuoted(functionStatus.path)); "
                                    + "printf x >> \(shellQuoted(output.path))"),
                            "paneId": .string(pane.id.rawValue),
                            "timeoutMs": .integer(5_000),
                        ])
                    )
                )
            }
            defer { running.cancel() }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    if phase.end != .daemonEnd {
                        return FileManager.default.fileExists(atPath: waiting.path)
                    }
                    return (try? String(contentsOf: attempts, encoding: .utf8))?
                        .split(separator: "\n").count ?? 0 >= 2
                }
            )
            let processIDs = try String(contentsOf: attempts, encoding: .utf8)
                .split(separator: "\n").compactMap { Int32($0) }
            let frame = try #require(processIDs.first)
            try #require(frame > 0 && frame != parent && processIDs.allSatisfy { $0 == frame })
            defer { _ = kill(frame, SIGKILL) }
            #expect(try String(contentsOf: traps, encoding: .utf8).contains("HUP") == ignoreHUP)
            #expect(try String(contentsOf: functionStatus, encoding: .utf8) == "0")
            switch phase.end {
            case .daemonEnd:
                try await fixture.killServer()
            case .daemonReplacement:
                try await fixture.killServer()
                let root = URL(fileURLWithPath: pane.incarnation.socketPath)
                    .deletingLastPathComponent()
                let start = TmuxCommandList([
                    TmuxCommand("new-session", ["-d", "-s", "replacement", "/bin/sh"]),
                    try reaperCommand(root: root),
                ])
                // The killed daemon unlinks its socket as it goes, so a client
                // sent at once can meet one still leaving. Retry until a
                // replacement answers, as the identity suite does.
                let started = try await waitUntil {
                    if try await fixture.hasSession("replacement") { return true }
                    return try await fixture.run(start).isSuccess
                }
                try #require(started)
                try #require(try await fixture.incarnation() != pane.incarnation)
            case .paneMissing:
                let reply = try await fixture.run(
                    TmuxCommand("kill-pane", ["-t", pane.id.rawValue]))
                try #require(reply.isSuccess)
            case .paneDead:
                let reply = try await fixture.run(
                    TmuxCommand(
                        "set-option", ["-p", "-t", pane.id.rawValue, "remain-on-exit", "on"]))
                try #require(reply.isSuccess)
                try #require(kill(parent, SIGKILL) == 0)
                try #require(
                    try await waitUntil {
                        try await fixture.format("#{pane_dead}", addressing: pane.id.rawValue)
                            == "1"
                    }
                )
            }
            try Data().write(to: permit)
            _ = await running.result
            #expect(
                try await waitUntil(within: .seconds(3)) {
                    kill(frame, 0) == -1 && errno == ESRCH
                }
            )
            let stopped = try String(contentsOf: attempts, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try String(contentsOf: attempts, encoding: .utf8) == stopped)
            #expect(try String(contentsOf: output, encoding: .utf8) == "x")
            try await expectReleased(pane)
        }
    }

    @Test("shell protocol targets its captured pane when another session is current")
    func shellProtocolTargetsCapturedPane() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let other = try await fixture.run(
                TmuxCommand("new-session", ["-d", "-s", "other", "/bin/sh"]))
            try #require(other.isSuccess)
            let current = try await fixture.run(
                TmuxCommand("display-message", ["-p", "#{pane_id}"]))
            try #require(
                current.text.trimmingCharacters(in: .whitespacesAndNewlines) != pane.id.rawValue)
            let ready = URL(fileURLWithPath: pane.incarnation.socketPath)
                .deletingLastPathComponent().appendingPathComponent("target-ready")
            try await fixture.send(
                [.key("unset TMUX TMUX_PANE; : > \(shellQuoted(ready.path))"), .key("Enter")],
                to: pane)
            try #require(
                try await waitUntil { FileManager.default.fileExists(atPath: ready.path) })
            let result = try await tools(fixture).call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("printf 'captured-pane\\n'"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(5_000),
                    ])
                )
            )
            #expect(result.structured["exitStatus"]?.intValue == 0)
            #expect(result.structured["output"]?.arrayValue == [.string("captured-pane")])
            try await expectReleased(pane)
        }
    }

    @Test(
        "local cleanup survives daemon termination and preserves replacement state",
        arguments: [false, true]
    )
    func localCleanupSurvivesTermination(replaceServer: Bool) async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("terminal-unlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("command")
        let output = directory.appendingPathComponent("body-output")
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let surface = tools(fixture)
            let release = "libtmux-swift-file-release-\(UUID().uuidString)"
            let request = ToolCall(
                name: "run_shell_command",
                arguments: .object([
                    "command": .string(
                        "printf x >> \(shellQuoted(output.path)); "
                            + "\(fixture.shellInvocation) wait-for \(release)"),
                    "paneId": .string(pane.id.rawValue),
                    "timeoutMs": .integer(5_000),
                ])
            )
            let arguments = try Arguments(request, for: #require(TmuxTools.byName[request.name]))
            let running = Task { try await surface.runShell(arguments, stagingAt: staged.path) }
            defer { running.cancel() }
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    (try? String(contentsOf: output, encoding: .utf8)) == "x"
                }
            )
            let payload = try String(contentsOf: staged, encoding: .utf8)
            let range = try #require(
                payload.range(of: "@libtmux_mcp_[a-f0-9]{32}_status", options: .regularExpression))
            let status = String(payload[range])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
            try await fixture.signal(release)
            // The command ran to completion despite the directory denying its
            // cleanup: a completed result is not discarded over a cleanup
            // failure, so the caller still sees the real exit status while the
            // staged file is retried in the background below.
            let outcome = try await running.value
            #expect(outcome.structured["exitStatus"]?.intValue == 0)
            try #require(FileManager.default.fileExists(atPath: staged.path))
            try await fixture.killServer()
            if replaceServer {
                let root = URL(fileURLWithPath: pane.incarnation.socketPath)
                    .deletingLastPathComponent()
                let start = TmuxCommandList([
                    TmuxCommand("new-session", ["-d", "-s", "replacement", "/bin/sh"]),
                    try reaperCommand(root: root),
                ])
                // The killed daemon unlinks its socket as it goes, so a client
                // sent at once can meet one still leaving. Retry until a
                // replacement answers, as the identity suite does.
                let started = try await waitUntil {
                    if try await fixture.hasSession("replacement") { return true }
                    return try await fixture.run(start).isSuccess
                }
                try #require(started)
                try #require(try await fixture.incarnation() != pane.incarnation)
                _ = try await fixture.run(
                    TmuxCommand("set-option", ["-p", "-t", "%0", status, "replacement-state"]))
            }
            // Keep deletion denied through the retained monitor's terminal probe.
            try await Task.sleep(for: .seconds(1))
            try #require(FileManager.default.fileExists(atPath: staged.path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            #expect(
                try await waitUntil(within: .seconds(3)) {
                    !FileManager.default.fileExists(atPath: staged.path)
                }
            )
            #expect(try String(contentsOf: output, encoding: .utf8) == "x")
            if replaceServer {
                let replacement = try #require(try await fixture.panes().first)
                #expect(
                    try await fixture.option(status, scope: .pane(replacement))
                        == "replacement-state")
            }
        }
    }

    @Test(
        "local file retries recover permissions and preserve replacement files",
        arguments: [false, true])
    func localFileRetryOwnership(replaceFile: Bool) async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("owned-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command")
        try Data("owned command".utf8).write(to: path)
        let handle = try FileHandle(forReadingFrom: path)
        let file = try TmuxTools.RunShellFile(path: path.path, descriptor: handle.fileDescriptor)
        try handle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try #require(file.remove() == .failed(POSIXErrorCode.EACCES.rawValue))
        let messages = RecordedProtocolLines()
        if replaceFile {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.moveItem(
                at: path, to: directory.appendingPathComponent("original"))
            try Data("foreign replacement".utf8).write(to: path)
        }
        let cleanup = Task {
            await TmuxTools.retryRunShellFileRemoval(file, within: .seconds(2)) {
                await messages.append($0)
            }
        }
        if !replaceFile {
            try await Task.sleep(for: .milliseconds(150))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        await cleanup.value
        if replaceFile {
            #expect(try String(contentsOf: path, encoding: .utf8) == "foreign replacement")
            #expect(await messages.values.count == 1)
            #expect(await messages.values.first?.contains("preserved a replacement") == true)
        } else {
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(await messages.values.isEmpty)
        }
    }

    @Test("retained cleanup releases its permit even when nothing ever confirms the run")
    func retainedCleanupReleasesWithoutConfirmation() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let reservation = try #require(await TmuxTools.paneRuns.reserve([pane]))
            let capture = try await server.captureBounded(
                pane, since: nil, maximumLines: 1, perStreamOutputLimit: 4_096)
            let cleanup = TmuxTools.RunShellCleanup(
                pane: pane,
                channel: "unused-done",
                releaseChannel: "unused-release",
                // A status option nothing ever sets: retainedRunState reads
                // it as neither completed nor released, and the live pane
                // never satisfies retainedRunEnded either, so nothing this
                // function polls for ever arrives on its own.
                statusOption: "@libtmux_mcp_test_unset_status",
                cursor: capture.cursor,
                startMarker: [],
                endMarker: [],
                payload: "",
                scriptPath: "/tmp/libtmux-swift-test/unused-\(UUID().uuidString)"
            )
            let started = ContinuousClock.now
            await TmuxTools.finishTimedOutRun(
                cleanup,
                server: server,
                reservation: reservation,
                releaseObserved: false,
                proofTimeout: .milliseconds(200)
            )
            // Bounded, not stuck: without a deadline this awaits forever,
            // since nothing here ever yields a proof on its own.
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(!(await TmuxTools.paneRuns.isHeld(pane)))
            // A subsequent run_shell_command on the same pane must not find
            // the permit still held by the one that never confirmed.
            #expect(await TmuxTools.paneRuns.reserve([pane]) != nil)
        }
    }

    @Test("permanent local cleanup failure ends retries and reports manual recovery")
    func localFileRetryHasTerminalFailure() async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("permanent-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("command")
        try Data("owned command".utf8).write(to: path)
        let handle = try FileHandle(forReadingFrom: path)
        let file = try TmuxTools.RunShellFile(path: path.path, descriptor: handle.fileDescriptor)
        try handle.close()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let messages = RecordedProtocolLines()
        let started = ContinuousClock.now
        await TmuxTools.retryRunShellFileRemoval(file, within: .milliseconds(250)) {
            await messages.append($0)
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(await messages.values.count == 1)
        #expect(await messages.values.first?.contains("automatic retry budget expired") == true)
        #expect(await messages.values.first?.contains("manual removal is required") == true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try await Task.sleep(for: .milliseconds(150))
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test("a delayed duplicate release cannot consume the frame's wakeup")
    func delayedReleaseRemainsIdempotent() async throws {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("release-waiter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let waiting = directory.appendingPathComponent("waiting")
        let permit = directory.appendingPathComponent("permit")
        let wrapper = directory.appendingPathComponent("tmux")
        try await withTmuxServer { fixture in
            let script = """
                #!/bin/sh
                waiting=0; signal=0; release=0
                for argument do
                    case "$argument" in
                        wait-for) waiting=1 ;;
                        -S) if [ "$waiting" = 1 ]; then signal=1; fi ;;
                        libtmux-mcp-release-*) release=1 ;;
                        'wait-for libtmux-mcp-release-'*) waiting=1; release=1 ;;
                    esac
                done
                if [ "$waiting$signal$release" = 101 ]; then
                    : > \(shellQuoted(waiting.path))
                    while [ ! -e \(shellQuoted(permit.path)) ]; do sleep 0.01; done
                fi
                exec \(shellQuoted(fixture.tmuxExecutable)) "$@"
                """
            try script.write(to: wrapper, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            defer { try? Data().write(to: permit) }
            let transport = RetainedProbeFailureTransport()
            await transport.delayFirstRelease()
            let server = Server(
                endpoint: fixture.endpoint, tmuxExecutable: wrapper.path, transport: transport)
            let pane = try #require(try await server.panes().first)
            let release = try await retainRun(
                on: pane, using: server, controlledBy: fixture, interruption: .cancel)
            try await fixture.signal(release)
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    await transport.delayedReleaseWasDelivered
                        && FileManager.default.fileExists(atPath: waiting.path)
                }
            )
            #expect(await TmuxTools.paneRuns.isHeld(pane))
            #expect(await transport.releaseAttempts == 2)
            try Data().write(to: permit)
            try #require(
                try await waitUntil(within: .seconds(3)) {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                }
            )
            #expect(await transport.inputDispatches == 1)
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
                let start = TmuxCommandList([
                    TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
                    TmuxCommand("set-environment", ["-g", "ENV", ""]),
                    TmuxCommand("set-option", ["-g", "default-command", "exec sh"]),
                    TmuxCommand("new-session", ["-d", "-s", "replacement"]),
                    try reaperCommand(root: root),
                ])
                // The killed daemon unlinks its socket as it goes, so a client
                // sent immediately after can meet one that is still leaving
                // and report `server exited unexpectedly`. Retrying until a
                // replacement answers is what the rest of the suite does --
                // see `staleValueCannotTargetReplacement` -- rather than
                // assuming teardown finished before this line.
                let started = try await waitUntil {
                    if try await server.hasSession("replacement") { return true }
                    return try await server.run(start).isSuccess
                }
                #expect(started)
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

enum RetainedReleaseFailure: String, CaseIterable, Sendable {
    case notSubmitted
    case unknownDelivery
    case replyLost
}

private actor RetainedProbeFailureTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private var armedFailure: RetainedProbeFailure?
    private var doneWaitCount = 0
    private var returnsFirstWaitEarly = false
    private var statusOverride: String?
    private var useRealStatus = false
    private var releaseFailure: RetainedReleaseFailure?
    private var releaseAllowed = false
    private var releaseReplyHeld = false
    private var cleanupFailure: RetainedReleaseFailure?
    private var cleanupAllowed = false
    private var cleanupWasDelivered = false
    private var delayingFirstRelease = false
    private var delayedReleaseArguments: [String]?
    private(set) var failureWasInjected = false
    private(set) var earlyWaitReturned = false
    private(set) var statusOverrideWasReturned = false
    private(set) var releaseFailureWasInjected = false
    private(set) var releaseChannel: String?
    private(set) var releaseAttempts = 0
    private(set) var inputDispatches = 0
    private(set) var releaseWasDelivered = false
    private(set) var cleanupFailureWasInjected = false
    private(set) var delayedReleaseWasDelivered = false

    func failRelease(with failure: RetainedReleaseFailure) {
        releaseFailure = failure
    }

    func allowRelease() {
        releaseAllowed = true
    }

    func holdReleaseReply() {
        releaseReplyHeld = true
    }

    func allowReleaseReply() {
        releaseReplyHeld = false
    }

    func failCleanup(with failure: RetainedReleaseFailure) {
        cleanupFailure = failure
    }

    func allowCleanup() {
        cleanupAllowed = true
    }

    func delayFirstRelease() {
        delayingFirstRelease = true
    }

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
        if arguments.contains(where: { $0.contains("send-keys") }) {
            inputDispatches += 1
        }
        let commandText = arguments.joined(separator: " ")
        if commandText.contains("set-option"), commandText.contains("_status"),
            !commandText.contains("releasing"), !commandText.contains("send-keys"),
            let cleanupFailure, !cleanupAllowed
        {
            if cleanupFailure == .replyLost, !cleanupWasDelivered {
                _ = try await underlying.run(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    perStreamOutputLimit: perStreamOutputLimit
                )
                cleanupWasDelivered = true
            }
            cleanupFailureWasInjected = true
            if cleanupFailure == .notSubmitted { throw .requestNotSubmitted }
            throw .invocationFailed(reason: "cleanup reply lost")
        }
        let releasePrefix = "libtmux-mcp-release-"
        if commandText.contains("wait-for"), commandText.contains("-S"),
            let range = commandText.range(of: releasePrefix)
        {
            let channel =
                releasePrefix + commandText[range.upperBound...].prefix(while: \.isHexDigit)
            releaseChannel = channel
            releaseAttempts += 1
            if delayingFirstRelease {
                delayingFirstRelease = false
                delayedReleaseArguments = arguments
                throw .invocationFailed(reason: "release is still in transit")
            }
            if let delayedReleaseArguments {
                self.delayedReleaseArguments = nil
                let reply = try await underlying.run(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    perStreamOutputLimit: perStreamOutputLimit
                )
                _ = try await underlying.run(
                    executable: executable,
                    arguments: delayedReleaseArguments,
                    environment: environment,
                    perStreamOutputLimit: perStreamOutputLimit
                )
                delayedReleaseWasDelivered = true
                return reply
            }
            if let releaseFailure, !releaseAllowed {
                releaseFailureWasInjected = true
                switch releaseFailure {
                case .notSubmitted:
                    throw .requestNotSubmitted
                case .unknownDelivery:
                    throw .invocationFailed(reason: "release delivery unknown")
                case .replyLost:
                    self.releaseFailure = nil
                    _ = try await underlying.run(
                        executable: executable,
                        arguments: arguments,
                        environment: environment,
                        perStreamOutputLimit: perStreamOutputLimit
                    )
                    releaseWasDelivered = true
                    while releaseReplyHeld {
                        do {
                            try await Task.sleep(for: .milliseconds(5))
                        } catch {
                            throw .cancelled
                        }
                    }
                    throw .invocationFailed(reason: "release reply lost")
                }
            }
        }
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
