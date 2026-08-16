import Foundation
import LibTmux
import Testing

@testable import LibTmuxMCP

/// The protocol half needs no tmux: a request is a string and a response is a
/// string, and nothing between them reaches a socket. The server it is built
/// against is never started, so these run without provisioning anything.
private func handler() throws -> MCPRequestHandler {
    let server = try Server(socketPath: "/tmp/libtmux-swift-test/unstarted")
    return MCPRequestHandler(tools: TmuxTools(server: server))
}

private func object(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("MCP protocol")
struct MCPProtocolTests {
    @Test("initialize answers with the protocol version and who is serving")
    func initializeAnswers() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        )
        let body = try object(reply)
        let result = try #require(body["result"])
        #expect(result["protocolVersion"]?.stringValue == MCPRequestHandler.protocolVersion)
        #expect(result["serverInfo"]?["name"]?.stringValue == MCPRequestHandler.serverName)
        // What a client is told this server is, which is the package's
        // own version rather than a number kept beside it.
        #expect(result["serverInfo"]?["version"]?.stringValue == LibTmuxVersion.current)
    }

    @Test("an integer id comes back an integer, not a float")
    func integerIdsSurvive() async throws {
        // JSON has one number type, so a decoded id is a Double and re-encoding
        // it naively yields `1.0`. A client matching replies to requests by id
        // would never match that to the `1` it sent.
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        )
        #expect(reply.contains(#""id":7"#))
        #expect(!reply.contains("7.0"))
    }

    @Test("a string id is echoed as the string it arrived as")
    func stringIdsSurvive() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        )
        #expect(try object(reply)["id"]?.stringValue == "abc")
    }

    @Test("every tool is advertised with the schema a client needs to call it")
    func toolsAreAdvertised() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        )
        guard case let .array(tools)? = try object(reply)["result"]?["tools"] else {
            Issue.record("tools/list did not answer with an array")
            return
        }
        #expect(tools.count == TmuxTools.definitions.count)

        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == Set(TmuxTools.definitions.map(\.name)))

        for tool in tools {
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
    }

    @Test("a required argument is listed as required, an optional one is not")
    func requiredArgumentsAreMarked() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        )
        guard case let .array(tools)? = try object(reply)["result"]?["tools"] else { return }
        for definition in TmuxTools.definitions {
            let tool = try #require(tools.first { $0["name"]?.stringValue == definition.name })
            guard case let .array(required)? = tool["inputSchema"]?["required"] else { continue }
            let listed = Set(required.compactMap(\.stringValue))
            let wanted = Set(definition.arguments.filter(\.isRequired).map(\.name))
            #expect(listed == wanted, "\(definition.name) advertises the wrong required set")
        }
    }

    @Test("an unknown method is refused by name")
    func unknownMethodIsRefused() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"no/such"}"#)
        )
        let body = try object(reply)
        #expect(body["error"]?["code"] == .number(-32601))
        #expect(body["error"]?["message"]?.stringValue?.contains("no/such") == true)
    }

    @Test("tools/call without a tool name is an invalid-params error")
    func toolCallNeedsAName() async throws {
        let reply = try #require(
            await handler().respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#
            )
        )
        #expect(try object(reply)["error"]?["code"] == .number(-32602))
    }

    @Test("a notification expects no reply, and neither does a line that is not one")
    func silenceWhereSilenceIsCorrect() async throws {
        let handler = try handler()
        // No id: a notification by JSON-RPC, which must not be answered.
        #expect(await handler.respond(to: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil)
        #expect(await handler.respond(to: "") == nil)
        #expect(await handler.respond(to: "not json at all") == nil)
        #expect(await handler.respond(to: "{") == nil)
    }

    @Test("every answer is one line, because the framing is one message per line")
    func answersAreSingleLines() async throws {
        let handler = try handler()
        for method in ["initialize", "tools/list", "ping", "no/such"] {
            let reply = try #require(
                await handler.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"\#(method)"}"#)
            )
            #expect(!reply.contains("\n"), "\(method) answered across more than one line")
        }
    }
}
