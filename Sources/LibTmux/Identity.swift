import Foundation

/// The identity of one running tmux daemon at one endpoint.
///
/// Provenance guards trust tmux's builtin parser and configured hooks. They
/// prevent accidental stale or foreign targeting, not hostile configuration.
public struct ServerIncarnation: Sendable, Hashable, Codable {
    public let endpoint: Endpoint
    public let socketPath: String
    public let processID: Int
    public let startedAt: Int

    public init(endpoint: Endpoint, socketPath: String, processID: Int, startedAt: Int) {
        self.endpoint = endpoint
        self.socketPath = socketPath
        self.processID = processID
        self.startedAt = startedAt
    }
}

extension ServerIncarnation {
    static let socketPathField = FormatField("socket_path")
    static let processField = FormatField("pid", .integer)
    static let startedField = FormatField("start_time", .integer)
    static let projectionFields = [socketPathField, processField, startedField]

    init(row: FormatRow, endpoint: Endpoint) {
        self.init(
            endpoint: endpoint,
            socketPath: row.text(Self.socketPathField),
            processID: row.integer(Self.processField),
            startedAt: row.integer(Self.startedField)
        )
    }
}

/// A tmux session id such as `$1`.
public struct SessionID:
    Sendable, Hashable, Codable, RawRepresentable, ExpressibleByStringLiteral,
    CustomStringConvertible, TmuxID
{
    public static let sigil: Character = "$"
    public let rawValue: String

    public init?(rawValue: String) {
        guard isValidTmuxID(rawValue, sigil: Self.sigil) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) { self = Self.tmuxIDLiteral(value) }
    public var description: String { rawValue }
    public init(from decoder: any Decoder) throws {
        self = try Self.decodeTmuxID(from: decoder)
    }
    public func encode(to encoder: any Encoder) throws { try encodeTmuxID(to: encoder) }
}

/// A tmux window id such as `@1`.
public struct WindowID:
    Sendable, Hashable, Codable, RawRepresentable, ExpressibleByStringLiteral,
    CustomStringConvertible, TmuxID
{
    public static let sigil: Character = "@"
    public let rawValue: String

    public init?(rawValue: String) {
        guard isValidTmuxID(rawValue, sigil: Self.sigil) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) { self = Self.tmuxIDLiteral(value) }
    public var description: String { rawValue }
    public init(from decoder: any Decoder) throws {
        self = try Self.decodeTmuxID(from: decoder)
    }
    public func encode(to encoder: any Encoder) throws { try encodeTmuxID(to: encoder) }
}

/// A tmux pane id such as `%1`.
public struct PaneID:
    Sendable, Hashable, Codable, RawRepresentable, ExpressibleByStringLiteral,
    CustomStringConvertible, TmuxID
{
    public static let sigil: Character = "%"
    public let rawValue: String

    public init?(rawValue: String) {
        guard isValidTmuxID(rawValue, sigil: Self.sigil) else { return nil }
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) { self = Self.tmuxIDLiteral(value) }
    public var description: String { rawValue }
    public init(from decoder: any Decoder) throws {
        self = try Self.decodeTmuxID(from: decoder)
    }
    public func encode(to encoder: any Encoder) throws { try encodeTmuxID(to: encoder) }
}

/// The session-local identity of one link to a window.
public struct WindowLinkID: Sendable, Hashable, Codable {
    public let sessionID: SessionID
    public let index: Int
    public let windowID: WindowID

    public init(sessionID: SessionID, index: Int, windowID: WindowID) {
        self.sessionID = sessionID
        self.index = index
        self.windowID = windowID
    }
}

protocol TmuxID: RawRepresentable where RawValue == String {
    static var sigil: Character { get }
}

extension TmuxID {
    static func tmuxIDLiteral(_ value: String) -> Self {
        guard let id = Self(rawValue: value) else {
            preconditionFailure("invalid \(Self.self) literal: \(value)")
        }
        return id
    }

    static func decodeTmuxID(from decoder: any Decoder) throws -> Self {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let id = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid \(Self.self): \(rawValue)"
            )
        }
        return id
    }

    func encodeTmuxID(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

func isValidTmuxID(_ rawValue: String, sigil: Character) -> Bool {
    guard rawValue.first == sigil else { return false }
    let digits = rawValue.dropFirst()
    guard !digits.isEmpty, digits.allSatisfy({ "0"..."9" ~= $0 }) else {
        return false
    }
    return digits.count == 1 || digits.first != "0"
}
