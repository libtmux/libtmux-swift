import Foundation

/// Just enough JSON to carry ids, arguments and results through without
/// knowing their shape.
///
/// An id is echoed back exactly as it arrived — a client that sends a string id
/// and receives a number will not match them up.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsignedInteger(UInt64)
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
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
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
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
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

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .integer(value): Int(exactly: value)
        case let .unsignedInteger(value): Int(exactly: value)
        case let .number(value): Int(exactly: value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .unsignedInteger(value): Double(value)
        case let .number(value): value
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(lhs), .bool(rhs)): lhs == rhs
        case let (.integer(lhs), .integer(rhs)): lhs == rhs
        case let (.unsignedInteger(lhs), .unsignedInteger(rhs)): lhs == rhs
        case let (.integer(lhs), .unsignedInteger(rhs)):
            UInt64(exactly: lhs) == rhs
        case let (.unsignedInteger(lhs), .integer(rhs)):
            lhs == UInt64(exactly: rhs)
        case let (.integer(lhs), .number(rhs)), let (.number(rhs), .integer(lhs)):
            lhs == Int64(exactly: rhs)
        case let (.unsignedInteger(lhs), .number(rhs)),
            let (.number(rhs), .unsignedInteger(lhs)):
            lhs == UInt64(exactly: rhs)
        case let (.number(lhs), .number(rhs)): lhs == rhs
        case let (.string(lhs), .string(rhs)): lhs == rhs
        case let (.array(lhs), .array(rhs)): lhs == rhs
        case let (.object(lhs), .object(rhs)): lhs == rhs
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case let .bool(value):
            hasher.combine(1)
            hasher.combine(value)
        case let .integer(value):
            hasher.combine(2)
            hasher.combine(Double(value))
        case let .unsignedInteger(value):
            hasher.combine(2)
            hasher.combine(Double(value))
        case let .number(value):
            hasher.combine(2)
            hasher.combine(value)
        case let .string(value):
            hasher.combine(3)
            hasher.combine(value)
        case let .array(value):
            hasher.combine(4)
            hasher.combine(value)
        case let .object(value):
            hasher.combine(5)
            hasher.combine(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(members) = self { return members[key] }
        return nil
    }

    /// Re-encodes any `Encodable` as a value this can carry.
    ///
    /// Tool results are modelled as Swift types and travel as JSON, so this is
    /// the one place the two meet. Encoding cannot fail for the types here —
    /// they are all plain `Codable` structs — and a caller has nothing useful
    /// to do about it if it did, so a failure becomes `null`.
    static func encoding(_ value: some Encodable) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return decoded
    }
}
