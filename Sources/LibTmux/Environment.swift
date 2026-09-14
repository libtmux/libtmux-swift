/// Which environment a variable lives in.
///
/// tmux keeps two, and only two: one global, and one per session. There is no
/// window or pane environment, so this cannot ask for one — unlike
/// ``OptionScope``, whose four tables are all real.
public enum EnvironmentScope: Sendable, Hashable, Codable {
    case global
    /// A session's own environment, addressed by name or id.
    case session(String)

    var arguments: [String] {
        switch self {
        case .global: ["-g"]
        case let .session(target): ["-t", target]
        }
    }
}

/// One variable in a tmux environment.
///
/// tmux prints two shapes, and they mean different things: `NAME=value` is a
/// variable with a value, and `-NAME` is one marked so that new processes start
/// *without* it, which is not the same as it being absent. Folding both into a
/// dictionary of strings would turn the second into a variable whose name
/// begins with a dash.
public struct TmuxEnvironmentVariable: Sendable, Hashable, Codable {
    /// The variable's name, without the `-` that marks a removal in tmux's
    /// own listing.
    public let name: String
    /// What a new process would be given, or `nil` when this variable is marked
    /// for removal instead. Ask ``isRemoved`` rather than testing for `nil`
    /// where the distinction is the point.
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }

    /// Whether tmux will strip this variable from a new process's environment
    /// rather than set it.
    public var isRemoved: Bool { value == nil }
}

extension Server {
    /// `--` ends the flags, so a name beginning with `-` reaches tmux as a
    /// name rather than as flags it does not have.
    private func setEnvironmentCommand(
        _ name: String, to value: String, in scope: EnvironmentScope
    ) -> TmuxCommand {
        TmuxCommand("set-environment", scope.arguments + ["--", name, value])
    }

    /// Sets a variable in a session's environment, refusing if that session is
    /// no longer the one this value names.
    package func setEnvironment(
        _ name: String, to value: String, in session: Session
    ) async throws(TmuxError) -> TmuxReply {
        try await runGuarded(
            setEnvironmentCommand(name, to: value, in: .session(session.id.rawValue)),
            by: [.session(session)])
    }

    /// Every variable in an environment, in the order tmux printed them.
    public func environment(
        _ scope: EnvironmentScope = .global
    ) async throws(TmuxError) -> [TmuxEnvironmentVariable] {
        let reply = try await run(TmuxCommand("show-environment", scope.arguments))
        guard reply.isSuccess else { return [] }
        return reply.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { TmuxEnvironmentVariable(line: String($0)) }
    }

    /// What one variable is set to, or `nil` when it is unset or marked for
    /// removal.
    ///
    /// Reads one value directly so embedded newlines remain part of that value.
    /// tmux's nonzero response for an unknown name becomes `nil`.
    public func environmentValue(
        _ name: String,
        in scope: EnvironmentScope = .global
    ) async throws(TmuxError) -> String? {
        let command = TmuxCommand("show-environment", scope.arguments + ["--", name])
        let reply = try await run(command)
        guard reply.isSuccess else {
            if reply.errorText == "unknown variable: \(name)" { return nil }
            throw reply.failure(for: command)
        }
        var text = reply.text
        if text.hasSuffix("\n") { text.removeLast() }
        if text == "-\(name)" { return nil }
        let prefix = "\(name)="
        guard text.hasPrefix(prefix) else {
            throw .invocationFailed(reason: "show-environment returned an unexpected variable.")
        }
        return String(text.dropFirst(prefix.count))
    }

    /// Sets a variable, replacing whatever was there.
    @discardableResult
    public func setEnvironment(
        _ name: String,
        to value: String,
        in scope: EnvironmentScope = .global
    ) async throws(TmuxError) -> TmuxReply {
        // run(_:) hands argv to tmux, which ends a command at a trailing `;`.
        // A guarded request is quoted as a command string and needs no escape.
        try await run(setEnvironmentCommand(name, to: tmuxArgumentData(value), in: scope))
    }

    /// Unsets a variable, leaving no trace of it.
    ///
    /// Different from ``removeEnvironment(_:in:)``: an unset variable is simply
    /// gone, where a removed one is still listed so that new processes are
    /// started without it.
    @discardableResult
    public func unsetEnvironment(
        _ name: String,
        in scope: EnvironmentScope = .global
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            TmuxCommand("set-environment", scope.arguments + ["-u", name])
        )
    }

    /// Marks a variable so new processes start without it, even when it is set
    /// in the environment tmux itself was started from.
    @discardableResult
    public func removeEnvironment(
        _ name: String,
        in scope: EnvironmentScope = .global
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            TmuxCommand("set-environment", scope.arguments + ["-r", name])
        )
    }
}

extension TmuxEnvironmentVariable {
    /// Reads one line of `show-environment`.
    init?(line: String) {
        if line.hasPrefix("-") {
            let name = String(line.dropFirst())
            guard !name.isEmpty else { return nil }
            self.init(name: name, value: nil)
            return
        }
        // Split on the first `=` only: a value is allowed to contain more.
        guard let separator = line.firstIndex(of: "=") else { return nil }
        let name = String(line[line.startIndex..<separator])
        guard !name.isEmpty else { return nil }
        self.init(name: name, value: String(line[line.index(after: separator)...]))
    }
}
