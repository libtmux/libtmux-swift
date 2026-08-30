import Foundation
import LibTmux

/// One validated JSON-RPC request, as far as this server reads it.
struct MCPRequest: Sendable {
    /// Absent on a notification.
    let id: JSONValue?
    let method: String
    let params: JSONValue?

    init?(_ value: JSONValue) {
        guard case let .object(members) = value,
            members["jsonrpc"] == .string("2.0"),
            case let .string(method)? = members["method"],
            Self.validID(members["id"]),
            Self.validParams(members["params"])
        else { return nil }
        self.id = members["id"]
        self.method = method
        self.params = members["params"]
    }

    var cancelledRequestID: JSONValue? {
        guard id == nil, method == "notifications/cancelled" else { return nil }
        return params?["requestId"]
    }

    private static func validID(_ id: JSONValue?) -> Bool {
        guard let id else { return true }
        switch id {
        case .integer, .unsignedInteger, .string: return true
        case .null, .bool, .number, .array, .object: return false
        }
    }

    private static func validParams(_ params: JSONValue?) -> Bool {
        guard let params else { return true }
        switch params {
        case .object: return true
        default: return false
        }
    }
}

enum MCPRequestDecoding: Sendable {
    case request(MCPRequest)
    case malformedJSON
    case invalidRequest
    case oversized
}

package enum MCPInput {
    package static func requestLine(for event: BoundedLineFramer.Event) -> String {
        switch event {
        case let .line(line): line
        case .oversized: "null"
        case .invalidUTF8: "{"
        }
    }
}

extension MCPRequestHandler {
    static func decodeRequest(_ line: String) -> MCPRequestDecoding {
        guard line.utf8.count <= maximumRequestBytes else { return .oversized }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        else { return .malformedJSON }
        guard let request = MCPRequest(value) else { return .invalidRequest }
        return .request(request)
    }
}
