import Foundation
import LibTmux

// The escape hatches, and the one guard that keeps them from wedging the
// caller.

/// tmux commands that never return without a terminal to answer them.
///
/// Each of these blocks its client indefinitely: `wait-for` until something
/// signals the channel, the prompts until a key arrives, `attach-session` for
/// as long as the client stays attached. Run through an MCP tool there is no
/// terminal and no key, so the call does not end — it spends the caller's turn
/// and returns nothing.
///
/// Refusing by name and pointing at the tool that does the same job is worth
/// more than a timeout, which would still have cost the wait.
private let blockingCommands: [String: String] = [
    "wait-for": "wait_for_channel, which bounds the wait and can be cancelled",
    "attach-session": "no tool: this server drives tmux, it does not attach to it",
    "attach": "no tool: this server drives tmux, it does not attach to it",
    "command-prompt": "send_keys, which does not need a terminal to answer it",
    "confirm-before": "the tool for the command itself, which needs no confirmation",
    "choose-tree": "list_sessions or snapshot",
    "choose-client": "read_format against #{client_name}",
    "choose-buffer": "run_command with list-buffers",
    "lock-server": "no tool: a locked server answers nothing",
    "lock-session": "no tool: a locked session answers nothing",
    "lock-client": "no tool: a locked client answers nothing",
]

extension TmuxTools {
    func runCommand(_ arguments: Arguments) async throws -> ToolOutcome {
        let name = try arguments.string("command")
        try Self.refuseIfBlocking(name)
        let reply = try await server.run(
            TmuxCommand(name, try arguments.strings("arguments"))
        )
        return .init(
            CommandResult(
                exitCode: reply.exitCode,
                standardOutput: reply.text,
                standardError: reply.errorText
            )
        )
    }

    func runCommands(_ arguments: Arguments) async throws -> ToolOutcome {
        guard let document = try arguments.document("commands") else {
            throw ToolError.missingArgument("commands")
        }
        let requested = try JSONDecoder().decode([CommandRequest].self, from: document)
        guard !requested.isEmpty else {
            throw ToolError.wrongArgumentType("commands", expected: "a non-empty array")
        }
        for request in requested { try Self.refuseIfBlocking(request.command) }

        var results: [StepResult] = []
        for (index, request) in requested.enumerated() {
            let reply = try await server.run(
                TmuxCommand(request.command, request.arguments ?? [])
            )
            results.append(
                StepResult(
                    step: index,
                    command: request.command,
                    exitCode: reply.exitCode,
                    standardOutput: reply.text,
                    standardError: reply.errorText
                )
            )
            // tmux runs a command list only as far as its first failure, and a
            // batch that kept going would do something the caller did not ask
            // for after the step it asked for stopped making sense.
            guard reply.isSuccess else { break }
        }
        return .init(
            BatchResult(
                steps: results,
                requested: requested.count,
                stoppedEarly: results.count < requested.count
            )
        )
    }

    static func refuseIfBlocking(_ command: String) throws {
        guard let alternative = blockingCommands[command] else { return }
        throw ToolError.refusedForSafety(
            """
            `\(command)` waits for a terminal that an MCP tool call does not have, \
            so it would never return and this call would spend your turn for \
            nothing. Use \(alternative).
            """
        )
    }
}

/// One step of a batch, as it arrives.
struct CommandRequest: Decodable {
    let command: String
    let arguments: [String]?
}
