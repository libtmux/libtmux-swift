extension TmuxTools {
    static let tmuxDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_command",
            title: "Run one tmux command",
            summary: "Runs one explicitly confirmed raw tmux command in isolation.",
            detail: """
                The unsafe escape hatch for anything above. Prefer a typed tool: this \
                bypasses typed targets, caller protection, and command-specific checks. \
                Arguments are passed to tmux without a shell, so this layer does not \
                expand or word-split them; tmux commands can still run shells, aliases, \
                command lists, and sourced configuration.

                A nonzero exit is reported rather than thrown — `has-session` answers \
                a question that way. The daemon incarnation is checked atomically, the \
                client has a finite deadline, and stdout and stderr are each capped at \
                256 KiB. Directly named terminal commands are refused early, but that \
                convenience check is not a safety boundary.
                """,
            tier: .destructive,
            arguments: [
                serverTarget,
                ToolArgument(
                    name: "command",
                    summary: "The tmux command name, such as new-window.",
                    isRequired: true
                ),
                ToolArgument(
                    name: "arguments",
                    summary: "Its arguments.",
                    kind: .stringArray
                ),
                confirmUnsafe,
                rawCommandTimeout,
            ],
            outputSchema: Schema.object(
                [
                    "serverRef": Schema.string, "exitCode": Schema.integer,
                    "standardOutput": Schema.string,
                    "standardError": Schema.string,
                ], required: ["serverRef", "exitCode", "standardOutput", "standardError"])
        ),
        ToolDefinition(
            name: "run_commands",
            title: "Run several tmux commands",
            summary: "Runs up to 16 confirmed raw tmux commands and attributes each result.",
            detail: """
                The batch form of run_command, with the same unsafe boundary, daemon \
                fence, output cap, and one deadline for the entire batch. Each command \
                uses its own isolated client, so output belongs to the step that \
                produced it rather than to one merged stream.

                Stops at the first failure, as tmux does. Every command that ran \
                carries its own output and status.
                """,
            tier: .destructive,
            arguments: [
                serverTarget,
                ToolArgument(
                    name: "commands",
                    summary:
                        "The commands, as JSON: an array of {command, arguments[]} "
                        + "objects.",
                    kind: .commandArray,
                    isRequired: true
                ),
                confirmUnsafe,
                rawCommandTimeout,
            ],
            outputSchema: Schema.object(
                [
                    "serverRef": Schema.string,
                    "steps": Schema.array(
                        of: Schema.object(
                            [
                                "step": Schema.integer, "command": Schema.string,
                                "exitCode": Schema.integer, "standardOutput": Schema.string,
                                "standardError": Schema.string,
                            ],
                            required: [
                                "step", "command", "exitCode", "standardOutput", "standardError",
                            ])), "requested": Schema.integer, "stoppedEarly": Schema.boolean,
                ], required: ["serverRef", "steps", "requested", "stoppedEarly"])
        ),
    ]
}
