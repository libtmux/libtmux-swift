import Foundation
import LibTmux
import LibTmuxMCP

/// An MCP server over stdio.
///
/// Speaks JSON-RPC 2.0 on stdin and stdout, one message per line. Anything the
/// server wants to say to a human goes to stderr, because stdout is the
/// protocol and a stray `print` there corrupts the stream.

// MARK: - Wire shapes

private struct Request: Decodable {
    let jsonrpc: String
    /// Absent on a notification, which expects no reply.
    let id: JSONValue?
    let method: String
    let params: JSONValue?
}

private struct ErrorBody: Encodable {
    let code: Int
    let message: String
}

/// Just enough JSON to carry ids and params through without knowing their
/// shape. An id is echoed back exactly as it arrived — a client that sends a
/// string id and receives a number will not match them up.
private enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
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

    func encode(to encoder: any Encoder) throws {
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

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }
}

// MARK: - Serving

private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

private func note(_ message: String) {
    FileHandle.standardError.write(Data("libtmux-mcp: \(message)\n".utf8))
}

/// Writes one JSON-RPC message, newline-delimited.
private func emit(_ body: [String: JSONValue]) {
    guard let data = try? encoder.encode(body) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func reply(to id: JSONValue, result: JSONValue) {
    emit(["jsonrpc": .string("2.0"), "id": id, "result": result])
}

private func reply(to id: JSONValue, code: Int, message: String) {
    emit([
        "jsonrpc": .string("2.0"),
        "id": id,
        "error": .object(["code": .number(Double(code)), "message": .string(message)]),
    ])
}

/// Wraps a tool's JSON in MCP's content envelope.
private func toolResult(_ json: Data) -> JSONValue {
    .object([
        "content": .array([
            .object([
                "type": .string("text"),
                "text": .string(String(decoding: json, as: UTF8.self)),
            ])
        ])
    ])
}

private func toolsList() -> JSONValue {
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

private func toolCall(_ params: JSONValue?) -> ToolCall? {
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

// MARK: - Entry

let environment = ProcessInfo.processInfo.environment
let socketName = environment["LIBTMUX_SOCKET"] ?? "default"
let executable = environment["LIBTMUX_TMUX_BIN"] ?? "tmux"

let server: Server
do {
    server = try Server(socketName: socketName, tmuxExecutable: executable)
} catch {
    note("cannot address a tmux server: \(error)")
    exit(1)
}
let tools = TmuxTools(server: server)
note("serving tmux socket \(socketName) through \(executable)")

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty,
        let request = try? decoder.decode(Request.self, from: Data(line.utf8))
    else {
        continue
    }
    // A notification carries no id and expects no reply.
    guard let id = request.id else { continue }

    switch request.method {
    case "initialize":
        reply(
            to: id,
            result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("libtmux"),
                    "version": .string("0.1.0"),
                ]),
            ])
        )
    case "tools/list":
        reply(to: id, result: toolsList())
    case "tools/call":
        guard let call = toolCall(request.params) else {
            reply(to: id, code: -32602, message: "tools/call needs a tool name")
            continue
        }
        do {
            reply(to: id, result: toolResult(try await tools.call(call)))
        } catch {
            // A tool that failed is a result the model should see and reason
            // about, not a transport error that hides the reason.
            reply(
                to: id,
                result: .object([
                    "isError": .bool(true),
                    "content": .array([
                        .object([
                            "type": .string("text"),
                            "text": .string(String(describing: error)),
                        ])
                    ]),
                ])
            )
        }
    case "ping":
        reply(to: id, result: .object([:]))
    default:
        reply(to: id, code: -32601, message: "no method \(request.method)")
    }
}
