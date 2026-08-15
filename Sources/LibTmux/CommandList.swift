/// Several tmux commands sent in one invocation.
///
/// tmux runs a `;`-separated list in a single client connection, which saves a
/// process and a round trip per command and keeps the list from interleaving
/// with another caller's work.
///
/// What it does *not* do is delimit the output: tmux concatenates everything
/// onto one stream with nothing marking where one command's output ends. So a
/// list answers "did all of this run, and what came out" — not "what did the
/// third command say". Ask separately when you need per-command attribution.
public struct TmuxCommandList: Sendable, Hashable, ExpressibleByArrayLiteral {
    public private(set) var commands: [TmuxCommand]

    public init(_ commands: [TmuxCommand] = []) {
        self.commands = commands
    }

    public init(arrayLiteral elements: TmuxCommand...) {
        self.init(elements)
    }

    /// Appends a command, returning a new list.
    ///
    /// Chaining builds a value; nothing is sent until the list is run, so a
    /// half-built chain has no effect on the server.
    public func then(_ command: TmuxCommand) -> Self {
        var copy = self
        copy.commands.append(command)
        return copy
    }

    public func then(_ name: String, _ arguments: [String] = []) -> Self {
        then(TmuxCommand(name, arguments))
    }

    public var isEmpty: Bool { commands.isEmpty }

    /// What tmux reads as "and then". Named once so the process path and the
    /// connection path cannot disagree about it.
    static let separator = ";"

    /// The argv for the whole list.
    ///
    /// The separator is its own argument. A `;` inside a command's arguments is
    /// therefore data, not punctuation — no shell or tmux parser ever sees the
    /// two as the same thing.
    var argumentVector: [String] {
        var arguments: [String] = []
        for (index, command) in commands.enumerated() {
            if index > 0 { arguments.append(TmuxCommandList.separator) }
            arguments.append(contentsOf: command.argumentVector)
        }
        return arguments
    }
}

extension Server {
    /// Runs a list of commands in one tmux invocation.
    ///
    /// The reply covers the whole list. tmux stops at the first command that
    /// fails, so a nonzero status means some prefix of the list ran — read the
    /// standard error to learn which command tmux objected to.
    ///
    /// Running an empty list is a no-op that reports success without invoking
    /// tmux at all.
    public func run(_ list: TmuxCommandList) async throws(TmuxError) -> TmuxReply {
        guard !list.isEmpty else {
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        }
        return try await run(rawArguments: list.argumentVector)
    }
}
