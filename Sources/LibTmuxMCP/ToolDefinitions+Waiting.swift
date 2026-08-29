extension TmuxTools {
    static let waitingDefinitions: [ToolDefinition] = [
        ToolDefinition(
            operation: .waitForOutput,
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
                - `outcome: "timedOut"` with `sawNewOutput: false` — the pane \
                stayed quiet. The thing never ran; no pattern fixes that.
                - `outcome: "timedOut"` with output — it printed something else. \
                `tail` holds what it actually said; fix the pattern from that.
                - `outcome: "stopped"` — a `stops` marker hit. `matched` says which.
                - `outcome: "expiredWhileReading"` — the timeout was too short to \
                read the pane at all, so the other fields report nothing. Ask \
                again with a longer one; the pattern is not the problem.

                For a command you wrote yourself, run_shell is cheaper and exact.
                """,
            tier: .readonly,
            arguments: [
                paneTarget,
                ToolArgument(
                    name: "patterns",
                    summary:
                        "Bounded regular expressions, any of which ends the wait. Omit for "
                        + "any new output at all.",
                    kind: .stringArray,
                    maximumItems: ToolPattern.maximumListCount
                ),
                ToolArgument(
                    name: "stops",
                    summary:
                        "Bounded regular expressions that end the wait as a failure. Put error "
                        + "markers here.",
                    kind: .stringArray,
                    maximumItems: ToolPattern.maximumListCount
                ),
                ToolArgument(
                    name: "case_insensitive",
                    summary: "Match every success and stop pattern without case distinctions.",
                    kind: .boolean,
                    defaultValue: .bool(false)
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
            operation: .watchFormat,
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
                paneWindowLink,
                ToolArgument(
                    name: "matching",
                    summary:
                        "A bounded regular expression the value must match to end the wait. "
                        + "Omit to return on the first change of any kind.",
                ),
                ToolArgument(
                    name: "case_insensitive",
                    summary: "Match the value without case distinctions.",
                    kind: .boolean,
                    defaultValue: .bool(false)
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
            operation: .waitForChannel,
            title: "Wait on a tmux channel",
            summary:
                "Blocks until this tmux server's channel is signalled. The only "
                + "wait that infers nothing.",
            detail: """
                Deterministic where every other wait is a heuristic: tmux blocks \
                server-side and returns on the signal itself. Use this only when \
                another process is already arranged to signal a channel on this \
                exact server.

                When you start the command, use run_shell instead. It addresses the \
                right server, signals after success or failure, and reports the exit \
                status without a second call.
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
            operation: .signalChannel,
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
    ]
}
