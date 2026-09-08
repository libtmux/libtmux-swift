import Foundation
import LibTmux

/// The independently selectable public tool groups.
public enum Toolset: String, Sendable, Hashable, Codable, CaseIterable {
    case inspect
    case manage
    case execute
    case teardown
}

/// Whether caller-controlled data can reach a workload process.
public enum ProcessReach: String, Sendable, Hashable, Codable {
    case none
    case configuredProcess = "configured-process"
    case paneInput = "pane-input"
    case paneCommand = "pane-command"
}

/// Direct effects on tmux state. This is a set, not an ordered safety level.
public enum TmuxEffect: String, Sendable, Hashable, Codable {
    case observe
    case change
    case delete
}

/// Classes of data a successful call can return.
public enum OutputClass: String, Sendable, Hashable, Codable {
    case tmuxMetadata = "tmux-metadata"
    case terminalContent = "terminal-content"
    case processEnvironment = "process-environment"
    case configuredCommand = "configured-command"
}

/// The interpreter boundary reached by one caller-controlled input.
public enum InputSink: String, Sendable, Hashable, Codable {
    case none
    case tmuxLookup = "tmux-lookup"
    case tmuxState = "tmux-state"
    case tmuxFormat = "tmux-format"
    case paneInput = "pane-input"
    case shellCommand = "shell-command"
    case processArgv = "process-argv"
    case regex
    case nestedTool = "nested-tool"
}

/// The manifest-owned control applied before a value reaches tmux format expansion.
public enum TmuxFormatControl: String, Sendable, Hashable, Codable {
    case doubleHashOnce = "double-hash-once"
    case validatedVariableName = "validated-variable-name"
}

/// All four MCP hints are owned explicitly by each registry row.
public struct ToolAnnotations: Sendable, Hashable, Codable {
    public let destructiveHint: Bool
    public let idempotentHint: Bool
    public let openWorldHint: Bool
    public let readOnlyHint: Bool

    public static let conservative = ToolAnnotations(
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true,
        readOnlyHint: false
    )
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
        case commandArray
        /// A nested JSON document, described by what it is rather than by its
        /// shape — a filter expression, a workspace plan.
        case object

        var schemaType: String {
            switch self {
            case .string: "string"
            case .integer: "integer"
            case .number: "number"
            case .boolean: "boolean"
            case .stringArray, .commandArray: "array"
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
    /// Inclusive numeric bounds, enforced by the reader and published in the schema.
    public let minimum: Double?
    public let maximum: Double?
    /// The most entries accepted in an array argument.
    public let maximumItems: Int?
    /// The fewest entries accepted in an array argument.
    public let minimumItems: Int?
    /// The most characters accepted in a string argument.
    public let maximumLength: Int?
    /// A byte ceiling disclosed explicitly because JSON Schema maxLength counts characters.
    public let maximumUTF8Bytes: Int?
    /// A JSON Schema pattern applied before the value reaches tmux.
    public let pattern: String?
    /// The schema for each entry when an array contains structured values.
    public let itemSchema: JSONValue?
    /// The exact control applied before this value reaches tmux format expansion.
    public let tmuxFormatControl: TmuxFormatControl?

    init(
        name: String,
        summary: String,
        kind: Kind = .string,
        isRequired: Bool = false,
        allowed: [String] = [],
        defaultValue: JSONValue? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minimumItems: Int? = nil,
        maximumItems: Int? = nil,
        maximumLength: Int? = nil,
        maximumUTF8Bytes: Int? = nil,
        pattern: String? = nil,
        itemSchema: JSONValue? = nil,
        tmuxFormatControl: TmuxFormatControl? = nil
    ) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.isRequired = isRequired
        self.allowed = allowed
        self.defaultValue = defaultValue
        self.minimum = minimum
        self.maximum = maximum
        self.minimumItems = minimumItems
        self.maximumItems = maximumItems
        self.maximumLength = maximumLength
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.pattern = pattern
        self.itemSchema = itemSchema
        self.tmuxFormatControl = tmuxFormatControl
    }

    var schema: JSONValue {
        var members: [String: JSONValue] = [
            "type": .string(kind.schemaType),
            "description": .string(summary),
        ]
        if kind == .stringArray {
            members["items"] = .object(["type": .string("string")])
        }
        if let itemSchema {
            members["items"] = itemSchema
        } else if kind == .commandArray {
            members["items"] = .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object(["type": .string("string")]),
                    "arguments": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("command")]),
                "additionalProperties": .bool(false),
            ])
        }
        if !allowed.isEmpty {
            members["enum"] = .array(allowed.map(JSONValue.string))
        }
        if let defaultValue {
            members["default"] = defaultValue
        }
        if let minimum { members["minimum"] = .number(minimum) }
        if let maximum { members["maximum"] = .number(maximum) }
        if let minimumItems { members["minItems"] = .number(Double(minimumItems)) }
        if let maximumItems { members["maxItems"] = .number(Double(maximumItems)) }
        if let maximumLength { members["maxLength"] = .number(Double(maximumLength)) }
        if let maximumUTF8Bytes {
            members["x-libtmux-max-utf8-bytes"] = .number(Double(maximumUTF8Bytes))
        }
        if let pattern { members["pattern"] = .string(pattern) }
        return .object(members)
    }

    func replacingItemSchema(with itemSchema: JSONValue) -> ToolArgument {
        return ToolArgument(
            name: name,
            summary: summary,
            kind: kind,
            isRequired: isRequired,
            allowed: allowed,
            defaultValue: defaultValue,
            minimum: minimum,
            maximum: maximum,
            minimumItems: minimumItems,
            maximumItems: maximumItems,
            maximumLength: maximumLength,
            maximumUTF8Bytes: maximumUTF8Bytes,
            pattern: pattern,
            itemSchema: itemSchema,
            tmuxFormatControl: tmuxFormatControl
        )
    }
}

public struct ToolDefinition: Sendable {
    static let capabilityMetadataKey = "com.git-pull.libtmux-mcp/capability"
    let operation: ToolOperation
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
    public let arguments: [ToolArgument]
    /// What the tool answers with, when that shape is guaranteed. Declared
    /// only where it is: MCP requires `structuredContent` to conform to this,
    /// so a schema the server may break is worse than none at all.
    public let outputSchema: JSONValue?
    public let toolset: Toolset
    public let processReach: ProcessReach
    public let tmuxEffects: Set<TmuxEffect>
    public let outputClasses: Set<OutputClass>
    public let mayExposeSecrets: Bool
    public let mayReturnUntrustedContent: Bool
    public let explicitAnnotations: ToolAnnotations
    public let inputSinks: [String: Set<InputSink>]
    public let nestedAuthority: Set<String>
    public let amplifiesFutureInput: Bool
    let handler: @Sendable (TmuxTools, Arguments, ProgressReporter) async throws -> ToolOutcome

    init(
        operation: ToolOperation,
        title: String,
        descriptionBody: String,
        toolset: Toolset,
        processReach: ProcessReach,
        tmuxEffects: Set<TmuxEffect>,
        outputClasses: Set<OutputClass>,
        mayExposeSecrets: Bool = true,
        mayReturnUntrustedContent: Bool = true,
        annotations: ToolAnnotations = .conservative,
        arguments: [ToolArgument],
        outputSchema: JSONValue,
        inputSinks: [String: Set<InputSink>],
        nestedAuthority: Set<String> = [],
        amplifiesFutureInput: Bool = false,
        handler:
            @escaping @Sendable (
                TmuxTools, Arguments, ProgressReporter
            ) async throws -> ToolOutcome
    ) {
        self.operation = operation
        self.name = operation.rawValue
        self.title = title
        self.summary =
            Self.controlledOpener(
                toolset: toolset,
                processReach: processReach,
                outputClasses: outputClasses
            )
            + descriptionBody
        self.detail = ""
        self.arguments = arguments
        self.outputSchema = outputSchema
        self.toolset = toolset
        self.processReach = processReach
        self.tmuxEffects = tmuxEffects
        self.outputClasses = outputClasses
        self.mayExposeSecrets = mayExposeSecrets
        self.mayReturnUntrustedContent = mayReturnUntrustedContent
        self.explicitAnnotations = annotations
        self.inputSinks = inputSinks
        self.nestedAuthority = nestedAuthority
        self.amplifiesFutureInput = amplifiesFutureInput
        self.handler = { tools, arguments, progress in
            let outcome = try await handler(tools, arguments, progress)
            do {
                try ToolSchemaValidator.validate(outcome.structured, against: outputSchema)
            } catch {
                throw ToolError.internalFailure(
                    "\(operation.rawValue) returned output outside its schema: \(error)"
                )
            }
            return outcome
        }
    }

    static func controlledOpener(
        toolset: Toolset,
        processReach: ProcessReach,
        outputClasses: Set<OutputClass>
    ) -> String {
        if toolset == .teardown {
            return "Delete tmux state; accepts no command payload. "
        }
        switch processReach {
        case .configuredProcess:
            return "Start a pane's configured process; accepts no command payload. "
        case .paneInput:
            return
                "Send input to a pane's program; a shell that receives it runs it with your user's permissions. "
        case .paneCommand:
            return "Run a shell command in a pane with your user's permissions. "
        case .none:
            break
        }
        guard toolset == .inspect else {
            return "Change tmux state; no client-supplied executable input. "
        }
        if outputClasses.contains(.terminalContent) {
            return
                "Read pane output; accepts no client-supplied executable input. Returned content may be sensitive or untrusted. "
        }
        if outputClasses.contains(.processEnvironment) {
            return
                "Read the tmux environment; accepts no client-supplied executable input. Returned values may contain secrets. "
        }
        if outputClasses.contains(.configuredCommand) {
            return
                "Read configured tmux commands; accepts no client-supplied executable input. Returned values may contain executable configuration. "
        }
        return "Inspect tmux metadata; accepts no client-supplied executable input. "
    }

    func restrictingNestedAuthority(to definitions: [ToolDefinition]) -> ToolDefinition {
        guard !nestedAuthority.isEmpty else { return self }
        let sourceOpener = Self.controlledOpener(
            toolset: toolset,
            processReach: processReach,
            outputClasses: outputClasses
        )
        let nestedDefinitions = definitions.filter { nestedAuthority.contains($0.name) }
        let restrictedNestedAuthority = Set(nestedDefinitions.map(\.name))
        let operationSchemas = nestedDefinitions.sorted { $0.name < $1.name }.map { nested in
            JSONValue.object([
                "type": .string("object"),
                "properties": .object([
                    "tool": .object([
                        "type": .string("string"),
                        "const": .string(nested.name),
                    ]),
                    "arguments": nested.inputSchema,
                ]),
                "required": .array([.string("tool")]),
                "additionalProperties": .bool(false),
            ])
        }
        let operationSchema: JSONValue =
            operationSchemas.isEmpty
            ? .object(["not": .object([:])])
            : .object(["oneOf": .array(operationSchemas)])
        let restrictedArguments = arguments.map { argument in
            argument.name == "operations"
                ? argument.replacingItemSchema(with: operationSchema)
                : argument
        }
        let nestedEffects = Set(nestedDefinitions.flatMap(\.tmuxEffects))
        let effectiveEffects: Set<TmuxEffect> =
            nestedEffects.isEmpty ? [.observe] : nestedEffects
        let nestedOutputs = Set(nestedDefinitions.flatMap(\.outputClasses))
        let nestedMayExposeSecrets = nestedDefinitions.contains(where: \.mayExposeSecrets)
        let nestedMayReturnUntrustedContent = nestedDefinitions.contains(
            where: \.mayReturnUntrustedContent
        )
        return ToolDefinition(
            operation: operation,
            title: title,
            descriptionBody: String(description.dropFirst(sourceOpener.count)),
            toolset: toolset,
            processReach: processReach,
            tmuxEffects: effectiveEffects,
            outputClasses: nestedOutputs,
            mayExposeSecrets: nestedMayExposeSecrets,
            mayReturnUntrustedContent: nestedMayReturnUntrustedContent,
            annotations: explicitAnnotations,
            arguments: restrictedArguments,
            outputSchema: outputSchema ?? .object(["type": .string("object")]),
            inputSinks: inputSinks,
            nestedAuthority: restrictedNestedAuthority,
            amplifiesFutureInput: amplifiesFutureInput,
            handler: handler
        )
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
            "readOnlyHint": .bool(explicitAnnotations.readOnlyHint),
            "destructiveHint": .bool(explicitAnnotations.destructiveHint),
            "idempotentHint": .bool(explicitAnnotations.idempotentHint),
            "openWorldHint": .bool(explicitAnnotations.openWorldHint),
        ])
    }

    private var capabilityAnnotations: JSONValue {
        .object([
            "readOnlyHint": .bool(explicitAnnotations.readOnlyHint),
            "destructiveHint": .bool(explicitAnnotations.destructiveHint),
            "idempotentHint": .bool(explicitAnnotations.idempotentHint),
            "openWorldHint": .bool(explicitAnnotations.openWorldHint),
        ])
    }

    var listing: JSONValue {
        var members: [String: JSONValue] = [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": annotations,
            "_meta": .object([Self.capabilityMetadataKey: capabilityRow]),
        ]
        if let outputSchema { members["outputSchema"] = outputSchema }
        return .object(members)
    }

    var capabilityRow: JSONValue {
        let formatControls = Dictionary(
            uniqueKeysWithValues: arguments.compactMap { argument in
                argument.tmuxFormatControl.map {
                    (argument.name, JSONValue.string($0.rawValue))
                }
            }
        )
        return .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "toolset": .string(toolset.rawValue),
            "processReach": .string(processReach.rawValue),
            "tmuxEffects": .array(tmuxEffects.map(\.rawValue).sorted().map(JSONValue.string)),
            "outputClasses": .array(
                outputClasses.map(\.rawValue).sorted().map(JSONValue.string)),
            "mayExposeSecrets": .bool(mayExposeSecrets),
            "mayReturnUntrustedContent": .bool(mayReturnUntrustedContent),
            "annotations": capabilityAnnotations,
            "inputSchema": inputSchema,
            "outputSchema": outputSchema ?? .object([:]),
            "inputLiteralization": .object(formatControls),
            "nestedAuthority": .array(nestedAuthority.sorted().map(JSONValue.string)),
            "amplifiesFutureInput": .bool(amplifiesFutureInput),
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
        do {
            try ToolSchemaValidator.validate(call.arguments, against: tool.inputSchema)
        } catch {
            throw ToolError.wrongArgumentType(
                "arguments",
                expected: "values matching \(tool.name)'s schema (\(error))"
            )
        }
        guard let values = call.arguments.objectValue else {
            throw ToolError.wrongArgumentType("arguments", expected: "an object")
        }
        self.tool = tool
        self.values = values

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

    func value(_ name: String) -> JSONValue? {
        guard let value = resolvedValue(name), !value.isNull else { return nil }
        return value
    }

    private func resolvedValue(_ name: String) -> JSONValue? {
        values[name]
    }

    func string(_ name: String) throws -> String {
        guard let value = resolvedValue(name)?.stringValue else {
            throw ToolError.wrongArgumentType(name, expected: "a string")
        }
        try checkAllowed(name, value)
        try checkLength(name, value)
        return value
    }

    func string(_ name: String, or fallback: String) throws -> String {
        guard let value = resolvedValue(name), !value.isNull else { return fallback }
        guard let text = value.stringValue else {
            throw ToolError.wrongArgumentType(name, expected: "a string")
        }
        try checkAllowed(name, text)
        try checkLength(name, text)
        return text
    }

    func optionalString(_ name: String) throws -> String? {
        guard let value = resolvedValue(name), !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ToolError.wrongArgumentType(name, expected: "a string")
        }
        try checkAllowed(name, text)
        try checkLength(name, text)
        return text
    }

    func strings(_ name: String) throws -> [String] {
        guard let value = resolvedValue(name), !value.isNull else { return [] }
        guard let entries = value.arrayValue else {
            throw ToolError.wrongArgumentType(name, expected: "an array of strings")
        }
        if let maximum = tool.arguments.first(where: { $0.name == name })?.maximumItems,
            entries.count > maximum
        {
            throw ToolError.wrongArgumentType(
                name,
                expected: "an array of at most \(maximum) strings"
            )
        }
        return try entries.map { entry in
            guard let text = entry.stringValue else {
                throw ToolError.wrongArgumentType(name, expected: "an array of strings")
            }
            return text
        }
    }

    func array(_ name: String) throws -> [JSONValue] {
        guard let entries = resolvedValue(name)?.arrayValue else {
            throw ToolError.wrongArgumentType(name, expected: "an array")
        }
        if let maximum = tool.arguments.first(where: { $0.name == name })?.maximumItems,
            entries.count > maximum
        {
            throw ToolError.wrongArgumentType(
                name,
                expected: "an array of at most \(maximum) entries"
            )
        }
        return entries
    }

    func bool(_ name: String, or fallback: Bool) throws -> Bool {
        guard let value = resolvedValue(name), !value.isNull else { return fallback }
        guard let flag = value.boolValue else {
            throw ToolError.wrongArgumentType(name, expected: "true or false")
        }
        return flag
    }

    func integer(_ name: String, or fallback: Int) throws -> Int {
        guard let value = resolvedValue(name), !value.isNull else { return fallback }
        guard let number = value.intValue else {
            throw ToolError.wrongArgumentType(name, expected: "a whole number")
        }
        try checkNumericBounds(name, Double(number))
        return number
    }

    /// Distinguishes an omitted number from one that happens to be zero.
    func optionalInteger(_ name: String) throws -> Int? {
        guard let value = resolvedValue(name), !value.isNull else { return nil }
        guard let number = value.intValue else {
            throw ToolError.wrongArgumentType(name, expected: "a whole number")
        }
        try checkNumericBounds(name, Double(number))
        return number
    }

    private func checkLength(_ name: String, _ value: String) throws {
        guard let maximum = tool.arguments.first(where: { $0.name == name })?.maximumLength,
            value.count > maximum
        else { return }
        throw ToolError.wrongArgumentType(name, expected: "at most \(maximum) characters")
    }

    private func checkAllowed(_ name: String, _ value: String) throws {
        guard let argument = tool.arguments.first(where: { $0.name == name }),
            !argument.allowed.isEmpty,
            !argument.allowed.contains(value)
        else { return }
        throw ToolError.notAllowed(name, value: value, allowed: argument.allowed)
    }

    private func checkNumericBounds(_ name: String, _ value: Double) throws {
        guard let argument = tool.arguments.first(where: { $0.name == name }) else { return }
        guard argument.minimum.map({ value >= $0 }) ?? true,
            argument.maximum.map({ value <= $0 }) ?? true
        else {
            let lower = argument.minimum.map { String($0) } ?? "-infinity"
            let upper = argument.maximum.map { String($0) } ?? "infinity"
            throw ToolError.wrongArgumentType(
                name,
                expected: "a number from \(lower) through \(upper)"
            )
        }
    }
}

/// Why a call could not produce its normal result.
public enum ToolError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownTool(String)
    case missingArgument(String)
    case unknownArguments([String], accepted: [String])
    case wrongArgumentType(String, expected: String)
    case notAllowed(String, value: String, allowed: [String])
    case notEnabled(String)
    case refusedForSafety(String)
    case tmuxRejected(String)
    case tmux(TmuxError)
    case internalFailure(String)

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
        case let .notEnabled(name):
            "\(name) is not enabled by this server's exact tool selection"
        case let .refusedForSafety(reason):
            reason
        case let .tmuxRejected(reason):
            "tmux refused the command: \(reason)"
        case let .tmux(error):
            String(describing: error)
        case let .internalFailure(reason):
            "the tool failed unexpectedly: \(reason)"
        }
    }
}
