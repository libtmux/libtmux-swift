extension TmuxTools {
    static let endingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            operation: .killPane,
            title: "Kill a pane",
            summary: "Ends a pane and whatever is running in it.",
            tier: .destructive,
            arguments: [paneTarget, confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"])
        ),
        ToolDefinition(
            operation: .killWindow,
            title: "Kill a window",
            summary: "Ends a window and every pane in it.",
            tier: .destructive,
            arguments: [target("A global windowRef to kill."), confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"])
        ),
        ToolDefinition(
            operation: .killSession,
            title: "Kill a session",
            summary: "Ends a session and every window in it.",
            tier: .destructive,
            arguments: [target("A session ref to kill."), confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"])
        ),

        ToolDefinition(
            operation: .killServer,
            title: "Kill the whole tmux server",
            summary: "Ends every session on this server, and the server with them.",
            tier: .destructive,
            arguments: [serverTarget, confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"]
            )
        ),
    ]
}
