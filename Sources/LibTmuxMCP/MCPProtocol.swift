import Foundation
import LibTmux

// The JSON-RPC half of `libtmux-mcp`, kept here rather than in the executable
// because top-level code in an executable target cannot be imported and so
// cannot be tested.

/// Just enough JSON to carry ids and params through without knowing their
/// shape. An id is echoed back exactly as it arrived — a client that sends a
/// string id and receives a number will not match them up.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            // Ids are usually integers; emitting 1.0 where 1 arrived is
            // technically equal and reads as a different id.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }
}

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
    public static let protocolVersion = "2024-11-05"
    public static let serverName = "libtmux"
    public static let serverVersion = LibTmuxVersion.current

    private let tools: TmuxTools
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(tools: TmuxTools) {
        self.tools = tools
    }

    /// Answers one newline-delimited JSON-RPC request.
    ///
    /// Returns the response line, or `nil` when there is nothing to say: a
    /// blank line, a line that is not JSON-RPC at all, or a notification.
    /// Unparseable input is ignored rather than answered, because a reply needs
    /// an id to carry and a malformed line has none to quote back.
    public func respond(to line: String) async -> String? {
        guard !line.isEmpty,
            let request = try? decoder.decode(MCPRequest.self, from: Data(line.utf8)),
            let id = request.id
        else {
            return nil
        }

        switch request.method {
        case "initialize":
            return encode([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": .object([
                    "protocolVersion": .string(Self.protocolVersion),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string(Self.serverName),
                        "version": .string(Self.serverVersion),
                    ]),
                ]),
            ])
        case "tools/list":
            return encode([
                "jsonrpc": .string("2.0"), "id": id, "result": Self.toolsList(),
            ])
        case "tools/call":
            guard let call = Self.toolCall(request.params) else {
                return failure(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            do {
                let json = try await tools.call(call)
                return encode([
                    "jsonrpc": .string("2.0"), "id": id, "result": Self.toolResult(json),
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
                                "text": .string(String(describing: error)),
                            ])
                        ]),
                    ]),
                ])
            }
        case "ping":
            return encode(["jsonrpc": .string("2.0"), "id": id, "result": .object([:])])
        default:
            return failure(id: id, code: -32601, message: "no method \(request.method)")
        }
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

    /// Wraps a tool's JSON in MCP's content envelope.
    static func toolResult(_ json: Data) -> JSONValue {
        .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(String(decoding: json, as: UTF8.self)),
                ])
            ])
        ])
    }

    /// The tool schema a client reads before it can call anything.
    static func toolsList() -> JSONValue {
        .object([
            "tools": .array(
                TmuxTools.definitions.map { definition in
                    var properties: [String: JSONValue] = [:]
                    var required: [JSONValue] = []
                    for argument in definition.arguments {
                        properties[argument.name] = .object([
                            "type": .string(argument.name == "arguments" ? "array" : "string"),
                            "description": .string(argument.summary),
                        ])
                        if argument.isRequired { required.append(.string(argument.name)) }
                    }
                    return .object([
                        "name": .string(definition.name),
                        "description": .string(definition.summary),
                        "inputSchema": .object([
                            "type": .string("object"),
                            "properties": .object(properties),
                            "required": .array(required),
                        ]),
                    ])
                }
            )
        ])
    }

    /// Reads a `tools/call` params object into the request the tools take.
    static func toolCall(_ params: JSONValue?) -> ToolCall? {
        guard let name = params?["name"]?.stringValue else { return nil }
        let arguments = params?["arguments"]
        var commandArguments: [String]?
        if case let .array(values)? = arguments?["arguments"] {
            commandArguments = values.compactMap(\.stringValue)
        }
        return ToolCall(
            name: name,
            filter: arguments?["filter"]?.stringValue,
            paneRelation: arguments?["paneRelation"]?.stringValue,
            command: arguments?["command"]?.stringValue,
            arguments: commandArguments
        )
    }
}
