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
}
