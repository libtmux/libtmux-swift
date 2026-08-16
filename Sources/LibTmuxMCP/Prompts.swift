import Foundation

/// Workflow recipes, as MCP prompts.
///
/// A prompt is how a server ships an operator's hard-won sequence to whoever
/// runs it, rather than hoping the model rediscovers it. Kept small and
/// deliberate: each one exists because the obvious approach to the same problem
/// is measurably worse, and says so.
enum Prompts {
    struct Recipe {
        let name: String
        let title: String
        let description: String
        let arguments: [(name: String, description: String, required: Bool)]
        let render: @Sendable ([String: String]) -> String
    }

    static let all: [Recipe] = [
        Recipe(
            name: "run_and_wait",
            title: "Run a command and wait for it",
            description:
                "Run a shell command in a pane and get its exit status, without "
                + "polling or prompt-matching.",
            arguments: [
                ("command", "The shell command to run.", true),
                ("pane", "The pane to run it in, such as %1.", true),
            ]
        ) { arguments in
            let command = arguments["command"] ?? "make"
            let pane = arguments["pane"] ?? "%1"
            return """
                Run this in tmux pane \(pane), wait for it, and read the result:

                    run_shell(pane: "\(pane)", command: \(quoted(command)))

                `run_shell` composes a tmux channel into the command, so completion \
                is signalled by tmux rather than guessed from the screen. Read \
                `exitStatus` for the answer and `output` for what it printed — only \
                the lines this command produced, not the whole pane.

                Do NOT drive this with send_keys followed by capture_pane in a retry \
                loop. That polls, cannot tell a slow command from a finished one, and \
                has no exit status to report.

                If `timedOut` is true the command is still running — nothing was \
                killed. Call again, or read the pane.
                """
        },

        Recipe(
            name: "watch_until_ready",
            title: "Wait for something you did not start",
            description:
                "Wait for a daemon, dev server or build that another process "
                + "started to reach a known state.",
            arguments: [
                ("pane", "The pane it is running in.", true),
                ("ready", "Text that means it is ready.", false),
            ]
        ) { arguments in
            let pane = arguments["pane"] ?? "%1"
            let ready = arguments["ready"] ?? "ready"
            return """
                Something you did not start is running in pane \(pane). Wait for it:

                1. `wait_for_output(pane: "\(pane)", patterns: [\(quoted(ready))], \
                stops: ["error", "EADDRINUSE", "FAILED"])`

                   The `stops` matter more than the pattern. A process that fails \
                after five seconds should end the wait then, not hold it for the \
                full timeout and report the same failure later.

                2. Read the result before changing anything:
                   - `sawNewOutput: false` — the pane was quiet. The thing never \
                started. Do not guess another pattern; check the command.
                   - `sawNewOutput: true, outcome: "timedOut"` — it printed \
                something else. `tail` holds what it actually said; fix the pattern \
                from that rather than from memory.
                   - `outcome: "stopped"` — a failure marker hit. `matched` says which.

                If the question is about *state* rather than text — has the command \
                finished, has the pane died — use `watch_format` with \
                `#{pane_current_command}` or `#{pane_dead}` instead. It reads no \
                scrollback at all.
                """
        },

        Recipe(
            name: "build_workspace",
            title: "Build a development session",
            description:
                "Create a multi-window, multi-pane session in one call rather than "
                + "a sequence of splits.",
            arguments: [
                ("session", "What to call the session.", true),
                ("directory", "Where its panes start.", false),
            ]
        ) { arguments in
            let session = arguments["session"] ?? "work"
            let directory = arguments["directory"] ?? "."
            return """
                Build a session named \(session) in one call:

                    apply_workspace(plan: {
                      "session_name": "\(session)",
                      "start_directory": "\(directory)",
                      "windows": [
                        {"window_name": "edit",   "panes": [{"shell_command": []}]},
                        {"window_name": "test",   "panes": [{"shell_command": []},
                                                            {"shell_command": []}]},
                        {"window_name": "server", "panes": [{"shell_command": []}]}
                      ]
                    })

                One call, and no pane ids to thread between steps — the result \
                carries every session, window and pane it made.

                Do NOT build this with new_session followed by a chain of \
                split_pane calls. That is one round trip per pane, and each one \
                returns an id you have to carry into the next.

                It refuses if the session already exists rather than adopting it. \
                Check with list_sessions first if that is a possibility.
                """
        },

        Recipe(
            name: "find_my_pane",
            title: "Work out where you are",
            description:
                "Identify the pane this agent is running in before changing "
                + "anything around it.",
            arguments: []
        ) { _ in
            """
            Before touching panes, find out which one is yours:

                describe_server()

            `caller_pane` is the pane this MCP server runs in, or null when it runs \
            outside tmux. `list_panes` also marks that row with `isCaller: true`.

            This matters because killing it ends the conversation, and nothing would \
            come back to tell you. The kill tools refuse that case already and name \
            `confirm_self` as the way to mean it — but knowing which pane is yours \
            is what stops you from asking in the first place.

            `describe_server` also reports the tmux version and the wait ceiling, so \
            it is worth calling once at the start of any session rather than \
            discovering both from a failure.
            """
        },
    ]

    static var listing: [JSONValue] {
        all.map { recipe in
            .object([
                "name": .string(recipe.name),
                "title": .string(recipe.title),
                "description": .string(recipe.description),
                "arguments": .array(
                    recipe.arguments.map { argument in
                        .object([
                            "name": .string(argument.name),
                            "description": .string(argument.description),
                            "required": .bool(argument.required),
                        ])
                    }
                ),
            ])
        }
    }

    static func render(_ name: String, arguments: JSONValue) -> JSONValue? {
        guard let recipe = all.first(where: { $0.name == name }) else { return nil }
        let values = (arguments.objectValue ?? [:]).compactMapValues(\.stringValue)
        return .object([
            "description": .string(recipe.description),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string(recipe.render(values)),
                    ]),
                ])
            ]),
        ])
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
