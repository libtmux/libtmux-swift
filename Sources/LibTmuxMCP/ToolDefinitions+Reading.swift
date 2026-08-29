extension TmuxTools {
    static let readingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "list_sessions",
            title: "List sessions",
            summary: "Every session, optionally selected by what its panes are running.",
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "pane_relation",
                    summary:
                        "A quantifier (some, every, none) and a pane filter, as JSON, "
                        + "selecting sessions by their panes.",
                    kind: .object
                ),
                fields,
            ],
            outputSchema: Schema.listing("sessions")
        ),
        ToolDefinition(
            name: "list_windows",
            title: "List windows",
            summary:
                "Every session-local window occurrence, optionally filtered by its "
                + "global window facts.",
            detail: """
                Each row carries a process-local ref for later reads. Re-list after this MCP \
                process restarts. \
                A global window can be linked into several sessions or more than once in \
                one session. Each occurrence therefore repeats the global id, name, size \
                and pane count and adds sessionID, index, isActive and the exact \
                $session:index target. A filter evaluates the global Window first, then \
                returns every link to each matching window.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "filter",
                    summary:
                        "A Window filter expression as JSON, as described by "
                        + "describe_filters. Link fields such as target are not filterable.",
                    kind: .object
                ),
                fields,
            ],
            outputSchema: Schema.listing("windows")
        ),
        ToolDefinition(
            name: "list_panes",
            title: "List panes",
            summary: "Every pane on the server, optionally filtered.",
            detail: """
                Each row carries a process-local ref for later reads. Re-list after this MCP \
                process restarts. \
                Searches pane *metadata* — what a pane is running, where it is, how \
                big it is. For what a pane has printed, use search_panes or \
                capture_pane; no filter here reads terminal text.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "filter",
                    summary: "A filter expression as JSON, as described by describe_filters.",
                    kind: .object
                ),
                fields,
            ],
            outputSchema: Schema.listing("panes")
        ),
        ToolDefinition(
            name: "snapshot",
            title: "Read the server as one value",
            summary:
                "Sessions, global windows, exact window links, panes and clients in one value.",
            detail: """
                One tool call instead of walking the hierarchy level by level. The \
                daemon identity is checked before and after the listings, so a daemon \
                replacement is reported. Another client can mutate the same daemon \
                between listings, so the result is not a tmux transaction. The answer \
                carries hierarchy facts, not the endpoint or socket path used to read \
                them. Its refs expire when this MCP process restarts. Prefer this whenever \
                you want more than one level.
                """,
            tier: .readonly,
            isIdempotent: true
        ),
        ToolDefinition(
            name: "capture_pane",
            title: "Read a pane's contents",
            summary: "The text a pane is showing, as a person would read it.",
            detail: """
                Returns the rendered grid, so escape sequences and cursor motion are \
                already resolved. For watching a pane over time, wait_for_output \
                costs less: this returns everything every call, most of which you \
                have already seen.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                paneReadTarget,
                ToolArgument(
                    name: "history",
                    summary: "Include the scrollback from its start, not just the visible rows.",
                    kind: .boolean,
                    defaultValue: .bool(false)
                ),
                ToolArgument(
                    name: "max_lines",
                    summary:
                        "Keep at most this many lines, dropping the oldest. The end of "
                        + "a pane is almost always the part that matters.",
                    kind: .integer,
                    defaultValue: .number(200)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "pane": Schema.string,
                    "lines": Schema.array(of: Schema.string),
                    "droppedLines": Schema.integer,
                ], required: ["paneRef", "pane", "lines", "droppedLines"])
        ),
        ToolDefinition(
            name: "capture_since",
            title: "Read what a pane has printed since last time",
            summary:
                "Answers only what is new since a cursor, so watching a pane "
                + "does not re-send what you have already read.",
            detail: """
                The tool for watching something over several turns. Call it once \
                with no cursor to start — it answers nothing and hands back a \
                mark — then pass that cursor to each later call and get only the \
                difference. A pane that has been quiet answers an empty list.

                `linesMissed` says the pane scrolled further than its history \
                keeps, so some output is gone for good. `restarted` says the pane \
                was respawned, so the cursor described a program that is no longer \
                running.

                Use wait_for_output instead when you want to block until something \
                appears rather than to check what has appeared.
                """,
            tier: .readonly,
            arguments: [
                paneReadTarget,
                ToolArgument(
                    name: "cursor",
                    summary:
                        "The cursor a previous call returned. Omit to start "
                        + "watching from now."
                ),
                ToolArgument(
                    name: "max_lines",
                    summary: "Keep at most this many new lines, dropping the oldest.",
                    kind: .integer,
                    defaultValue: .number(200)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "pane": Schema.string,
                    "lines": Schema.array(of: Schema.string),
                    "cursor": Schema.string,
                    "linesMissed": Schema.boolean,
                    "restarted": Schema.boolean,
                ],
                required: [
                    "paneRef", "pane", "lines", "cursor", "linesMissed", "restarted",
                ]
            )
        ),
        ToolDefinition(
            name: "search_panes",
            title: "Search what panes have printed",
            summary: "Finds a regular expression in the contents of every pane.",
            detail: """
                The tool for "which pane mentions X". Reads content, where list_panes \
                reads metadata. Each match carries its pane ref and line, so the answer \
                is directly actionable.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "pattern",
                    summary: "A regular expression to look for.",
                    isRequired: true
                ),
                ToolArgument(
                    name: "filter",
                    summary:
                        "A pane filter as JSON, to search a subset. Searching every "
                        + "pane on a busy server is the expensive case.",
                    kind: .object
                ),
                ToolArgument(
                    name: "history",
                    summary: "Search the scrollback too, not just the visible rows.",
                    kind: .boolean,
                    defaultValue: .bool(false)
                ),
                ToolArgument(
                    name: "max_matches",
                    summary: "Stop after this many matches.",
                    kind: .integer,
                    defaultValue: .number(50)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "matches": Schema.array(
                        of: Schema.object(
                            [
                                "paneRef": Schema.string, "pane": Schema.string,
                                "line": Schema.integer, "text": Schema.string,
                            ],
                            required: ["paneRef", "pane", "line", "text"])),
                    "panesSearched": Schema.integer,
                    "panesAvailable": Schema.integer, "truncated": Schema.boolean,
                ], required: ["matches", "panesSearched", "panesAvailable", "truncated"])
        ),
        ToolDefinition(
            name: "read_format",
            title: "Evaluate a tmux format",
            summary:
                "Evaluates any tmux format, reaching fields the listings do not carry.",
            detail: """
                The escape hatch for anything tmux can report but this server does not \
                model — `#{pane_dead}` or `#{window_bell_flag}`. \
                A stale target ref is refused; re-list after this MCP process restarts. \
                With no target, null means tmux returned no server-level value, while \
                an empty field is `""`.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "template",
                    summary: "A tmux format, such as #{pane_current_command}.",
                    isRequired: true
                ),
                target(
                    "A session ref, exact window linkRef, or pane ref; omit for the server.",
                    required: false
                ),
                ToolArgument(
                    name: "window_link",
                    summary:
                        "Exact linkRef for a pane whose window has several links. "
                        + "Returned by list_windows."
                ),
            ],
            outputSchema: Schema.object(["value": Schema.nullableString])
        ),

        ToolDefinition(
            name: "show_options",
            title: "Read tmux options",
            summary: "What a tmux option is set to, or every option in a table.",
            detail: """
                Reports what tmux has been *told*, not its built-in defaults, so \
                a fresh server's session table is legitimately empty. The \
                counterpart to set_option: reading configuration and changing it \
                should not need two different mental models.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "name",
                    summary: "One option to read. Omit for every option in the table."
                ),
                ToolArgument(
                    name: "scope",
                    summary: "Which level to read.",
                    allowed: ["server", "session", "window", "pane"],
                    defaultValue: .string("server")
                ),
                ToolArgument(
                    name: "global",
                    summary: "Read the global table rather than the object's own.",
                    kind: .boolean,
                    defaultValue: .bool(false)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "options": Schema.array(
                        of: Schema.object(
                            ["name": Schema.string, "value": Schema.string],
                            required: ["name", "value"]
                        )
                    )
                ],
                required: ["options"]
            )
        ),
        ToolDefinition(
            name: "show_environment",
            title: "Read the environment new panes inherit",
            summary:
                "The global variables tmux gives a process it starts, which is not this "
                + "process's environment.",
            detail: """
                A pane inherits tmux's environment, not the one the client was \
                launched with. This is where to look when a command works in your \
                shell and not in a pane, and set_environment is where to fix it — \
                for panes started *after* the change.
                """,
            tier: .readonly,
            isIdempotent: true,
            outputSchema: Schema.object(
                [
                    "variables": Schema.array(
                        of: Schema.object(
                            ["name": Schema.string, "value": Schema.nullableString],
                            required: ["name"]
                        )
                    )
                ],
                required: ["variables"]
            )
        ),
        ToolDefinition(
            name: "show_hooks",
            title: "Read the hooks that are bound",
            summary: "The global commands tmux runs when something happens.",
            detail: """
                Read-only on purpose. A hook outlives this process — it is server \
                state, not a subscription — so one written from here would keep \
                firing long after the conversation that set it ended, with nothing \
                to say where it came from. Put hooks in your tmux config, where \
                they can be read and removed.

                Only bound hooks are listed. tmux knows many names with nothing \
                on them, and an unbound name is a place a hook could go rather \
                than a hook.
                """,
            tier: .readonly,
            isIdempotent: true,
            outputSchema: Schema.object(
                [
                    "hooks": Schema.array(
                        of: Schema.object(
                            [
                                "name": Schema.string,
                                "index": Schema.integer,
                                "command": Schema.string,
                            ],
                            required: ["name", "index", "command"]
                        )
                    )
                ],
                required: ["hooks"]
            )
        ),
    ]
}
