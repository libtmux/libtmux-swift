import Foundation
import LibTmux

// JSON-RPC handling lives in the library target because executable top-level
// code cannot be imported and tested.

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
        "2025-11-25", "2025-06-18", "2024-11-05",
    ]
    public static var protocolVersion: String { protocolVersions[0] }
    public static let serverName = "libtmux"
    public static let serverVersion = LibTmuxVersion.current
    package static let maximumRequestBytes = 2_000_000
    static let maximumResponseBytes = 1_000_000

    private let tools: TmuxTools
    private let resources: CapabilityResources
    private let encoder = JSONEncoder()

    public init(tools: TmuxTools) {
        self.tools = tools
        self.resources = CapabilityResources(tools: tools)
    }

    /// Answers one newline-delimited JSON-RPC request.
    ///
    /// Returns the response line, or `nil` for a valid notification, an
    /// oversized request, or a tool call whose id cannot fit in a bounded
    /// response. Malformed JSON and invalid request objects receive the
    /// standard JSON-RPC error with a null id.
    ///
    /// - Parameters:
    ///   - line: one JSON-RPC request without its trailing newline.
    ///   - emit: where a notification sent *before* the answer goes — progress,
    ///     while a long call is still running. Writing them is the caller's job
    ///     because they share the one stdout the answer uses, and two writers
    ///     there would interleave.
    public func respond(
        to line: String,
        emit: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> String? {
        await respond(to: Self.decodeRequest(line), emit: emit)
    }

    func respond(
        to decoded: MCPRequestDecoding,
        emit: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> String? {
        let request: MCPRequest
        switch decoded {
        case let .request(decoded):
            request = decoded
        case .malformedJSON:
            return failure(id: .null, code: -32700, message: "Parse error")
        case .invalidRequest:
            return failure(id: .null, code: -32600, message: "Invalid Request")
        case .oversized:
            return nil
        }
        guard let id = request.id else { return nil }
        guard minimalFailure(id: id) != nil else { return nil }

        switch request.method {
        case "initialize":
            guard let requested = Self.initializeProtocolVersion(request.params) else {
                return failure(
                    id: id,
                    code: -32602,
                    message: "initialize needs protocolVersion, capabilities, and clientInfo"
                )
            }
            return boundedResponse(
                id: id,
                [
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object([
                        "protocolVersion": .string(
                            Self.negotiated(requested)
                        ),
                        "capabilities": .object([
                            "tools": .object(["listChanged": .bool(false)]),
                            "resources": .object([
                                "subscribe": .bool(false), "listChanged": .bool(false),
                            ]),
                        ]),
                        "serverInfo": .object([
                            "name": .string(Self.serverName),
                            "title": .string("tmux"),
                            "version": .string(Self.serverVersion),
                        ]),
                        "instructions": .string(
                            Instructions.text(
                                authority: tools.authority,
                                waitCeiling: tools.waitCeiling,
                                caller: tools.caller
                            )
                        ),
                    ]),
                ])

        case "tools/list":
            return boundedResponse(
                id: id,
                [
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object([
                        "tools": .array(tools.visibleDefinitions.map(\.listing))
                    ]),
                ])

        case "tools/call":
            // Do not run a tool when no bounded response can echo its id.
            guard toolFailure(id: id, message: Self.oversizedToolError) != nil else {
                return failure(
                    id: id,
                    code: -32001,
                    message: "request id leaves no room for a tool response"
                )
            }
            guard let call = Self.toolCall(request.params) else {
                return failure(
                    id: id,
                    code: -32602,
                    message: "tools/call needs a tool name and object arguments"
                )
            }
            guard tools.exposes(call.name) else {
                return failure(
                    id: id,
                    code: -32602,
                    message: ToolError.unknownTool(call.name).description
                )
            }
            do {
                let outcome = try await tools.call(
                    call,
                    reporting: ProgressReporter(
                        token: ProgressReporter.token(in: request.params),
                        emit: emit
                    )
                )
                return toolResponse(id: id, outcome: outcome)
            } catch {
                // A tool that failed is a result the model should see and
                // reason about, not a transport error that hides the reason.
                return toolFailure(id: id, message: Self.message(for: error))
            }

        case "resources/list":
            return boundedResponse(
                id: id,
                [
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object(["resources": .array(CapabilityResources.fixed)]),
                ])

        case "resources/templates/list":
            return boundedResponse(
                id: id,
                [
                    "jsonrpc": .string("2.0"),
                    "id": id,
                    "result": .object(["resourceTemplates": .array(CapabilityResources.templates)]),
                ])

        case "resources/read":
            guard let uri = request.params?["uri"]?.stringValue else {
                return failure(id: id, code: -32602, message: "resources/read needs a uri")
            }
            do {
                return boundedResponse(
                    id: id,
                    [
                        "jsonrpc": .string("2.0"),
                        "id": id,
                        "result": .object(["contents": .array([try resources.read(uri)])]),
                    ])
            } catch {
                // -32002 is the specification's code for a resource that is not
                // there, which clients distinguish from a malformed request.
                return failure(id: id, code: -32002, message: Self.message(for: error))
            }

        case "ping":
            return boundedResponse(
                id: id,
                ["jsonrpc": .string("2.0"), "id": id, "result": .object([:])]
            )

        default:
            return failure(id: id, code: -32601, message: "no method \(request.method)")
        }
    }

    static func negotiated(_ requested: String?) -> String {
        guard let requested, protocolVersions.contains(requested) else {
            return protocolVersion
        }
        return requested
    }

    static func initializeProtocolVersion(_ params: JSONValue?) -> String? {
        guard let members = params?.objectValue,
            let requested = members["protocolVersion"]?.stringValue,
            members["capabilities"]?.objectValue != nil,
            let clientInfo = members["clientInfo"]?.objectValue,
            clientInfo["name"]?.stringValue != nil,
            clientInfo["version"]?.stringValue != nil
        else { return nil }
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
        ]) ?? minimalFailure(id: id)
    }

    func capacityFailure(id: JSONValue, maximum: Int) -> String? {
        failure(
            id: id,
            code: -32000,
            message: "server already has \(maximum) requests in flight"
        )
    }

    private func encode(_ body: [String: JSONValue]) -> String? {
        guard let data = try? encoder.encode(body),
            data.count < Self.maximumResponseBytes
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func boundedResponse(
        id: JSONValue,
        _ body: [String: JSONValue]
    ) -> String? {
        encode(body)
            ?? failure(
                id: id,
                code: -32001,
                message: "response exceeds the encoded byte limit"
            )
    }

    private func minimalFailure(id: JSONValue) -> String? {
        encode([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(-32001),
                "message": .string("response exceeds the encoded byte limit"),
            ]),
        ])
    }

    func toolResponse(id: JSONValue, outcome: ToolOutcome) -> String? {
        if let response = encodedToolResponse(id: id, outcome: outcome) { return response }
        if let bounded = ReadBatchAccumulator.bounding(
            outcome,
            whileExceeding: { encodedToolResponse(id: id, outcome: $0) != nil }
        ), let response = encodedToolResponse(id: id, outcome: bounded) {
            return response
        }
        return toolFailure(
            id: id,
            message: "tool result exceeds the 1000000-byte encoded response limit"
        )
    }

    private func encodedToolResponse(id: JSONValue, outcome: ToolOutcome) -> String? {
        let body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(outcome.text),
                    ])
                ]),
                // Modern clients parse this and never see the text; older
                // ones have only the text.
                "structuredContent": outcome.structured,
                "isError": .bool(false),
            ]),
        ]
        return encode(body)
    }

    private func toolFailure(id: JSONValue, message: String) -> String? {
        let body: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "isError": .bool(true),
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(message),
                    ])
                ]),
            ]),
        ]
        if let response = encode(body) { return response }

        let bounded: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object([
                "isError": .bool(true),
                "content": .array([
                    .object([
                        "type": .string("text"), "text": .string(Self.oversizedToolError),
                    ])
                ]),
            ]),
        ]
        return encode(bounded)
    }

    private static let oversizedToolError = "tool failed with an oversized error"

    /// Reads a `tools/call` params object.
    ///
    /// The arguments object travels whole. Naming fields here is what made
    /// `read_format` unreachable once: the handler carried five of its seven
    /// argument names, so the two it forgot could never arrive however
    /// correctly they were sent.
    static func toolCall(_ params: JSONValue?) -> ToolCall? {
        guard let name = params?["name"]?.stringValue else { return nil }
        let arguments = params?["arguments"] ?? .object([:])
        guard arguments.objectValue != nil else { return nil }
        return ToolCall(name: name, arguments: arguments)
    }
}
