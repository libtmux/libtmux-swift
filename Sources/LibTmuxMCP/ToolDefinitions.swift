import Foundation

// Every tool this server offers, with the schema and the behaviour hints a
// client reads before calling one. Descriptions are written for a model
// choosing between neighbouring tools, which is the decision that actually goes
// wrong: `capture_pane` and `wait_for_output` both "read a pane", and only the
// description says which question each answers.

extension TmuxTools {
    /// Shared by every tool that names one tmux object.
    static func target(
        _ summary: String,
        required: Bool = true
    ) -> ToolArgument {
        ToolArgument(name: "target", summary: summary, isRequired: required)
    }

    static let paneTarget = ToolArgument(
        name: "pane",
        summary:
            "A pane ref returned by list_panes or snapshot. Re-list after this MCP "
            + "process restarts.",
        isRequired: true
    )

    static let paneWindowLink = ToolArgument(
        name: "window_link",
        summary: "Exact linkRef from list_windows. Required only when the pane has several links."
    )

    static let serverTarget = ToolArgument(
        name: "server_ref",
        summary:
            "The current server ref returned by describe_server. Re-read it after MCP restart.",
        isRequired: true
    )

    static let fields = ToolArgument(
        name: "fields",
        summary:
            "Only these response fields from each record. Omit for every field. "
            + "Use it when one field answers the question — a listing of a busy "
            + "server is mostly context you will not read. Target refs are always retained.",
        kind: .stringArray
    )

    static let confirmSelf = ToolArgument(
        name: "confirm_self",
        summary:
            "Proceed when a target is, or could become, a container of this MCP's pane. "
            + "Window and session kills on the caller's server require this because "
            + "membership can change before a separate kill executes.",
        kind: .boolean,
        defaultValue: .bool(false)
    )

    static let confirmUnsafe = ToolArgument(
        name: "confirm_unsafe",
        summary:
            "Set true to acknowledge that a raw tmux command bypasses typed target, "
            + "caller, and command-specific safety checks.",
        kind: .boolean,
        isRequired: true
    )

    static let rawCommandTimeout = ToolArgument(
        name: "timeout",
        summary:
            "Seconds before the isolated tmux client is cancelled. Clamped to the "
            + "server wait ceiling.",
        kind: .number,
        defaultValue: .number(10)
    )

    /// Every tool, in the order a client sees them.
    public static let definitions: [ToolDefinition] = [
        orientationDefinitions,
        readingDefinitions,
        waitingDefinitions,
        drivingDefinitions,
        endingDefinitions,
        tmuxDefinitions,
    ].flatMap { $0 }

    static let byName: [String: ToolDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.name, $0) }
    )
}
