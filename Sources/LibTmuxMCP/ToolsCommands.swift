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
    "choose-client": "snapshot to inspect clients; there is no typed client-format target",
    "choose-buffer": "run_command with list-buffers",
    "lock-server": "no tool: a locked server answers nothing",
    "lock-session": "no tool: a locked session answers nothing",
    "lock-client": "no tool: a locked client answers nothing",
]

private let rawCommandOutputLimit = 256 * 1_024
private let rawCommandBatchLimit = 16
private let rawUnsafeConfirmationReason =
    "raw tmux commands bypass typed target and safety checks; "
    + "pass confirm_unsafe=true to acknowledge that"

extension TmuxTools {
    func runCommand(_ arguments: Arguments) async throws -> ToolOutcome {
        let (timeout, enforced) = try rawCommandDeadline(arguments)
        let incarnation = try await serverIncarnation(try arguments.string("server_ref"))
        let name = try arguments.string("command")
        try Self.refuseIfBlocking(name)
        let command = TmuxCommand(name, try arguments.strings("arguments"))
        let reply = try await withRawCommandDeadline(
            "run_command",
            timeout: timeout,
            seconds: enforced
        ) {
            try await server.runIsolated(
                command,
                expecting: incarnation,
                perStreamOutputLimit: rawCommandOutputLimit
            )
        }
        return .init(
            CommandResult(
                serverRef: WireReferenceCodec.processLocal.reference(to: incarnation),
                exitCode: reply.exitCode,
                standardOutput: reply.text,
                standardError: reply.errorText
            )
        )
    }

    func runCommands(_ arguments: Arguments) async throws -> ToolOutcome {
        let (timeout, enforced) = try rawCommandDeadline(arguments)
        let incarnation = try await serverIncarnation(try arguments.string("server_ref"))
        guard let document = try arguments.document("commands") else {
            throw ToolError.missingArgument("commands")
        }
        let requested = try JSONDecoder().decode([CommandRequest].self, from: document)
        guard !requested.isEmpty else {
            throw ToolError.wrongArgumentType("commands", expected: "a non-empty array")
        }
        guard requested.count <= rawCommandBatchLimit else {
            throw ToolError.wrongArgumentType(
                "commands",
                expected: "at most \(rawCommandBatchLimit) commands"
            )
        }
        for request in requested { try Self.refuseIfBlocking(request.command) }

        let results = try await withRawCommandDeadline(
            "run_commands",
            timeout: timeout,
            seconds: enforced
        ) {
            var results: [StepResult] = []
            for (index, request) in requested.enumerated() {
                let reply = try await server.runIsolated(
                    TmuxCommand(request.command, request.arguments ?? []),
                    expecting: incarnation,
                    perStreamOutputLimit: rawCommandOutputLimit
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
                // A later command is unsafe to infer after this one failed.
                guard reply.isSuccess else { break }
            }
            return results
        }
        return .init(
            BatchResult(
                serverRef: WireReferenceCodec.processLocal.reference(to: incarnation),
                steps: results,
                requested: requested.count,
                stoppedEarly: results.count < requested.count
            )
        )
    }

    private func rawCommandDeadline(
        _ arguments: Arguments
    ) throws -> (duration: Duration, enforced: Double) {
        guard try arguments.bool("confirm_unsafe", or: false) else {
            throw ToolError.refusedForSafety(rawUnsafeConfirmationReason)
        }
        return bounded(try arguments.seconds("timeout", or: 10))
    }

    private func withRawCommandDeadline<Result: Sendable>(
        _ tool: String,
        timeout: Duration,
        seconds: Double,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ToolError.timedOut(tool, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ToolError.refusedForSafety("\(tool) started no isolated command")
            }
            return result
        }
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
struct CommandRequest: Decodable, Sendable {
    let command: String
    let arguments: [String]?
}
