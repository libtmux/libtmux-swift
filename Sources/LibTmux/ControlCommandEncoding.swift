import Foundation

/// Refuses an argument a command line cannot carry.
///
/// A connection sends commands one per line, so a newline inside an argument
/// ends the command there and leaves the rest to be read as the next one — and
/// tmux answers the truncated command, successfully, having done something the
/// caller did not ask for.
///
/// There is no encoding that avoids it. Single quotes leave the newline as a
/// newline. Double quotes carry it as `\n`, but tmux expands `#` and `$` inside
/// them and offers no escape for `#`, so any value that might contain a format
/// sequence would be rewritten instead. A process takes an argument vector and
/// has none of this trouble, which is why the same call is fine in the default
/// mode.
func requireSingleLine(_ arguments: [String]) throws(TmuxError) {
    guard arguments.allSatisfy({ !$0.contains("\n") }) else {
        throw .invocationFailed(
            reason:
                "an argument containing a newline cannot be sent over a control "
                + "connection; run this on a server without one"
        )
    }
}

/// Quotes one argument for a POSIX shell.
///
/// Separate from ``tmuxQuoted`` despite the identical shape today: the two
/// answer to different parsers, and a change made for one of them would
/// otherwise silently apply to the other.
package func shellQuoted(_ argument: String) -> String {
    let safe = argument.allSatisfy { character in
        character.isLetter || character.isNumber || "_-./=:@%+,".contains(character)
    }
    if safe, !argument.isEmpty { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// Quotes one argument for tmux's own command parser.
///
/// Control mode takes a command *line*, not argv, so tmux re-parses what is
/// sent: `#` opens a comment, and whitespace and quotes separate or group.
/// A format like `#{session_name}` therefore has to be quoted or it vanishes
/// mid-command.
func tmuxQuoted(_ argument: String) -> String {
    let safe = argument.allSatisfy { character in
        character.isLetter || character.isNumber
            || "_-./=:@%+,".contains(character)
    }
    if safe, !argument.isEmpty { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

extension ControlSession {
    /// Answers a process-shaped request from the connection.
    ///
    /// The rest of the library asks for a listing the same way whatever is
    /// carrying it, so a connection has to reply in the shape a process would:
    /// bytes, and a status. A command tmux rejected keeps its meaning as a
    /// reply rather than becoming a thrown error — the same contract
    /// ``Server/run(_:)`` states — so its text lands on standard error with a
    /// nonzero status instead.
    func reply(to rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        guard !rawArguments.isEmpty else {
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        }
        try requireSingleLine(rawArguments)
        let commands = splitTmuxArgumentCommands(rawArguments)
        guard !commands.isEmpty else {
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        }
        let line =
            commands
            .map { $0.map(tmuxQuoted).joined(separator: " ") }
            .joined(separator: " \(TmuxCommandList.separator) ")

        // How many commands went out is how many blocks may come back.
        let reply = try await send(line: line, commands: commands.count)

        // A process ends its output with a newline; the connection reports
        // lines. Restore it, so both spellings decode to the same rows.
        let bytes =
            reply.lines.isEmpty
            ? []
            : Array((reply.lines.joined(separator: "\n") + "\n").utf8)
        return TmuxReply(
            standardOutput: reply.isError ? [] : bytes,
            standardError: reply.isError ? bytes : [],
            exitCode: reply.isError ? 1 : 0
        )
    }

    func reply(to request: GuardedRequest) async throws(TmuxError) -> TmuxReply {
        try requireSingleLine([request.controlLine])
        let reply = try await sendFenced(
            line: request.controlLine,
            marker: request.fenceMarker
        )

        let bytes =
            reply.lines.isEmpty
            ? []
            : Array((reply.lines.joined(separator: "\n") + "\n").utf8)
        return TmuxReply(
            standardOutput: reply.isError ? [] : bytes,
            standardError: reply.isError ? bytes : [],
            exitCode: reply.isError ? 1 : 0
        )
    }
}

private func splitTmuxArgumentCommands(_ arguments: [String]) -> [[String]] {
    // tmux's argv parser makes a trailing `;` structural and `\;` literal.
    // Recreate that result before quoting the control command line.
    var commands: [[String]] = [[]]
    for argument in arguments {
        guard argument.hasSuffix(TmuxCommandList.separator) else {
            commands[commands.endIndex - 1].append(argument)
            continue
        }

        var prefix = String(argument.dropLast())
        if prefix.hasSuffix("\\") {
            prefix.removeLast()
            commands[commands.endIndex - 1].append(prefix + TmuxCommandList.separator)
        } else {
            if !prefix.isEmpty { commands[commands.endIndex - 1].append(prefix) }
            commands.append([])
        }
    }
    return commands.filter { !$0.isEmpty }
}
