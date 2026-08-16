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
        summary: "A pane id such as %1. Pane ids survive layout changes; indexes do not.",
        isRequired: true
    )

    private static let fields = ToolArgument(
        name: "fields",
        summary:
            "Only these fields of each record, by the names describe_filters lists. "
            + "Omit for every field. Use it when one field answers the question — a "
            + "listing of a busy server is mostly context you will not read.",
        kind: .stringArray
    )

    private static let confirmSelf = ToolArgument(
        name: "confirm_self",
        summary:
            "Proceed even when the target is the pane, session, or server this MCP "
            + "is running inside. Without it such a call is refused, because it ends "
            + "the conversation making it.",
        kind: .boolean,
        defaultValue: .bool(false)
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
            isIdempotent: true
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
            ]
        ),
        ToolDefinition(
            name: "list_windows",
            title: "List windows",
            summary: "Every window on the server, optionally filtered.",
            tier: .readonly,
            isIdempotent: true,
            arguments: [
                ToolArgument(
                    name: "filter",
                    summary: "A filter expression as JSON, as described by describe_filters.",
                    kind: .object
                ),
                fields,
            ]
        ),
        ToolDefinition(
            name: "list_panes",
            title: "List panes",
            summary: "Every pane on the server, optionally filtered.",
            detail: """
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
            ]
        ),
        ToolDefinition(
            name: "snapshot",
            title: "Read the whole hierarchy at once",
            summary:
                "Every session, window, pane and client as one consistent picture.",
            detail: """
                One call instead of walking the hierarchy level by level, and the \
                only read that proves what it returns existed together: the server's \
                identity is checked before and after, so a daemon that died and was \
                replaced mid-read is reported rather than described. Prefer this \
                whenever you want more than one level.
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
                paneTarget,
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
            ]
        ),
        ToolDefinition(
            name: "search_panes",
            title: "Search what panes have printed",
            summary: "Finds a regular expression in the contents of every pane.",
            detail: """
                The tool for "which pane mentions X". Reads content, where list_panes \
                reads metadata. Each match carries its pane id and line, so the answer \
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
            ]
        ),
        ToolDefinition(
            name: "read_format",
            title: "Evaluate a tmux format",
            summary:
                "Evaluates any tmux format, reaching fields the listings do not carry.",
            detail: """
                The escape hatch for anything tmux can report but this server does not \
                model — `#{pane_dead}`, `#{window_bell_flag}`, `#{client_termname}`. \
                A target that no longer resolves reports null, which is how it differs \
                from a field that is legitimately empty.
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
                    "A tmux id — $0, @1, %2 — or omitted to ask about the server itself.",
                    required: false
                ),
            ]
        ),

        // MARK: Waiting

        ToolDefinition(
            name: "wait_for_output",
            title: "Wait for a pane to print something",
            summary:
                "Blocks until a pane prints matching text, driven by tmux events "
                + "rather than by polling.",
            detail: """
                For output you did not author: a daemon printing `ready`, a dev server \
                someone else started, a build you attached to. tmux pushes pane output \
                over a control connection, so a quiet pane costs nothing while this \
                waits.

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
                paneTarget,
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
            ]
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
                paneTarget,
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
            ]
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
            ]
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
            ]
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
            ]
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
            ]
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
            ]
        ),
        ToolDefinition(
            name: "new_window",
            title: "Create a window",
            summary: "Creates a window in a session and returns it.",
            tier: .mutating,
            arguments: [
                target("The session id or name to create it in."),
                ToolArgument(name: "name", summary: "What to call it."),
                ToolArgument(name: "start_directory", summary: "Where it starts."),
            ]
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
            ]
        ),
        ToolDefinition(
            name: "apply_workspace",
            title: "Build a session from a plan",
            summary:
                "Builds a whole session — windows, panes, directories, commands — "
                + "from one declarative plan.",
            detail: """
                One call instead of a create-split-split-send sequence whose pane ids \
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
            ]
        ),
        ToolDefinition(
            name: "set_option",
            title: "Set a tmux option",
            summary: "Sets a tmux option at server, session, window or pane scope.",
            tier: .mutating,
            isIdempotent: true,
            arguments: [
                ToolArgument(name: "name", summary: "The option name.", isRequired: true),
                ToolArgument(name: "value", summary: "What to set it to.", isRequired: true),
                ToolArgument(
                    name: "scope",
                    summary: "Which level the option belongs to.",
                    allowed: ["server", "session", "window", "pane", "global"],
                    defaultValue: .string("session")
                ),
                target("The object to set it on, when the scope is not server.", required: false),
            ]
        ),

        // MARK: Ending things

        ToolDefinition(
            name: "kill_pane",
            title: "Kill a pane",
            summary: "Ends a pane and whatever is running in it.",
            tier: .destructive,
            arguments: [paneTarget, confirmSelf]
        ),
        ToolDefinition(
            name: "kill_window",
            title: "Kill a window",
            summary: "Ends a window and every pane in it.",
            tier: .destructive,
            arguments: [target("The window id to kill."), confirmSelf]
        ),
        ToolDefinition(
            name: "kill_session",
            title: "Kill a session",
            summary: "Ends a session and every window in it.",
            tier: .destructive,
            arguments: [target("The session id or name to kill."), confirmSelf]
        ),

        // MARK: tmux itself

        ToolDefinition(
            name: "run_command",
            title: "Run one tmux command",
            summary: "Runs a single tmux command and returns what tmux said.",
            detail: """
                The escape hatch for anything above. Arguments are passed to tmux \
                without a shell, so nothing here is expanded or word-split.

                A nonzero exit is reported rather than thrown — `has-session` answers \
                a question that way. Commands that block forever without a terminal \
                are refused by name, with the tool that does the same job safely.
                """,
            tier: .mutating,
            arguments: [
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
            ]
        ),
        ToolDefinition(
            name: "run_commands",
            title: "Run several tmux commands",
            summary:
                "Runs a list of tmux commands over one connection and reports each "
                + "one's result separately.",
            detail: """
                Cheaper than a call each, and unlike a `;` list it says which command \
                failed: tmux numbers a control connection's replies, so output belongs \
                to the command that produced it rather than to one merged stream.

                Stops at the first failure, as tmux does. Every command that ran \
                carries its own output and status.
                """,
            tier: .mutating,
            arguments: [
                ToolArgument(
                    name: "commands",
                    summary:
                        "The commands, as JSON: an array of {command, arguments[]} "
                        + "objects.",
                    kind: .object,
                    isRequired: true
                )
            ]
        ),
    ]

    static let byName: [String: ToolDefinition] = Dictionary(
        uniqueKeysWithValues: definitions.map { ($0.name, $0) }
    )
}
