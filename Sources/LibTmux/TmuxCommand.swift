/// One tmux command, as argv.
///
/// No shell sees the arguments. tmux still reads a trailing `;` as a command
/// separator; spell a literal trailing semicolon as `\;`.
public struct TmuxCommand: Sendable, Hashable {
    /// The tmux command, as tmux spells it — `new-session`, `list-panes`.
    public let name: String
    /// Its arguments, one element each. Never a joined string: a value holding
    /// a space is data.
    public let arguments: [String]
    public init(_ name: String, _ arguments: [String] = []) {
        self.name = name
        self.arguments = arguments
    }

    /// The command's own argv, without the endpoint tmux is addressed with.
    var argumentVector: [String] {
        [name] + arguments
    }

    /// A command argument that tmux will parse as another command.
    var parsedString: String {
        argumentVector.map(tmuxQuoted).joined(separator: " ")
    }
}

// tmux packs argv after a four-byte argc in its 16 KiB command message.
private let maximumTmuxCommandPayloadBytes = 16_380

func requireTmuxCommandFits(_ arguments: [String]) throws(TmuxError) {
    var actualBytes = 0
    for argument in arguments {
        let (argumentBytes, argumentOverflowed) = argument.utf8.count
            .addingReportingOverflow(1)
        let (nextBytes, totalOverflowed) = actualBytes.addingReportingOverflow(
            argumentBytes
        )
        guard !argumentOverflowed, !totalOverflowed else {
            throw .commandTooLarge(
                actualBytes: .max,
                maximumBytes: maximumTmuxCommandPayloadBytes
            )
        }
        actualBytes = nextBytes
    }
    guard actualBytes <= maximumTmuxCommandPayloadBytes else {
        throw .commandTooLarge(
            actualBytes: actualBytes,
            maximumBytes: maximumTmuxCommandPayloadBytes
        )
    }
}

/// What tmux said.
///
/// Output is bytes. tmux does not promise UTF-8 — a pane title can carry
/// anything the program in it emitted — so decoding is the caller's decision
/// and invalid bytes are data rather than a failure.
public struct TmuxReply: Sendable, Hashable {
    /// Bytes rather than a string, because a format's fields are separated by
    /// a byte and decoding happens after splitting, not before.
    public let standardOutput: [UInt8]
    /// Where tmux explains a command it refused.
    public let standardError: [UInt8]
    /// tmux's exit status. Nonzero is an answer — `has-session` says "no" this
    /// way — so it is reported rather than thrown.
    public let exitCode: Int32

    public init(standardOutput: [UInt8], standardError: [UInt8], exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    public var isSuccess: Bool { exitCode == 0 }

    /// Standard output decoded as UTF-8, replacing anything invalid.
    public var text: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    /// Standard error decoded as UTF-8, trimmed of its trailing newline.
    public var errorText: String {
        var text = String(decoding: standardError, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
