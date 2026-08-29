import Foundation
import LibTmux
import Testing

@testable import LibTmuxMCP

/// The protocol half needs no tmux: a request is a string and a response is a
/// string, and nothing between them reaches a socket. The server it is built
/// against is never started, so these run without provisioning anything.
private func handler(
    tier: SafetyTier = .mutating,
    caller: CallerIdentity? = nil
) throws -> MCPRequestHandler {
    let server = try Server(socketPath: "/tmp/libtmux-swift-test/unstarted")
    return MCPRequestHandler(
        tools: TmuxTools(server: server, tier: tier, caller: caller)
    )
}

private func visible(tier: SafetyTier = .mutating) throws -> [ToolDefinition] {
    let server = try Server(socketPath: "/tmp/libtmux-swift-test/unstarted")
    return TmuxTools(server: server, tier: tier).visibleDefinitions
}

private func object(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func encoded(_ value: JSONValue) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
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

    @Test("large integer ids are echoed without Double rounding")
    func largeIntegerIdsSurvive() async throws {
        for id in ["9007199254740993", "18446744073709551615"] {
            let reply = try #require(
                await handler().respond(
                    to: #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#
                )
            )
            #expect(reply.contains(#""id":\#(id)"#))
        }
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
        // The listing is what the tier allows, not the whole catalogue: a
        // client must not be shown a tool the server would refuse.
        let expected = try visible()
        #expect(tools.count == expected.count)

        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(Set(names) == Set(expected.map(\.name)))

        for tool in tools {
            #expect(tool["inputSchema"]?["type"]?.stringValue == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
            #expect(tool["annotations"]?["title"]?.stringValue?.isEmpty == false)
        }
    }

    @Test("a readonly server advertises no way to change anything")
    func readonlyAdvertisesNoWrites() async throws {
        let reply = try #require(
            await handler(tier: .readonly)
                .respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        )
        guard case let .array(tools)? = try object(reply)["result"]?["tools"] else {
            Issue.record("tools/list did not answer with an array")
            return
        }
        #expect(!tools.isEmpty)
        for tool in tools {
            #expect(tool["annotations"]?["readOnlyHint"]?.boolValue == true)
        }
    }

    @Test("a required argument is listed as required, an optional one is not")
    func requiredArgumentsAreMarked() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        )
        guard case let .array(tools)? = try object(reply)["result"]?["tools"] else { return }
        for definition in try visible() {
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

    @Test("encoded tool responses have a wire limit")
    func toolResponsesAreBoundedAfterJSONEscaping() throws {
        let outcome = ToolOutcome(
            structured: .object([
                "text": .string(String(repeating: "\\", count: 500_000))
            ])
        )
        let reply = try #require(try handler().toolResponse(id: .number(1), outcome: outcome))
        let result = try #require(try object(reply)["result"])

        #expect(result["isError"]?.boolValue == true)
        #expect(try object(reply)["id"] == .number(1))
        #expect(reply.utf8.count <= MCPRequestHandler.maximumResponseBytes)
    }

    @Test("oversized tool errors use a bounded failure with the original id")
    func toolErrorsAreBoundedAfterJSONEscaping() async throws {
        let name = String(repeating: "\\", count: 600_000)
        let request = try encoded(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .number(2),
                "method": .string("tools/call"),
                "params": .object(["name": .string(name)]),
            ])
        )
        let reply = try #require(await handler().respond(to: request))
        let body = try object(reply)

        #expect(body["id"] == .number(2))
        #expect(body["result"]?["isError"]?.boolValue == true)
        #expect(
            body["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
                == "tool failed with an oversized error"
        )
        #expect(reply.utf8.count <= MCPRequestHandler.maximumResponseBytes)
    }

    @Test("a tool call with an unanswerable id is not answered under another id")
    func unanswerableToolIDIsNotReplaced() async throws {
        let id = String(repeating: "\\", count: 600_000)
        let request = try encoded(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .string(id),
                "method": .string("tools/call"),
                "params": .object(["name": .string("unknown")]),
            ])
        )
        #expect(try await handler().respond(to: request) == nil)
    }

    @Test("oversized non-tool results become bounded protocol errors")
    func protocolResultsAreBounded() async throws {
        let command = String(repeating: "\\", count: 600_000)
        let request = try encoded(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .number(3),
                "method": .string("prompts/get"),
                "params": .object([
                    "name": .string("run_and_wait"),
                    "arguments": .object([
                        "command": .string(command), "pane": .string("%1"),
                    ]),
                ]),
            ])
        )
        let reply = try #require(await handler().respond(to: request))
        let body = try object(reply)

        #expect(body["id"] == .number(3))
        #expect(body["error"]?["code"] == .number(-32001))
        #expect(reply.utf8.count <= MCPRequestHandler.maximumResponseBytes)
    }

    @Test("oversized protocol errors retry with a fixed bounded message")
    func protocolErrorsAreBounded() async throws {
        let method = String(repeating: "\\", count: 600_000)
        let request = try encoded(
            .object([
                "jsonrpc": .string("2.0"),
                "id": .number(4),
                "method": .string(method),
            ]))
        let reply = try #require(await handler().respond(to: request))
        let body = try object(reply)

        #expect(body["id"] == .number(4))
        #expect(body["error"]?["message"]?.stringValue == "response exceeds the encoded byte limit")
        #expect(reply.utf8.count <= MCPRequestHandler.maximumResponseBytes)
    }

    @Test(
        "malformed JSON receives a parse error",
        arguments: ["", "not json at all", "{"]
    )
    func malformedJSONIsAnswered(_ line: String) async throws {
        let reply = try #require(await handler().respond(to: line))
        let body = try object(reply)
        #expect(body["id"] == .null)
        #expect(body["error"]?["code"] == .number(-32700))
        #expect(body["error"]?["message"]?.stringValue == "Parse error")
    }

    @Test("stdio framing failures receive bounded protocol errors")
    func framingFailuresAreAnswered() async throws {
        let handler = try handler()
        for (event, code) in [
            (BoundedLineFramer.Event.invalidUTF8, -32700),
            (.oversized, -32600),
        ] {
            let reply = try #require(
                await handler.respond(to: MCPInput.requestLine(for: event))
            )
            let body = try object(reply)
            #expect(body["id"] == .null)
            #expect(body["error"]?["code"] == .number(Double(code)))
            #expect(reply.utf8.count <= MCPRequestHandler.maximumResponseBytes)
        }
    }

    @Test(
        "a JSON value that is not a request receives an invalid-request error",
        arguments: [
            "null",
            "[]",
            #"{"method":"ping"}"#,
            #"{"jsonrpc":"1.0","method":"ping"}"#,
            #"{"jsonrpc":"2.0"}"#,
            #"{"jsonrpc":"2.0","method":1}"#,
            #"{"jsonrpc":"2.0","method":"ping","params":true}"#,
            #"{"jsonrpc":"2.0","method":"ping","params":[]}"#,
        ]
    )
    func invalidRequestsAreAnswered(_ line: String) async throws {
        let reply = try #require(await handler().respond(to: line))
        let body = try object(reply)
        #expect(body["id"] == .null)
        #expect(body["error"]?["code"] == .number(-32600))
        #expect(body["error"]?["message"]?.stringValue == "Invalid Request")
    }

    @Test(
        "only string and integer request ids are valid",
        arguments: ["null", "1.5", "true", "false", "[]", "{}"]
    )
    func invalidRequestIDsAreRefused(_ id: String) async throws {
        let reply = try #require(
            await handler().respond(
                to: #"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#
            )
        )
        let body = try object(reply)
        #expect(body["id"] == .null)
        #expect(body["error"]?["code"] == .number(-32600))
    }

    @Test("a valid notification expects no reply")
    func notificationsAreSilent() async throws {
        let handler = try handler()
        #expect(await handler.respond(to: #"{"jsonrpc":"2.0","method":"ping"}"#) == nil)
    }

    @Test("the client's protocol revision is echoed when this server speaks it")
    func protocolRevisionIsNegotiated() async throws {
        for requested in MCPRequestHandler.protocolVersions {
            let reply = try #require(
                await handler().respond(
                    to: #"""
                        {"jsonrpc":"2.0","id":1,"method":"initialize",
                        "params":{"protocolVersion":"\#(requested)"}}
                        """#.replacingOccurrences(of: "\n", with: "")
                )
            )
            #expect(try object(reply)["result"]?["protocolVersion"]?.stringValue == requested)
        }
        // An unrecognised revision gets this server's newest rather than an
        // error: the specification says to answer with what is supported.
        let reply = try #require(
            await handler().respond(
                to:
                    #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#
            )
        )
        #expect(
            try object(reply)["result"]?["protocolVersion"]?.stringValue
                == MCPRequestHandler.protocolVersion
        )
    }

    @Test("initialize carries the instructions a model reads before choosing a tool")
    func initializeCarriesInstructions() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        )
        let instructions = try #require(
            try object(reply)["result"]?["instructions"]?.stringValue
        )
        #expect(instructions.utf8.count <= Instructions.maximumBytes)
        // The two mistakes the blurb exists to prevent.
        #expect(instructions.contains("NOT FOR"))
        #expect(instructions.contains("WAIT, DON'T POLL"))
    }

    @Test("the caller's own pane reaches the client without a call spent on it")
    func callerPaneIsAnnounced() async throws {
        let reply = try #require(
            await handler(
                caller: CallerIdentity(
                    paneID: "%42",
                    sessionID: "$0",
                    socketPath: nil,
                    serverProcessID: 1
                )
            )
            .respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        )
        let instructions = try #require(
            try object(reply)["result"]?["instructions"]?.stringValue
        )
        #expect(instructions.contains("%42"))
    }

    @Test("capabilities name every surface this server actually serves")
    func capabilitiesMatchTheSurfaces() async throws {
        let reply = try #require(
            await handler().respond(to: #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
        )
        let capabilities = try #require(try object(reply)["result"]?["capabilities"])
        // Declaring a surface that answers nothing is worse than not declaring
        // it: a client lists it once and gets an error.
        for surface in ["tools", "resources", "prompts"] {
            #expect(capabilities[surface] != nil)
        }
    }

    @Test("resources and their templates are listed separately, as the spec has them")
    func resourcesAreListed() async throws {
        let handler = try handler()
        let fixed = try #require(
            await handler.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        )
        guard case let .array(resources)? = try object(fixed)["result"]?["resources"] else {
            Issue.record("resources/list did not answer with an array")
            return
        }
        #expect(!resources.isEmpty)
        for resource in resources {
            // A fixed resource carries `uri`; a template carries `uriTemplate`.
            // Sending one under the other's key makes it unreadable.
            #expect(resource["uri"]?.stringValue?.hasPrefix("tmux://") == true)
            #expect(resource["mimeType"]?.stringValue?.isEmpty == false)
        }

        let templated = try #require(
            await handler.respond(
                to: #"{"jsonrpc":"2.0","id":1,"method":"resources/templates/list"}"#
            )
        )
        guard
            case let .array(templates)? = try object(templated)["result"]?[
                "resourceTemplates"
            ]
        else {
            Issue.record("resources/templates/list did not answer with an array")
            return
        }
        #expect(!templates.isEmpty)
        for template in templates {
            #expect(template["uriTemplate"]?.stringValue?.contains("{") == true)
        }
    }

    @Test("a resource that is not there is refused with the spec's own code")
    func missingResourceIsRefused() async throws {
        let reply = try #require(
            await handler().respond(
                to:
                    #"{"jsonrpc":"2.0","id":1,"method":"resources/read","params":{"uri":"tmux://nowhere"}}"#
            )
        )
        #expect(try object(reply)["error"]?["code"] == .number(-32002))
    }

    @Test("every prompt renders with the arguments it declares")
    func promptsRender() async throws {
        let handler = try handler()
        let listed = try #require(
            await handler.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"prompts/list"}"#)
        )
        guard case let .array(prompts)? = try object(listed)["result"]?["prompts"] else {
            Issue.record("prompts/list did not answer with an array")
            return
        }
        #expect(!prompts.isEmpty)

        for prompt in prompts {
            let name = try #require(prompt["name"]?.stringValue)
            let reply = try #require(
                await handler.respond(
                    to: #"""
                        {"jsonrpc":"2.0","id":1,"method":"prompts/get",
                        "params":{"name":"\#(name)","arguments":{}}}
                        """#.replacingOccurrences(of: "\n", with: "")
                )
            )
            let messages = try #require(try object(reply)["result"]?["messages"]?.arrayValue)
            let text = try #require(messages.first?["content"]?["text"]?.stringValue)
            #expect(!text.isEmpty, "\(name) rendered nothing")
            // A recipe that calls a tool this server does not have sends the
            // model somewhere it cannot go, and the failure surfaces as a
            // confused agent rather than as an error here.
            for called in Self.toolsCalled(in: text) {
                #expect(
                    TmuxTools.byName[called] != nil,
                    "prompt \(name) calls \(called), which is not a tool"
                )
            }
        }
    }

    /// Every `name(` in a rendered recipe, which is how the recipes write a
    /// tool call.
    private static func toolsCalled(in text: String) -> Set<String> {
        var found: Set<String> = []
        var identifier = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                identifier.append(character)
                continue
            }
            if character == "(", identifier.contains("_") { found.insert(identifier) }
            identifier = ""
        }
        return found
    }

    @Test("an unknown prompt is refused rather than rendered empty")
    func unknownPromptIsRefused() async throws {
        let reply = try #require(
            await handler().respond(
                to:
                    #"{"jsonrpc":"2.0","id":1,"method":"prompts/get","params":{"name":"nope"}}"#
            )
        )
        #expect(try object(reply)["error"]?["code"] == .number(-32602))
    }

    @Test("every answer is one line, because the framing is one message per line")
    func answersAreSingleLines() async throws {
        let handler = try handler()
        for method in [
            "initialize", "tools/list", "resources/list", "resources/templates/list",
            "prompts/list", "ping", "no/such",
        ] {
            let reply = try #require(
                await handler.respond(to: #"{"jsonrpc":"2.0","id":1,"method":"\#(method)"}"#)
            )
            #expect(!reply.contains("\n"), "\(method) answered across more than one line")
        }
    }
}
