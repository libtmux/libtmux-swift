extension TmuxTools {
    static let drivingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            name: "run_shell",
            title: "Run a shell command in a pane",
            summary:
                "Runs a command line in a pane, waits for it to finish, and reports "
                + "its exit status and output.",
            detail: """
                The tool for a command you wrote. It composes a tmux channel into the \
                command so completion is signalled rather than guessed, which makes it \
                both exact and cheap — no prompt regex, no polling, no scraping.

                Use send_keys instead for keystrokes a program is meant to interpret, \
                for anything interactive, or when the shell state has to persist \
                across calls in a way a one-shot command cannot express.
                """,
            tier: .mutating,
            arguments: [
                paneTarget,
                ToolArgument(
                    name: "command",
                    summary: "The shell command line to run.",
                    isRequired: true
                ),
                ToolArgument(
                    name: "timeout",
                    summary:
                        "Seconds to wait for it to finish. Clamped by the server "
                        + "ceiling. On a timeout the command keeps running in the pane.",
                    kind: .number,
                    defaultValue: .number(30)
                ),
                ToolArgument(
                    name: "max_lines",
                    summary: "Keep at most this many lines of output, dropping the oldest.",
                    kind: .integer,
                    defaultValue: .number(200),
                    minimum: 1,
                    maximum: Double(PaneOutputBudget.maximumLines)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "pane": Schema.string,
                    "exitStatus": Schema.nullableInteger,
                    "timedOut": Schema.boolean, "output": Schema.array(of: Schema.string),
                    "droppedLines": Schema.integer, "seconds": Schema.number,
                    "effectiveTimeout": Schema.number,
                ],
                required: [
                    "paneRef", "pane", "timedOut", "output", "droppedLines", "seconds",
                    "effectiveTimeout",
                ])
        ),
        ToolDefinition(
            name: "send_keys",
            title: "Send keys to a pane",
            summary: "Sends keys to a pane, as if typed.",
            detail: """
                Raw input: no completion is waited for and no output is returned. Key \
                names such as `C-c`, `Enter` and `Escape` are interpreted by tmux \
                unless `literal` is set. For a shell command whose result you want, \
                use run_shell.
                """,
            tier: .mutating,
            arguments: [
                paneTarget,
                ToolArgument(
                    name: "keys",
                    summary:
                        "The keys to send, one entry per key or string. `Enter` is a "
                        + "key name, not a newline.",
                    kind: .stringArray,
                    isRequired: true
                ),
                ToolArgument(
                    name: "literal",
                    summary: "Send the characters as-is, without interpreting key names.",
                    kind: .boolean,
                    defaultValue: .bool(false)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "pane": Schema.string,
                    "keys": Schema.array(of: Schema.string),
                ],
                required: ["paneRef", "pane", "keys"])
        ),
        ToolDefinition(
            name: "new_session",
            title: "Create a session",
            summary: "Creates a detached session and returns it.",
            tier: .mutating,
            isDestructive: false,
            arguments: [
                ToolArgument(
                    name: "name",
                    summary: "What to call it. Must not already exist.",
                    isRequired: true
                ),
                ToolArgument(
                    name: "start_directory",
                    summary: "Where its first window starts."
                ),
                ToolArgument(name: "window_name", summary: "What to call its first window."),
            ],
            outputSchema: Schema.object(
                [
                    "ref": Schema.string, "id": Schema.string, "name": Schema.string,
                    "windowCount": Schema.integer, "isAttached": Schema.boolean,
                    "createdAt": Schema.integer,
                ],
                required: [
                    "ref", "id", "name", "windowCount", "isAttached", "createdAt",
                ])
        ),
        ToolDefinition(
            name: "new_window",
            title: "Create a window",
            summary: "Creates a window in a session and returns it.",
            tier: .mutating,
            isDestructive: false,
            arguments: [
                target("A session ref from list_sessions or snapshot."),
                ToolArgument(name: "name", summary: "What to call it."),
                ToolArgument(name: "start_directory", summary: "Where it starts."),
            ],
            outputSchema: Schema.object(
                [
                    "windowRef": Schema.string, "linkRef": Schema.string,
                    "id": Schema.string, "name": Schema.string, "paneCount": Schema.integer,
                    "width": Schema.integer, "height": Schema.integer,
                    "sessionID": Schema.string, "index": Schema.integer,
                    "isActive": Schema.boolean, "target": Schema.string,
                ],
                required: [
                    "windowRef", "linkRef", "id", "name", "paneCount", "width", "height",
                    "sessionID", "index", "isActive", "target",
                ])
        ),
        ToolDefinition(
            name: "split_pane",
            title: "Split a pane",
            summary: "Splits a pane and returns the new one.",
            tier: .mutating,
            isDestructive: false,
            arguments: [
                paneTarget,
                ToolArgument(
                    name: "direction",
                    summary: "Where the new pane goes, relative to the one being split.",
                    allowed: ["below", "right", "above", "left"],
                    defaultValue: .string("below")
                ),
                ToolArgument(name: "start_directory", summary: "Where the new pane starts."),
            ],
            outputSchema: Schema.object(
                [
                    "ref": Schema.string, "id": Schema.string, "index": Schema.integer,
                    "width": Schema.integer, "height": Schema.integer,
                    "isActive": Schema.boolean, "currentCommand": Schema.string,
                    "currentPath": Schema.string, "isAtTop": Schema.boolean,
                    "isAtBottom": Schema.boolean, "isAtLeft": Schema.boolean,
                    "isAtRight": Schema.boolean, "windowID": Schema.string,
                ],
                required: [
                    "ref", "id", "index", "width", "height", "isActive", "currentCommand",
                    "currentPath", "isAtTop", "isAtBottom", "isAtLeft", "isAtRight",
                    "windowID",
                ])
        ),
        ToolDefinition(
            name: "apply_workspace",
            title: "Build a session from a plan",
            summary:
                "Builds a whole session — windows, panes, directories, commands — "
                + "from one declarative plan.",
            detail: """
                One call instead of a create-split-split-send sequence whose pane refs \
                you have to thread by hand. The plan is tmuxp's shape, so an existing \
                workspace file can be passed through unchanged.

                Refuses rather than adopting a session that already exists, so two \
                callers building the same workspace never silently share one.
                """,
            tier: .mutating,
            arguments: [
                ToolArgument(
                    name: "plan",
                    summary:
                        "The workspace, as JSON: session_name, optional "
                        + "start_directory, and windows[] each with panes[].",
                    kind: .object,
                    isRequired: true
                )
            ],
            outputSchema: Schema.object(
                [
                    "session": Schema.object(
                        [
                            "ref": Schema.string, "id": Schema.string, "name": Schema.string,
                            "windowCount": Schema.integer, "isAttached": Schema.boolean,
                            "createdAt": Schema.integer,
                        ],
                        required: [
                            "ref", "id", "name", "windowCount", "isAttached", "createdAt",
                        ]),
                    "windows": Schema.array(
                        of: Schema.object(
                            [
                                "windowRef": Schema.string, "linkRef": Schema.string,
                                "id": Schema.string, "name": Schema.string,
                                "paneCount": Schema.integer, "width": Schema.integer,
                                "height": Schema.integer, "sessionID": Schema.string,
                                "index": Schema.integer, "isActive": Schema.boolean,
                                "target": Schema.string,
                            ],
                            required: [
                                "windowRef", "linkRef", "id", "name", "paneCount", "width",
                                "height", "sessionID", "index", "isActive", "target",
                            ])),
                    "panes": Schema.array(
                        of: Schema.object(
                            [
                                "ref": Schema.string, "id": Schema.string,
                                "index": Schema.integer, "width": Schema.integer,
                                "height": Schema.integer, "isActive": Schema.boolean,
                                "currentCommand": Schema.string, "currentPath": Schema.string,
                                "isAtTop": Schema.boolean, "isAtBottom": Schema.boolean,
                                "isAtLeft": Schema.boolean, "isAtRight": Schema.boolean,
                                "windowID": Schema.string,
                            ],
                            required: [
                                "ref", "id", "index", "width", "height", "isActive",
                                "currentCommand", "currentPath", "isAtTop", "isAtBottom",
                                "isAtLeft", "isAtRight", "windowID",
                            ])),
                ],
                required: ["session", "windows", "panes"])
        ),
        ToolDefinition(
            name: "rename",
            title: "Rename a session or window",
            summary: "Gives a session or window a new name.",
            detail: """
                Names are what a person reads; ids are what a tool should target. \
                Renaming does not change an id, so anything already holding one \
                keeps working.
                """,
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                target("A session ref or global windowRef to rename."),
                ToolArgument(name: "name", summary: "What to call it.", isRequired: true),
            ],
            outputSchema: Schema.object(
                [
                    "ref": Schema.string, "kind": Schema.string, "id": Schema.string,
                    "name": Schema.string,
                ],
                required: ["ref", "kind", "id", "name"]
            )
        ),
        ToolDefinition(
            name: "select",
            title: "Make a pane or window active",
            summary: "Changes which pane or window is the active one.",
            detail: """
                Worth knowing because "active" is what a command reaches when it \
                names a window and stops there — so this changes what later calls \
                mean, not just what a person would see.
                """,
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                target(
                    "A pane ref from list_panes or exact linkRef from list_windows."
                )
            ],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"]
            )
        ),
        ToolDefinition(
            name: "resize_pane",
            title: "Resize a pane",
            summary: "Sets a pane's width or height in cells.",
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                paneTarget,
                ToolArgument(name: "width", summary: "Columns.", kind: .integer),
                ToolArgument(name: "height", summary: "Rows.", kind: .integer),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "pane": Schema.string, "width": Schema.integer,
                    "height": Schema.integer,
                ],
                required: ["paneRef", "pane", "width", "height"]
            )
        ),
        ToolDefinition(
            name: "select_layout",
            title: "Apply a layout to a window",
            summary: "Rearranges a window's panes with one of tmux's own layouts.",
            detail: """
                One call instead of resizing panes individually, and the result is \
                a layout tmux maintains rather than sizes that drift as panes come \
                and go.
                """,
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                target("A global windowRef from list_windows or snapshot."),
                ToolArgument(
                    name: "layout",
                    summary: "A tmux layout name, or a layout string tmux printed.",
                    isRequired: true,
                    allowed: [
                        "even-horizontal", "even-vertical", "main-horizontal",
                        "main-vertical", "tiled",
                    ]
                ),
            ],
            outputSchema: Schema.object(
                [
                    "windowRef": Schema.string, "window": Schema.string,
                    "layout": Schema.string,
                ],
                required: ["windowRef", "window", "layout"]
            )
        ),
        ToolDefinition(
            name: "respawn_pane",
            title: "Restart what runs in a pane",
            summary: "Replaces the process in a pane, keeping the pane itself.",
            detail: """
                The recovery action: a pane whose program has wedged or exited \
                gets a new one without the pane ref changing, so anything holding \
                that ref keeps working. Watchers are told — capture_since reports \
                `restarted` rather than reading the new program's output as a \
                continuation of the old one's.
                """,
            tier: .destructive,
            arguments: [
                paneTarget,
                ToolArgument(
                    name: "command",
                    summary: "What to run. Omit for the pane's default command.",
                    kind: .stringArray
                ),
                confirmSelf,
            ],
            outputSchema: Schema.object(
                ["paneRef": Schema.string, "pane": Schema.string],
                required: ["paneRef", "pane"]
            )
        ),
        ToolDefinition(
            name: "paste_text",
            title: "Paste text into a pane",
            summary:
                "Puts text into a pane without any of it being read as a key name.",
            detail: """
                send_keys interprets `C-c`, `Enter` and the rest, which is what \
                you want for driving a program and exactly wrong for text that \
                might contain them. This pastes, so the content arrives as \
                content.

                The staging buffer is deleted afterwards, so nothing is left in \
                tmux's paste history.
                """,
            tier: .mutating,
            arguments: [
                paneTarget,
                ToolArgument(
                    name: "text",
                    summary: "The text to paste.",
                    isRequired: true
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "pane": Schema.string,
                    "characters": Schema.integer,
                ],
                required: ["paneRef", "pane", "characters"]
            )
        ),
        ToolDefinition(
            name: "set_environment",
            title: "Set what new panes inherit",
            summary: "Sets a global variable in the environment tmux gives new processes.",
            detail: """
                Takes effect for panes started *after* it. A pane already running \
                has the environment it was given, and nothing can reach into it.
                """,
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                ToolArgument(name: "name", summary: "The variable.", isRequired: true),
                ToolArgument(
                    name: "value",
                    summary: "What to set it to. Omit to unset it.",
                ),
            ],
            outputSchema: Schema.object(
                [
                    "serverRef": Schema.string, "name": Schema.string,
                    "value": Schema.nullableString,
                ],
                required: ["serverRef", "name"]
            )
        ),
        ToolDefinition(
            name: "set_option",
            title: "Set a tmux option",
            summary: "Sets a server or global tmux option.",
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                ToolArgument(name: "name", summary: "The option name.", isRequired: true),
                ToolArgument(name: "value", summary: "What to set it to.", isRequired: true),
                ToolArgument(
                    name: "scope",
                    summary: "The server table, or the global session table.",
                    allowed: ["server", "global"],
                    defaultValue: .string("server")
                ),
            ],
            outputSchema: Schema.object(
                [
                    "serverRef": Schema.string, "exitCode": Schema.integer,
                    "standardOutput": Schema.string,
                    "standardError": Schema.string,
                ], required: ["serverRef", "exitCode", "standardOutput", "standardError"])
        ),
    ]
}
