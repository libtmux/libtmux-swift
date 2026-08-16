import Foundation
import LibTmux

// The JSON-RPC half of `libtmux-mcp`, kept here rather than in the executable
// because top-level code in an executable target cannot be imported and so
// cannot be tested.

/// One JSON-RPC request, as far as this server reads them.
struct MCPRequest: Decodable {
    let jsonrpc: String
    /// Absent on a notification, which expects no reply.
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

/// Answers MCP requests, one line at a time, without touching a file
/// descriptor.
public struct MCPRequestHandler: Sendable {
    /// The revisions this server speaks, newest first.
    ///
    /// A client's requested revision is echoed back when it is one of these, so
    /// a new client is not held to an old shape and an old one is not handed a
    /// new one. Anything unrecognised gets the newest, which is what the
    /// specification says to do.
    public static let protocolVersions = [
        "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
    ]
    public static var protocolVersion: String { protocolVersions[0] }
    public static let serverName = "libtmux"
    public static let serverVersion = LibTmuxVersion.current

    private let tools: TmuxTools
    private let resources: TmuxResources
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(tools: TmuxTools) {
        self.tools = tools
        self.resources = TmuxResources(server: tools.server)
    }

    /// Answers one newline-delimited JSON-RPC request.
    ///
    /// Returns the response line, or `nil` when there is nothing to say: a
    /// blank line, a line that is not JSON-RPC at all, or a notification.
    /// Unparseable input is ignored rather than answered, because a reply needs
    /// an id to carry and a malformed line has none to quote back.
    ///
    /// - Parameter emit: where a notification sent *before* the answer goes —
    ///   progress, while a long call is still running. Writing them is the
    ///   caller's job because they share the one stdout the answer uses, and
    ///   two writers there would interleave.
    public func respond(
        to line: String,
        emit: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> String? {
        guard !line.isEmpty,
            let request = try? decoder.decode(MCPRequest.self, from: Data(line.utf8))
        else {
            return nil
        }
        guard let id = request.id else { return nil }

        switch request.method {
        case "initialize":
            return encode([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([
                    "protocolVersion": .string(
                        Self.negotiated(request.params?["protocolVersion"]?.stringValue)
                    ),
                    "capabilities": .object([
                        "tools": .object(["listChanged": .bool(false)]),
                        "resources": .object([
                            "subscribe": .bool(false), "listChanged": .bool(false),
                        ]),
                        "prompts": .object(["listChanged": .bool(false)]),
                    ]),
                    "serverInfo": .object([
                        "name": .string(Self.serverName),
                        "title": .string("tmux"),
                        "version": .string(Self.serverVersion),
                    ]),
                    "instructions": .string(
                        Instructions.text(
                            tier: tools.tier,
                            waitCeiling: tools.waitCeiling,
                            caller: tools.caller
                        )
                    ),
                ]),
            ])

        case "tools/list":
            return encode([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([
                    "tools": .array(tools.visibleDefinitions.map(\.listing))
                ]),
            ])

        case "tools/call":
            guard let call = Self.toolCall(request.params) else {
                return failure(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            do {
                let outcome = try await tools.call(
                    call,
                    reporting: ProgressReporter(
                        token: ProgressReporter.token(in: request.params),
                        emit: emit
                    )
                )
                return encode([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object([
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(outcome.text),
                            ])
                        ]),
                        // Modern clients parse this and never see the text;
                        // older ones have only the text. Sending one would make
                        // the server unusable on half of them.
                        "structuredContent": outcome.structured,
                        "isError": .bool(false),
                    ]),
                ])
            } catch {
                // A tool that failed is a result the model should see and
                // reason about, not a transport error that hides the reason.
                return encode([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object([
                        "isError": .bool(true),
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string(Self.message(for: error)),
                            ])
                        ]),
                    ]),
                ])
            }

        case "resources/list":
            return encode([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(["resources": .array(TmuxResources.fixed)]),
            ])

        case "resources/templates/list":
            return encode([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(["resourceTemplates": .array(TmuxResources.templates)]),
            ])

        case "resources/read":
            guard let uri = request.params?["uri"]?.stringValue else {
                return failure(id: id, code: -32602, message: "resources/read needs a uri")
            }
            do {
                return encode([
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object(["contents": .array([try await resources.read(uri)])]),
                ])
            } catch {
                // -32002 is the specification's code for a resource that is not
                // there, which clients distinguish from a malformed request.
                return failure(id: id, code: -32002, message: Self.message(for: error))
            }

        case "prompts/list":
            return encode([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object(["prompts": .array(Prompts.listing)]),
            ])

        case "prompts/get":
            guard let name = request.params?["name"]?.stringValue else {
                return failure(id: id, code: -32602, message: "prompts/get needs a name")
            }
            guard
                let rendered = Prompts.render(
                    name,
                    arguments: request.params?["arguments"] ?? .object([:])
                )
            else {
                return failure(id: id, code: -32602, message: "no prompt named \(name)")
            }
            return encode(["jsonrpc": .string("2.0"), "id": id, "result": rendered])

        case "ping":
            return encode(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])

        default:
            return failure(id: id, code: -32601, message: "no method \(request.method)")
        }
    }

    /// Whether a line is a notification — something to act on with no reply.
    ///
    /// `notifications/cancelled` is the one that matters: it is how a client
    /// says it has stopped waiting, and the only way a wait already in flight
    /// can be stopped early.
    public static func cancelledRequestID(in line: String) -> JSONValue? {
        guard let request = try? JSONDecoder().decode(MCPRequest.self, from: Data(line.utf8)),
            request.method == "notifications/cancelled"
        else { return nil }
        return request.params?["requestId"]
    }

    static func negotiated(_ requested: String?) -> String {
        guard let requested, protocolVersions.contains(requested) else {
            return protocolVersion
        }
        return requested
    }

    /// The text a model reads when something went wrong.
    ///
    /// ``ToolError`` writes for that reader; anything else is a Swift error
    /// whose `description` is the best available and rarely as good.
    static func message(for error: any Error) -> String {
        if let tool = error as? ToolError { return tool.description }
        if let tmux = error as? TmuxError { return String(describing: tmux) }
        return String(describing: error)
    }

    private func failure(id: JSONValue, code: Int, message: String) -> String? {
        encode([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }

    private func encode(_ body: [String: JSONValue]) -> String? {
        guard let data = try? encoder.encode(body) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a `tools/call` params object.
    ///
    /// The arguments object travels whole. Naming fields here is what made
    /// `read_format` unreachable once: the handler carried five of its seven
    /// argument names, so the two it forgot could never arrive however
    /// correctly they were sent.
    static func toolCall(_ params: JSONValue?) -> ToolCall? {
        guard let name = params?["name"]?.stringValue else { return nil }
        return ToolCall(name: name, arguments: params?["arguments"] ?? .object([:]))
    }
}
