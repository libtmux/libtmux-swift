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

    @Test("a cancelled pane command keeps its lease until the command finishes")
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
            await #expect(throws: ToolError.self) {
                _ = try await surface.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string("printf 'must-not-overlap\\n'"),
                            "paneId": .string(pane.id.rawValue),
                            "timeoutMs": .integer(200),
                        ])
                    )
                )
            }

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
