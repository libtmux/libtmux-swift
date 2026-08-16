import Foundation

/// How much damage a tool can do.
///
/// The server refuses anything above the tier it was started at and hides it
/// from `tools/list`, so a client configured for reading never sees a way to
/// write. Ordered, because the gate is a comparison rather than a set.
public enum SafetyTier: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Answers questions. Nothing on the server changes.
    case readonly
    /// Creates, renames, resizes, and sends input.
    case mutating
    /// Ends something: a pane, a window, a session, the server.
    case destructive

    private var rank: Int {
        switch self {
        case .readonly: 0
        case .mutating: 1
        case .destructive: 2
        }
    }

    public static func < (lhs: SafetyTier, rhs: SafetyTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One argument of a tool, in enough detail to generate its schema.
///
/// The schema and the reader are generated from the same declaration, which is
/// what keeps a documented argument from being one the tool cannot actually
/// receive.
public struct ToolArgument: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case string
        case integer
        case number
        case boolean
        case stringArray
        /// A nested JSON document, described by what it is rather than by its
        /// shape — a filter expression, a workspace plan.
        case object

        var schemaType: String {
            switch self {
            case .string: "string"
            case .integer: "integer"
            case .number: "number"
            case .boolean: "boolean"
            case .stringArray: "array"
            case .object: "object"
            }
        }
    }

    public let name: String
    public let summary: String
    public let kind: Kind
    public let isRequired: Bool
    /// The only values accepted, when there is a fixed set. Reaches the schema
    /// as `enum`, so a client can offer them rather than guess.
    public let allowed: [String]
    /// What the tool does when the argument is omitted, stated in the schema so
    /// a caller need not send it to find out.
    public let defaultValue: JSONValue?

    public init(
        name: String,
        summary: String,
        kind: Kind = .string,
        isRequired: Bool = false,
        allowed: [String] = [],
        defaultValue: JSONValue? = nil
    ) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.isRequired = isRequired
        self.allowed = allowed
        self.defaultValue = defaultValue
    }

    var schema: JSONValue {
        var members: [String: JSONValue] = [
            "type": .string(kind.schemaType),
            "description": .string(summary),
        ]
        if kind == .stringArray {
            members["items"] = .object(["type": .string("string")])
        }
        if !allowed.isEmpty {
            members["enum"] = .array(allowed.map(JSONValue.string))
        }
        if let defaultValue {
            members["default"] = defaultValue
        }
        return .object(members)
    }
}

/// One tool a client can call.
public struct ToolDefinition: Sendable, Hashable {
    /// What the client names in a ``ToolCall``.
    public let name: String
    /// A short human label, shown by clients that render one.
    public let title: String
    /// What the tool answers, for a model choosing between them. First line of
    /// the description, and the only part some clients show.
    public let summary: String
    /// When to reach for this one rather than a neighbour, and what the result
    /// means. Empty for tools whose summary says everything.
    public let detail: String
    public let tier: SafetyTier
    /// Whether calling twice with the same arguments leaves the same state as
    /// calling once. Reaches clients as `idempotentHint`.
    public let isIdempotent: Bool
    public let arguments: [ToolArgument]

    public init(
        name: String,
        title: String,
        summary: String,
        detail: String = "",
        tier: SafetyTier,
        isIdempotent: Bool = false,
        arguments: [ToolArgument] = []
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.detail = detail
        self.tier = tier
        self.isIdempotent = isIdempotent
        self.arguments = arguments
    }

    var description: String {
        detail.isEmpty ? summary : "\(summary)\n\n\(detail)"
    }

    var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for argument in arguments { properties[argument.name] = argument.schema }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(
                arguments.filter(\.isRequired).map { .string($0.name) }
            ),
            // Every tool rejects an argument it does not declare, so the schema
            // says so: a client that validates locally then reports the
            // mistake without spending a call on it.
            "additionalProperties": .bool(false),
        ])
    }

    /// The MCP behaviour hints, which clients use to decide what to confirm.
    var annotations: JSONValue {
        .object([
            "title": .string(title),
            "readOnlyHint": .bool(tier == .readonly),
            "destructiveHint": .bool(tier == .destructive),
            "idempotentHint": .bool(isIdempotent),
            // Everything here acts on one tmux server, whose contents change
            // under us: panes come and go without this server doing anything.
            "openWorldHint": .bool(true),
        ])
    }

    var listing: JSONValue {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": annotations,
        ])
    }
}

/// One tool call, as it arrives.
public struct ToolCall: Sendable, Hashable {
    public let name: String
    /// The arguments object, verbatim. Held whole rather than pulled apart
    /// here: a field this layer forgets to carry is a field the tool can never
    /// receive, and the reader below is the one place that knows the names.
    public let arguments: JSONValue

    public init(name: String, arguments: JSONValue = .object([:])) {
        self.name = name
        self.arguments = arguments
    }
}

/// Reads a call's arguments against the tool's declaration.
///
/// Strict on the way in: an argument the tool does not declare is an error
/// rather than something quietly dropped. A model that sends `pattern` where
/// the tool takes `patterns` is told so and can fix it, instead of watching a
/// wait return nothing and concluding the pane was quiet.
struct Arguments {
    private let values: [String: JSONValue]
    private let tool: ToolDefinition

    init(_ call: ToolCall, for tool: ToolDefinition) throws {
        self.tool = tool
        self.values = call.arguments.objectValue ?? [:]

        let declared = Set(tool.arguments.map(\.name))
        let unknown = values.keys.filter { !declared.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw ToolError.unknownArguments(
                unknown,
                accepted: tool.arguments.map(\.name).sorted()
            )
        }
        for argument in tool.arguments where argument.isRequired {
            guard let value = values[argument.name], !value.isNull else {
                throw ToolError.missingArgument(argument.name)
            }
        }
    }

    func string(_ name: String) throws -> String {
        guard let value = values[name]?.stringValue else {
            throw ToolError.wrongArgumentType(name, expected: "a string")
        }
        try checkAllowed(name, value)
        return value
    }

    func string(_ name: String, or fallback: String) throws -> String {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let text = value.stringValue else {
            throw ToolError.wrongArgumentType(name, expected: "a string")
        }
        try checkAllowed(name, text)
        return text
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = values[name], !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ToolError.wrongArgumentType(name, expected: "a string")
        }
        try checkAllowed(name, text)
        return text
    }

    func strings(_ name: String) throws -> [String] {
        guard let value = values[name], !value.isNull else { return [] }
        guard let entries = value.arrayValue else {
            throw ToolError.wrongArgumentType(name, expected: "an array of strings")
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                throw ToolError.wrongArgumentType(name, expected: "an array of strings")
            }
            return text
        }
    }

    /// Distinguishes an omitted list from an empty one, which several tools
    /// read as different instructions.
    func optionalStrings(_ name: String) throws -> [String]? {
        guard let value = values[name], !value.isNull else { return nil }
        return try strings(name)
    }

    func bool(_ name: String, or fallback: Bool) throws -> Bool {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let flag = value.boolValue else {
            throw ToolError.wrongArgumentType(name, expected: "true or false")
        }
        return flag
    }

    func integer(_ name: String, or fallback: Int) throws -> Int {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let number = value.intValue else {
            throw ToolError.wrongArgumentType(name, expected: "a whole number")
        }
        return number
    }

    func seconds(_ name: String, or fallback: Double) throws -> Double {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let number = value.doubleValue ?? value.intValue.map(Double.init) else {
            throw ToolError.wrongArgumentType(name, expected: "a number of seconds")
        }
        return number
    }

    /// A nested JSON document, taken either as JSON text or as an object the
    /// client inlined. Models send both, and rejecting either would be a
    /// distinction without a reason.
    func document(_ name: String) throws -> Data? {
        guard let value = values[name], !value.isNull else { return nil }
        if let text = value.stringValue { return Data(text.utf8) }
        let encoder = JSONEncoder()
        return try? encoder.encode(value)
    }

    private func checkAllowed(_ name: String, _ value: String) throws {
        guard let argument = tool.arguments.first(where: { $0.name == name }),
            !argument.allowed.isEmpty,
            !argument.allowed.contains(value)
        else { return }
        throw ToolError.notAllowed(name, value: value, allowed: argument.allowed)
    }
}

/// Why a call could not be run at all, as distinct from a tmux command that ran
/// and reported a nonzero status.
public enum ToolError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownTool(String)
    case missingArgument(String)
    case unknownArguments([String], accepted: [String])
    case wrongArgumentType(String, expected: String)
    case notAllowed(String, value: String, allowed: [String])
    case deniedByTier(String, needs: SafetyTier, allowed: SafetyTier)
    case refusedForSafety(String)
    case timedOut(String, seconds: Double)

    public var description: String {
        switch self {
        case let .unknownTool(name):
            "no tool named \(name)"
        case let .missingArgument(name):
            "\(name) is required"
        case let .unknownArguments(unknown, accepted):
            """
            unrecognised argument\(unknown.count == 1 ? "" : "s"): \
            \(unknown.joined(separator: ", ")). This tool accepts: \
            \(accepted.joined(separator: ", "))
            """
        case let .wrongArgumentType(name, expected):
            "\(name) must be \(expected)"
        case let .notAllowed(name, value, allowed):
            "\(name) cannot be \(value); it is one of \(allowed.joined(separator: ", "))"
        case let .deniedByTier(name, needs, allowed):
            """
            \(name) is a \(needs.rawValue) tool and this server runs at \
            \(allowed.rawValue). Restart it with LIBTMUX_SAFETY=\(needs.rawValue) \
            if that is what you want.
            """
        case let .refusedForSafety(reason):
            reason
        case let .timedOut(name, seconds):
            """
            \(name) gave up after \(seconds)s. The work it started is still \
            running in tmux — read the pane, or call again with a longer timeout.
            """
        }
    }
}
