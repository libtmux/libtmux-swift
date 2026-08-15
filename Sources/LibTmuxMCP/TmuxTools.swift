import Foundation
import LibTmux

/// The tmux tools an MCP client can call.
///
/// This is the layer that puts `LibTmux` across a process boundary, which is
/// what a filter expression was designed for: a client sends the expression as
/// data and the tool evaluates it here, rather than the client asking for
/// everything and filtering at home.
public struct TmuxTools: Sendable {
    private let server: Server

    public init(server: Server) {
        self.server = server
    }

    /// Every tool, with the arguments it takes.
    ///
    /// `describeFilters` is what makes the rest usable: a client that does not
    /// speak Swift learns the filterable vocabulary from it instead of hard
    /// coding field names that a rename would break.
    public static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "list_sessions",
            summary: "Every session on the server, optionally by what its panes run.",
            arguments: [
                ArgumentDefinition(
                    name: "paneRelation",
                    summary:
                        "A quantifier (some, every, none) and a pane filter, "
                        + "selecting sessions by their panes.",
                    isRequired: false
                )
            ]
        ),
        ToolDefinition(
            name: "list_windows",
            summary: "Every window on the server.",
            arguments: []
        ),
        ToolDefinition(
            name: "list_panes",
            summary: "Every pane on the server, optionally filtered.",
            arguments: [
                ArgumentDefinition(
                    name: "filter",
                    summary: "A filter expression, as described by describe_filters.",
                    isRequired: false
                )
            ]
        ),
        ToolDefinition(
            name: "describe_filters",
            summary: "The filterable fields, their types, and their aliases.",
            arguments: []
        ),
        ToolDefinition(
            name: "read_format",
            summary:
                "Evaluates a tmux format, reaching fields the listings do not "
                + "carry.",
            arguments: [
                ArgumentDefinition(
                    name: "template",
                    summary: "A tmux format, such as #{pane_current_command}.",
                    isRequired: true
                ),
                ArgumentDefinition(
                    name: "target",
                    summary:
                        "A tmux id — $0, @1, %2 — or omitted to ask about the "
                        + "server itself.",
                    isRequired: false
                ),
            ]
        ),
        ToolDefinition(
            name: "run_command",
            summary: "Runs one tmux command and returns what tmux said.",
            arguments: [
                ArgumentDefinition(
                    name: "command",
                    summary: "The tmux command name, such as new-window.",
                    isRequired: true
                ),
                ArgumentDefinition(
                    name: "arguments",
                    summary: "Arguments, passed to tmux without a shell.",
                    isRequired: false
                ),
            ]
        ),
    ]

    /// Calls a tool and returns its JSON result.
    public func call(_ request: ToolCall) async throws -> Data {
        switch request.name {
        case "list_sessions":
            guard let relation = request.paneRelation else {
                return try encode(await server.sessions())
            }
            // A relation filter needs the related objects in hand, so this is
            // the one listing that reads a whole snapshot.
            let query = try JSONDecoder().decode(
                RelationQuery<Pane>.self,
                from: Data(relation.utf8)
            )
            return try encode(await server.snapshot().sessions(ofPanes: query))
        case "list_windows":
            return try encode(await server.windows())
        case "list_panes":
            let panes = try await server.panes()
            guard let filter = request.filter else { return try encode(panes) }
            let expression = try JSONDecoder().decode(
                FilterExpr<Pane>.self,
                from: Data(filter.utf8)
            )
            return try encode(panes.filter(expression))
        case "describe_filters":
            return try encode(FilterSchema.current)
        case "read_format":
            guard let template = request.template else {
                throw ToolError.missingArgument("template")
            }
            let value =
                if let target = request.target {
                    try await server.format(template, addressing: target)
                } else {
                    try await server.format(template)
                }
            return try encode(FormatResult(value: value))
        case "run_command":
            guard let command = request.command else {
                throw ToolError.missingArgument("command")
            }
            let reply = try await server.run(
                TmuxCommand(command, request.arguments ?? [])
            )
            return try encode(
                CommandResult(
                    exitCode: reply.exitCode,
                    standardOutput: reply.text,
                    standardError: reply.errorText
                )
            )
        default:
            throw ToolError.unknownTool(request.name)
        }
    }

    private func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

/// One tool a client can call, described well enough to call it without
/// reading this source.
public struct ToolDefinition: Sendable, Hashable, Codable {
    /// What the client names in a ``ToolCall``.
    public let name: String
    /// What the tool answers, in one line, for a client choosing between them.
    public let summary: String
    /// Everything it accepts. An empty list means the tool takes nothing.
    public let arguments: [ArgumentDefinition]
}

/// One argument of a tool.
public struct ArgumentDefinition: Sendable, Hashable, Codable {
    /// The key the client sets on the call.
    public let name: String
    /// What the argument selects, and the shape it has to arrive in.
    public let summary: String
    /// Whether omitting it is an error rather than a default.
    public let isRequired: Bool
}

/// One tool call, as it arrives.
public struct ToolCall: Sendable, Hashable, Codable {
    /// Which tool to run, matching a ``ToolDefinition/name``.
    public let name: String
    /// A `FilterExpr` encoded as JSON text. It arrives as data because that is
    /// the whole point: a closure could not cross this boundary.
    public let filter: String?
    /// A `RelationQuery` encoded as JSON text. Quantifier and expression travel
    /// together, so the boundary never has to reassemble them.
    public let paneRelation: String?
    /// The format `read_format` evaluates.
    public let template: String?
    /// The tmux id `read_format` evaluates it against, or nothing to ask about
    /// the server itself.
    public let target: String?
    /// The tmux command name for `run_command` — `new-window`, and the rest.
    public let command: String?
    /// Its arguments, passed to tmux without a shell, so nothing here is
    /// expanded or word-split on the way.
    public let arguments: [String]?

    public init(
        name: String,
        filter: String? = nil,
        paneRelation: String? = nil,
        template: String? = nil,
        target: String? = nil,
        command: String? = nil,
        arguments: [String]? = nil
    ) {
        self.name = name
        self.filter = filter
        self.paneRelation = paneRelation
        self.template = template
        self.target = target
        self.command = command
        self.arguments = arguments
    }
}

/// What a format evaluated to.
///
/// Wrapped rather than returned as bare text so the answer stays distinct from
/// the absence of one: a target that no longer resolves reports `null`, where a
/// field that is legitimately empty reports `""`.
public struct FormatResult: Sendable, Hashable, Codable {
    /// What tmux printed, or nothing when the target has gone.
    public let value: String?
}

/// What tmux said, in a shape a client can read without knowing tmux's
/// conventions. A nonzero exit is reported, not thrown: a client asking whether
/// a session exists wants the answer, not an error.
public struct CommandResult: Sendable, Hashable, Codable {
    /// tmux's exit status. Nonzero is an answer, not a failure.
    public let exitCode: Int32
    /// What the command printed.
    public let standardOutput: String
    /// Where tmux explains a command it refused.
    public let standardError: String
}

/// Why a call could not be run at all, as distinct from a tmux command that
/// ran and reported a nonzero status.
public enum ToolError: Error, Sendable, Hashable {
    case unknownTool(String)
    case missingArgument(String)
}
