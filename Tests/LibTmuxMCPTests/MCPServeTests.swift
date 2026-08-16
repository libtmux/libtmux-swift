import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// The other half: a `tools/call` reaches tmux, so these need a server. The
/// protocol shape is asserted in `MCPProtocolTests` without one.
@Suite("MCP over a real server", .timeLimit(.minutes(1)))
struct MCPServeTests {
    private func object(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The text a tool answered with, out of MCP's content envelope.
    private func content(_ reply: String) throws -> String? {
        guard case let .array(items)? = try object(reply)["result"]?["content"] else { return nil }
        return items.first?["text"]?.stringValue
    }

    @Test("a listing crosses the boundary as JSON a client can decode")
    func aListingCrossesAsJSON() async throws {
        try await withTmuxServer { server in
            let handler = MCPRequestHandler(tools: TmuxTools(server: server))
            let reply = try #require(
                await handler.respond(
                    to: #"""
                        {"jsonrpc":"2.0","id":1,"method":"tools/call",
                        "params":{"name":"list_sessions"}}
                        """#.replacingOccurrences(of: "\n", with: "")
                )
            )
            let text = try #require(try content(reply))
            let sessions = try JSONDecoder().decode([Session].self, from: Data(text.utf8))
            #expect(sessions.map(\.name) == ["bootstrap"])
        }
    }

    @Test("a tool that fails is a result the model can read, not a transport error")
    func aFailingToolIsAResult() async throws {
        try await withTmuxServer { server in
            let handler = MCPRequestHandler(tools: TmuxTools(server: server))
            let reply = try #require(
                await handler.respond(
                    to: #"""
                        {"jsonrpc":"2.0","id":1,"method":"tools/call",
                        "params":{"name":"read_format"}}
                        """#.replacingOccurrences(of: "\n", with: "")
                )
            )
            let body = try object(reply)
            // The reason belongs where the model will see it, so this is a
            // result carrying isError rather than a JSON-RPC error object.
            #expect(body["error"] == nil)
            #expect(body["result"]?["isError"] == .bool(true))
        }
    }

    @Test("an unknown tool is refused by name, and the server keeps serving")
    func anUnknownToolIsRefused() async throws {
        try await withTmuxServer { server in
            let handler = MCPRequestHandler(tools: TmuxTools(server: server))
            let refused = try #require(
                await handler.respond(
                    to: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope"}}"#
                )
            )
            #expect(try object(refused)["result"]?["isError"] == .bool(true))

            // The connection is a stream of independent lines: one bad request
            // must not end it.
            let after = try #require(
                await handler.respond(to: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
            )
            #expect(try object(after)["result"] == .object([:]))
        }
    }

    @Test("work a tool did is visible to the library that did not do it")
    func toolWorkIsVisibleOutside() async throws {
        try await withTmuxServer { server in
            let handler = MCPRequestHandler(tools: TmuxTools(server: server))
            _ = await handler.respond(
                to: #"""
                    {"jsonrpc":"2.0","id":1,"method":"tools/call","params":
                    {"name":"run_command","arguments":{"command":"new-session",
                    "arguments":["-d","-s","made-by-mcp"]}}}
                    """#.replacingOccurrences(of: "\n", with: "")
            )
            let made = try await server.hasSession("made-by-mcp")
            #expect(made)
        }
    }

    @Test("every argument a tool advertises survives the trip over the wire")
    func advertisedArgumentsSurviveTheWire() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .destructive)
            let handler = MCPRequestHandler(tools: tools)
            // The defect this exists for: `read_format` advertised `template`
            // and `target`, the protocol layer carried neither, and every call
            // failed as though the client had sent nothing. Both halves were
            // tested — separately, either side of the seam that was wrong.
            for definition in tools.visibleDefinitions {
                var members: [String: JSONValue] = [:]
                for argument in definition.arguments {
                    members[argument.name] = Self.sample(for: argument)
                }
                let request = MCPRequestHandler.toolCall(
                    .object([
                        "name": .string(definition.name),
                        "arguments": .object(members),
                    ])
                )
                let call = try #require(request)
                #expect(
                    throws: Never.self,
                    "\(definition.name) cannot receive what it advertises"
                ) {
                    try Arguments(call, for: definition)
                }
            }
            _ = handler
        }
    }

    @Test("a slow call does not hold up the calls beside it")
    func slowCallsDoNotBlockOthers() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let service = MCPService(
                handler: MCPRequestHandler(tools: TmuxTools(server: server))
            )
            let answers = Answers()
            let lines = AsyncStream<String> { continuation in
                continuation.yield(
                    #"""
                    {"jsonrpc":"2.0","id":"slow","method":"tools/call","params":
                    {"name":"wait_for_output","arguments":{"pane":"\#(pane.id)",
                    "patterns":["never-arrives"],"timeout":4}}}
                    """#.replacingOccurrences(of: "\n", with: "")
                )
                continuation.yield(#"{"jsonrpc":"2.0","id":"fast","method":"ping"}"#)
                continuation.finish()
            }
            await service.serve(lines) { await answers.record($0) }

            let order = await answers.order
            // Serving one at a time would put the four-second wait first and
            // make the server's slowest tool its latency for everything.
            #expect(order.first?.contains("\"fast\"") == true)
            #expect(order.count == 2)
        }
    }

    @Test("a cancelled request stops rather than running out its timeout")
    func cancellationStopsAWait() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let service = MCPService(
                handler: MCPRequestHandler(tools: TmuxTools(server: server))
            )
            let answers = Answers()
            let started = ContinuousClock.now
            let lines = AsyncStream<String> { continuation in
                continuation.yield(
                    #"""
                    {"jsonrpc":"2.0","id":"wait","method":"tools/call","params":
                    {"name":"wait_for_output","arguments":{"pane":"\#(pane.id)",
                    "patterns":["never-arrives"],"timeout":60}}}
                    """#.replacingOccurrences(of: "\n", with: "")
                )
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    continuation.yield(
                        #"""
                        {"jsonrpc":"2.0","method":"notifications/cancelled",
                        "params":{"requestId":"wait"}}
                        """#.replacingOccurrences(of: "\n", with: "")
                    )
                    continuation.finish()
                }
            }
            await service.serve(lines) { await answers.record($0) }

            let elapsed = ContinuousClock.now - started
            // A minute-long wait the client stopped caring about must not keep
            // a tmux process alive for the rest of it.
            #expect(elapsed < .seconds(20))
        }
    }

    private actor Answers {
        private(set) var order: [String] = []
        func record(_ line: String) { order.append(line) }
    }

    private static func sample(for argument: ToolArgument) -> JSONValue {
        if let first = argument.allowed.first { return .string(first) }
        switch argument.kind {
        case .string: return .string("%0")
        case .integer, .number: return .number(1)
        case .boolean: return .bool(false)
        case .stringArray: return .array([.string("x")])
        case .object: return .object([:])
        }
    }
}
