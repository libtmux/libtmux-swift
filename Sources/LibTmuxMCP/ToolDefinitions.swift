import Foundation

// Every tool this server offers, with the schema and the behaviour hints a
// client reads before calling one. Descriptions are written for a model
// choosing between neighbouring tools, which is the decision that actually goes
// wrong: `capture_pane` and `wait_for_output` both "read a pane", and only the
// description says which question each answers.

extension TmuxTools {
    /// Shared by every tool that names one tmux object.
    private static func target(
        _ summary: String,
        required: Bool = true
    ) -> ToolArgument {
        ToolArgument(name: "target", summary: summary, isRequired: required)
    }

    private static let paneTarget = ToolArgument(
        name: "pane",
        summary:
            "A pane ref returned by list_panes or snapshot. Re-list after this MCP "
            + "process restarts.",
        isRequired: true
    )

    private static let paneReadTarget = ToolArgument(
        name: "pane",
        summary:
            "A pane ref returned by list_panes or snapshot. Re-list after this MCP "
            + "process restarts.",
        isRequired: true
    )

    private static let paneWindowLink = ToolArgument(
        name: "window_link",
        summary: "Exact linkRef from list_windows. Required only when the pane has several links."
    )

    private static let serverTarget = ToolArgument(
        name: "server_ref",
        summary:
            "The current server ref returned by describe_server. Re-read it after MCP restart.",
        isRequired: true
    )

    private static let fields = ToolArgument(
        name: "fields",
        summary:
            "Only these response fields from each record. Omit for every field. "
            + "Use it when one field answers the question — a listing of a busy "
            + "server is mostly context you will not read. Target refs are always retained.",
        kind: .stringArray
    )

    private static let confirmSelf = ToolArgument(
        name: "confirm_self",
        summary:
            "Proceed when a target is, or could become, a container of this MCP's pane. "
            + "Window and session kills on the caller's server require this because "
            + "membership can change before a separate kill executes.",
        kind: .boolean,
        defaultValue: .bool(false)
    )

    private static let confirmUnsafe = ToolArgument(
        name: "confirm_unsafe",
        summary:
            "Set true to acknowledge that a raw tmux command bypasses typed target, "
            + "caller, and command-specific safety checks.",
        kind: .boolean,
        isRequired: true
    )

    private static let rawCommandTimeout = ToolArgument(
        name: "timeout",
        summary:
            "Seconds before the isolated tmux client is cancelled. Clamped to the "
            + "server wait ceiling.",
        kind: .number,
        defaultValue: .number(10)
    )

    /// Every tool, in the order a client sees them.
    public static let definitions: [ToolDefinition] = [
        // MARK: Orientation

        ToolDefinition(
            name: "describe_server",
            title: "Describe this server",
            summary:
                "What tmux this is, which optional features it supports, and where "
                + "the caller sits in it.",
            detail: """
                Call this first in an unfamiliar session. It answers, in one call, \
                the questions that otherwise cost a turn each: the tmux version and \
                whether it is inside the supported range, which pane this MCP is \
                running in (so you never kill your own), the safety tier in force, \
                and the ceiling every wait is clamped to.
                """,
            tier: .readonly,
            isIdempotent: true,
            outputSchema: Schema.object(
                [
                    "ref": Schema.string, "endpoint": Schema.string,
                    "tmuxVersion": Schema.nullableString,
                    "isSupported": .object(["type": .array([.string("boolean"), .string("null")])]),
                    "serverProcessID": Schema.nullableInteger, "sessionCount": Schema.integer,
                    "safetyTier": Schema.string, "waitCeilingSeconds": Schema.number,
                    "callerPane": Schema.nullableString, "callerSession": Schema.nullableString,
                    "capabilities": Schema.object(
                        [
                            "formatSubscriptions": Schema.boolean, "pushOutput": Schema.boolean,
                            "controlModeBatching": Schema.boolean,
                        ], required: ["formatSubscriptions", "pushOutput", "controlModeBatching"]),
                ],
                required: [
                    "ref", "endpoint", "sessionCount", "safetyTier", "waitCeilingSeconds",
                    "capabilities",
                ])
        ),
        ToolDefinition(
            name: "list_servers",
            title: "Find the tmux servers that are running",
            summary:
                "Every tmux server listening on a socket, which is the one "
                + "question no other tool can answer.",
            detail: """
                Everything else here addresses the server this process was \
                pointed at. This says what else is there — for arriving in an \
                unfamiliar machine, or for noticing that the session you want is \
                on a different socket.

                A socket file is not a running server: tmux leaves the file \
                behind when it exits, so each one is asked whether it answers \
                and the ones that do not are left out.
                """,
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "directories",
                    summary:
                        "Where to look. Defaults to TMUX_TMPDIR, or tmux's own "
                        + "default socket directory for this user.",
                    kind: .stringArray
                )
            ],
            outputSchema: Schema.object(
                [
                    "servers": Schema.array(
                        of: Schema.object(
                            [
                                "socketPath": Schema.string,
                                "processID": Schema.nullableInteger,
                                "sessionCount": Schema.integer,
                            ],
                            required: ["socketPath", "sessionCount"]
                        )
                    )
                ],
                required: ["servers"]
            )
        ),
        ToolDefinition(
            name: "describe_filters",
            title: "Describe the filter vocabulary",
            summary: "The filterable fields of each object, their types, and aliases.",
            detail: """
                Read this before writing a `filter` argument. The vocabulary is \
                generated from the same registry the library filters through, so a \
                field named here is one that works, and a rename carries its old \
                name as an alias rather than breaking a stored expression.
                """,
            tier: .readonly,
            isIdempotent: true
        ),

        // MARK: Reading

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

        // MARK: Waiting

        ToolDefinition(
            name: "wait_for_output",
            title: "Wait for a pane to print something",
            summary:
                "Blocks until a pane prints matching text, with tmux output events "
                + "driving each capture.",
            detail: """
                For output you did not author: a daemon printing `ready`, a dev server \
                someone else started, a build you attached to. tmux pushes pane output \
                over a control connection. A low-rate liveness check detects a pane \
                removed while it is quiet.

                Omit `patterns` to wait for any new output at all — the right choice \
                when what will be printed is not known. Always pass `stops` when a \
                failure marker exists: a build that fails after five seconds should \
                not hold this open for the rest of the timeout.

                The condition is checked before it is blocked on: text already on \
                screen returns at once with `matchedAtEntry: true`, because "wait \
                until it is listening" is answered by something already listening. \
                Set `require_fresh` when only a NEW occurrence counts — re-running a \
                command whose output looks identical to last time.

                Read the result before changing anything:
                - `sawNewOutput: false`, `matchedAtEntry: false` — the pane stayed \
                quiet. The thing never ran; no pattern fixes that.
                - `outcome: "timedOut"` with output — it printed something else. \
                `tail` holds what it actually said; fix the pattern from that.
                - `outcome: "stopped"` — a `stops` marker hit. `matched` says which.

                For a command you wrote yourself, run_shell is cheaper and exact.
                """,
            tier: .readonly,
            arguments: [
                paneReadTarget,
                ToolArgument(
                    name: "patterns",
                    summary:
                        "Regular expressions, any of which ends the wait. Omit for "
                        + "any new output at all.",
                    kind: .stringArray
                ),
                ToolArgument(
                    name: "stops",
                    summary:
                        "Regular expressions that end the wait as a failure. Put error "
                        + "markers here.",
                    kind: .stringArray
                ),
                ToolArgument(
                    name: "require_fresh",
                    summary:
                        "Only count output that arrives after this call, so a match "
                        + "already on screen is waited past rather than returned. For "
                        + "re-running a command whose output looks identical.",
                    kind: .boolean,
                    defaultValue: .bool(false)
                ),
                ToolArgument(
                    name: "timeout",
                    summary:
                        "Seconds to wait. Clamped by the server ceiling; the result "
                        + "reports what was actually enforced.",
                    kind: .number,
                    defaultValue: .number(30)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "outcome": Schema.string,
                    "matched": Schema.nullableString,
                    "matchedIndex": Schema.nullableInteger, "sawNewOutput": Schema.boolean,
                    "matchedAtEntry": Schema.boolean, "tail": Schema.array(of: Schema.string),
                    "seconds": Schema.number, "effectiveTimeout": Schema.number,
                ],
                required: [
                    "paneRef", "outcome", "sawNewOutput", "matchedAtEntry", "tail",
                    "seconds", "effectiveTimeout",
                ])
        ),
        ToolDefinition(
            name: "watch_format",
            title: "Wait for a tmux format to change",
            summary:
                "Blocks until a tmux format takes a matching value, without reading "
                + "any scrollback.",
            detail: """
                The cheapest wait there is, and the one to reach for when the question \
                is about *state* rather than text: has the foreground command changed, \
                has the pane died, has a window rung its bell. tmux evaluates the \
                format and reports changes itself.

                `#{pane_current_command}` answers "is my command done?" exactly, with \
                no prompt regex to guess and no output to read back. Values are \
                reported at most once a second, so this notices a change rather than \
                timing one.
                """,
            tier: .readonly,
            arguments: [
                ToolArgument(
                    name: "format",
                    summary: "A tmux format, such as #{pane_current_command}.",
                    isRequired: true
                ),
                paneReadTarget,
                paneWindowLink,
                ToolArgument(
                    name: "matching",
                    summary:
                        "A regular expression the value must match to end the wait. "
                        + "Omit to return on the first change of any kind.",
                ),
                ToolArgument(
                    name: "timeout",
                    summary: "Seconds to wait. Clamped by the server ceiling.",
                    kind: .number,
                    defaultValue: .number(30)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "paneRef": Schema.string, "linkRef": Schema.string,
                    "outcome": Schema.string, "value": Schema.nullableString,
                    "seconds": Schema.number, "effectiveTimeout": Schema.number,
                ],
                required: ["paneRef", "linkRef", "outcome", "seconds", "effectiveTimeout"])
        ),
        ToolDefinition(
            name: "wait_for_channel",
            title: "Wait on a tmux channel",
            summary:
                "Blocks until something runs `tmux wait-for -S <channel>`. The only "
                + "wait that infers nothing.",
            detail: """
                Deterministic where every other wait is a heuristic: tmux blocks \
                server-side and returns on the signal itself. Compose it into a \
                command you send — `send_keys('make; tmux wait-for -S built')` then \
                wait here. The `;` fires the signal whether the command passed or \
                failed, so the wait cannot deadlock on failure.

                run_shell does this for you and adds the exit status. Reach for this \
                directly when the shell composition has to be your own.
                """,
            tier: .readonly,
            arguments: [
                ToolArgument(
                    name: "channel",
                    summary: "The channel name to block on.",
                    isRequired: true
                ),
                ToolArgument(
                    name: "timeout",
                    summary: "Seconds to wait. Clamped by the server ceiling.",
                    kind: .number,
                    defaultValue: .number(30)
                ),
            ],
            outputSchema: Schema.object(
                [
                    "channel": Schema.string, "released": Schema.boolean, "seconds": Schema.number,
                    "effectiveTimeout": Schema.number,
                ], required: ["channel", "released", "seconds", "effectiveTimeout"])
        ),
        ToolDefinition(
            name: "signal_channel",
            title: "Release a tmux channel",
            summary: "Releases one waiter on a channel.",
            tier: .mutating,
            arguments: [
                ToolArgument(
                    name: "channel",
                    summary: "The channel name to signal.",
                    isRequired: true
                )
            ],
            outputSchema: Schema.object(
                ["channel": Schema.string, "signalled": Schema.boolean],
                required: ["channel", "signalled"])
        ),

        // MARK: Driving

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
                    defaultValue: .number(200)
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

        // MARK: Ending things

        ToolDefinition(
            name: "kill_pane",
            title: "Kill a pane",
            summary: "Ends a pane and whatever is running in it.",
            tier: .destructive,
            arguments: [paneTarget, confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"])
        ),
        ToolDefinition(
            name: "kill_window",
            title: "Kill a window",
            summary: "Ends a window and every pane in it.",
            tier: .destructive,
            arguments: [target("A global windowRef to kill."), confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"])
        ),
        ToolDefinition(
            name: "kill_session",
            title: "Kill a session",
            summary: "Ends a session and every window in it.",
            tier: .destructive,
            arguments: [target("A session ref to kill."), confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"])
        ),

        ToolDefinition(
            name: "kill_server",
            title: "Kill the whole tmux server",
            summary: "Ends every session on this server, and the server with them.",
            tier: .destructive,
            arguments: [serverTarget, confirmSelf],
            outputSchema: Schema.object(
                ["ref": Schema.string, "kind": Schema.string, "id": Schema.string],
                required: ["ref", "kind", "id"]
            )
        ),

        // MARK: tmux itself

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

    static let byName: [String: ToolDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.name, $0) }
    )
}
