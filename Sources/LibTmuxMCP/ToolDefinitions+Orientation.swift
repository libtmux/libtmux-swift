import LibTmux

extension TmuxTools {
    static let orientationDefinitions: [ToolDefinition] = [
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
                and the ones that do not are left out. At most 4,096 entries \
                are inspected and 128 socket candidates are probed, with two \
                seconds allowed for each; `truncated` says more may remain.
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
                    "servers": .object([
                        "type": .string("array"),
                        "items": Schema.object(
                            [
                                "socketPath": Schema.string,
                                "processID": Schema.nullableInteger,
                                "sessionCount": Schema.integer,
                            ],
                            required: ["socketPath", "sessionCount"]
                        ),
                        "maxItems": .number(Double(TmuxServers.maximumCandidates)),
                    ]),
                    "truncated": Schema.boolean,
                ],
                required: ["servers", "truncated"]
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
    ]
}
