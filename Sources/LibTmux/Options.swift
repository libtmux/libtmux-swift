/// Which table an option or hook lives in.
///
/// tmux keeps four, and the same name can mean different things in different
/// ones, so a scope is part of an option's identity rather than a detail of how
/// it was read.
public enum OptionScope: Sendable, Hashable, Codable {
    case server
    case session
    case window
    case pane

    /// The flag that selects this table. `show-options` and `set-option` agree
    /// on these, which is why one value serves both directions.
    var flag: String {
        switch self {
        case .server: "-s"
        case .session: ""
        case .window: "-w"
        case .pane: "-p"
        }
    }

    /// The flags that select this table.
    ///
    /// Session and window tables each have a global tier and a per-object one,
    /// and they are genuinely different storage: a hook set globally is not
    /// visible in the local table. Server and pane tables have no such split,
    /// so `global` does not apply to them.
    func selectorArguments(global: Bool) -> [String] {
        var arguments = flag.isEmpty ? [] : [flag]
        if global, self == .session || self == .window {
            arguments.append("-g")
        }
        return arguments
    }
}

/// One tmux option.
public struct TmuxOption: Sendable, Hashable, Codable {
    /// The option's name as tmux spells it, `@`-prefixed for a user option.
    public let name: String
    /// The value exactly as tmux printed it. tmux quotes values that need it,
    /// and unquoting is lossy without knowing the option's type, so the raw
    /// text is what the library keeps.
    public let value: String
    /// Which of tmux's four tables this was read from. The same name can mean
    /// different things in different ones, so it is part of the identity
    /// rather than a note about how it was fetched.
    public let scope: OptionScope

    public init(name: String, value: String, scope: OptionScope) {
        self.name = name
        self.value = value
        self.scope = scope
    }

    /// A user option — one whose name begins with `@`. tmux never interprets
    /// these, so they are the safe place to keep your own state on a server.
    public var isUserOption: Bool { name.hasPrefix("@") }
}

/// Which of tmux's hook tables a hook lives in.
///
/// tmux keeps two, and only two: one global, and one per session. `set-hook`
/// takes `-w` and `-p` and reports success for both, but the hook lands in the
/// session's table either way, and `show-hooks` has no server flag at all — so
/// a window or pane scope here would only ever read back empty. This asks for
/// neither, unlike ``OptionScope``, whose four tables are all real.
public enum HookScope: Sendable, Hashable, Codable {
    case global
    /// One session's own hooks, addressed by name or id.
    case session(String)

    var arguments: [String] {
        switch self {
        case .global: ["-g"]
        case let .session(target): ["-t", target]
        }
    }
}

/// One tmux hook: a command tmux runs when something happens.
public struct TmuxHook: Sendable, Hashable, Codable {
    /// The event this runs on, as tmux names it — `after-new-window`.
    public let name: String
    /// Which slot of the name's array holds this command.
    ///
    /// tmux stores an array per hook name and labels every bound command with
    /// its position, filling `[0]` when a caller does not choose one. So a
    /// reported hook always has an index, and reading one costs no unwrapping.
    public let index: Int
    /// The tmux command line to run, kept unparsed because tmux parses it
    /// itself at the moment the hook fires.
    public let command: String
    /// Which of the two hook tables this was read from.
    public let scope: HookScope

    public init(name: String, index: Int, command: String, scope: HookScope) {
        self.name = name
        self.index = index
        self.command = command
        self.scope = scope
    }
}

extension Server {
    /// Every option set in one table.
    ///
    /// Reports what tmux has actually been told, not the built-in defaults —
    /// a fresh server's session table is legitimately empty.
    public func options(
        _ scope: OptionScope,
        global: Bool = false
    ) async throws(TmuxError) -> [TmuxOption] {
        let reply = try await run(
            TmuxCommand("show-options", scope.selectorArguments(global: global))
        )
        guard reply.isSuccess else { return [] }
        return reply.text.split(separator: "\n").map { line in
            let (name, value) = splitOnFirstSpace(String(line))
            return TmuxOption(name: name, value: value, scope: scope)
        }
    }

    /// The value of one option, or `nil` if it is not set in that table.
    ///
    /// Presence comes from the table listing and the value from
    /// `show-options -v`, because neither answers both portably: the listing
    /// quotes a value containing spaces, while `-v` reports "not set" as exit 0
    /// with empty output on 3.2a and exit 1 on 3.7 — and reading emptiness as
    /// absence would erase the difference between an option nobody set and one
    /// deliberately set to "".
    public func option(
        _ name: String,
        scope: OptionScope = .server,
        global: Bool = false
    ) async throws(TmuxError) -> String? {
        let listed = try await options(scope, global: global)
        guard listed.contains(where: { $0.name == name }) else { return nil }

        let reply = try await run(
            TmuxCommand(
                "show-options",
                scope.selectorArguments(global: global) + ["-v", name]
            )
        )
        guard reply.isSuccess else { return nil }
        var value = reply.text
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    /// Sets an option.
    @discardableResult
    public func setOption(
        _ name: String,
        to value: String,
        scope: OptionScope = .server,
        global: Bool = false
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            TmuxCommand(
                "set-option",
                scope.selectorArguments(global: global) + [name, value]
            )
        )
    }

    /// Puts an option back the way it was before anyone set it.
    ///
    /// What that means depends on the option. A user option — `@`-prefixed,
    /// which tmux never interprets — is deleted outright and stops being
    /// listed. One of tmux's own reverts to its built-in default, so it is
    /// still listed, carrying a value nobody chose.
    ///
    /// Unsetting a name nothing was set to succeeds and changes nothing.
    @discardableResult
    public func unsetOption(
        _ name: String,
        scope: OptionScope = .server,
        global: Bool = false
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            TmuxCommand(
                "set-option",
                scope.selectorArguments(global: global) + ["-u", name]
            )
        )
    }

    /// Hooks tmux has a command for.
    ///
    /// `show-hooks` lists every hook name tmux knows, most with nothing bound.
    /// Only the bound ones are reported here — an unbound name is not a hook,
    /// it is a place one could go.
    public func hooks(
        _ scope: HookScope = .global
    ) async throws(TmuxError) -> [TmuxHook] {
        let reply = try await run(TmuxCommand("show-hooks", scope.arguments))
        guard reply.isSuccess else { return [] }
        return reply.text.split(separator: "\n").compactMap { line in
            let (label, command) = splitOnFirstSpace(String(line))
            guard !command.isEmpty else { return nil }
            // Every supported release labels a bound command with its slot. A
            // line carrying a command but no slot is a listing this cannot
            // attribute, so it is left out rather than reported at a position
            // tmux never gave it.
            guard let (name, index) = splitTrailingIndex(label) else { return nil }
            return TmuxHook(name: name, index: index, command: command, scope: scope)
        }
    }

    /// Binds a command to a hook.
    ///
    /// Without an index this replaces every command bound to the name, leaving
    /// the one given at slot 0 — tmux assigns the array, not just an element.
    /// Pass `at:` to write one slot and leave its neighbours alone.
    ///
    /// A name tmux does not know is a reply reporting why, not a thrown error.
    ///
    /// - Parameters:
    ///   - name: a hook name tmux knows, such as `after-new-window`.
    ///   - command: the tmux command line to run, unparsed until tmux runs it.
    ///   - index: which slot to write, or every slot when omitted.
    ///   - scope: which table to write to.
    @discardableResult
    public func setHook(
        _ name: String,
        to command: String,
        at index: Int? = nil,
        in scope: HookScope = .global
    ) async throws(TmuxError) -> TmuxReply {
        let slot = index.map { "\(name)[\($0)]" } ?? name
        return try await run(
            TmuxCommand("set-hook", scope.arguments + [slot, command])
        )
    }

    /// Unbinds every command from a hook.
    ///
    /// In the global table tmux empties the array but keeps listing the name,
    /// so an unset hook reads as a name with nothing behind it — which is what
    /// an unbound name looks like to begin with, and why ``hooks(_:)`` reports
    /// neither. Unsetting a name nothing was bound to succeeds.
    @discardableResult
    public func unsetHook(
        _ name: String,
        in scope: HookScope = .global
    ) async throws(TmuxError) -> TmuxReply {
        try await run(TmuxCommand("set-hook", scope.arguments + ["-u", name]))
    }

    /// Runs a hook's commands now, without waiting for what would trigger it.
    ///
    /// Running a name nothing is bound to succeeds and does nothing.
    @discardableResult
    public func runHook(
        _ name: String,
        in scope: HookScope = .global
    ) async throws(TmuxError) -> TmuxReply {
        try await run(TmuxCommand("set-hook", scope.arguments + ["-R", name]))
    }
}

/// tmux prints `name value`, and a value may contain spaces, so only the first
/// space is a separator.
private func splitOnFirstSpace(_ line: String) -> (String, String) {
    guard let space = line.firstIndex(of: " ") else { return (line, "") }
    return (
        String(line[line.startIndex..<space]),
        String(line[line.index(after: space)...])
    )
}

/// tmux labels a bound hook `name[0]`. Anything not ending in a bracketed
/// number carries no slot, and this reports that rather than inventing one.
private func splitTrailingIndex(_ label: String) -> (String, Int)? {
    guard label.hasSuffix("]"), let open = label.lastIndex(of: "[") else {
        return nil
    }
    let digits = label[label.index(after: open)..<label.index(before: label.endIndex)]
    guard let index = Int(digits) else { return nil }
    return (String(label[label.startIndex..<open]), index)
}
