/// The exact tmux table that owns an option.
///
/// Session and window options have global and object-local tables. A local
/// scope carries its target so direct and connected dispatch reach the same
/// object, and the target's daemon identity is checked before the command runs.
public enum OptionScope: Sendable, Hashable, Codable {
    case server
    case globalSession
    case globalWindow
    case session(Session)
    case window(Window)
    case pane(Pane)

    /// The arguments that select this table.
    var selectorArguments: [String] {
        switch self {
        case .server: ["-s"]
        case .globalSession: ["-g"]
        case .globalWindow: ["-w", "-g"]
        case let .session(session): ["-t", session.id.rawValue]
        case let .window(window): ["-w", "-t", window.id.rawValue]
        case let .pane(pane): ["-p", "-t", pane.id.rawValue]
        }
    }

    /// The table this scope addresses, in words.
    var tableDescription: String {
        switch self {
        case .server: "the server table"
        case .globalSession: "the global session table"
        case .globalWindow: "the global window table"
        case .session: "a session's own table"
        case .window: "a window's own table"
        case .pane: "a pane's own table"
        }
    }

    var guardedValue: GuardedValue? {
        switch self {
        case .server, .globalSession, .globalWindow: nil
        case let .session(session): .session(session)
        case let .window(window): .window(window)
        case let .pane(pane): .pane(pane)
        }
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
    /// The exact table this was read from.
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
/// neither, unlike ``OptionScope``, whose table addresses are all real.
public enum HookScope: Sendable, Hashable, Codable {
    case global
    /// One session's own hooks, addressed by name or id. The name is matched
    /// exactly -- see ``Server/hasSession(_:)``.
    case session(String)

    var arguments: [String] {
        switch self {
        case .global: ["-g"]
        case let .session(target): ["-t", tmuxExactSessionOfPane(target)]
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
    /// Every option set in one exact table.
    ///
    /// Reports what tmux has actually been told, not the built-in defaults —
    /// a fresh server's session table is legitimately empty. An empty result
    /// is therefore tmux's own answer: a listing tmux could not give throws,
    /// so no server and no options set cannot be mistaken for each other.
    public func options(
        _ scope: OptionScope
    ) async throws(TmuxError) -> [TmuxOption] {
        let command = TmuxCommand("show-options", scope.selectorArguments)
        let reply = try await runOptionCommand(command, in: scope)
        guard reply.isSuccess else { throw reply.failure(for: command) }
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
        scope: OptionScope = .server
    ) async throws(TmuxError) -> String? {
        let listed = try await options(scope)
        guard listed.contains(where: { $0.name == name }) else { return nil }

        let command = TmuxCommand("show-options", scope.selectorArguments + ["-v", name])
        let reply = try await runOptionCommand(command, in: scope)
        // Presence came from the listing, so `nil` is already spent on "not
        // set" and a failure here is a failure.
        guard reply.isSuccess else { throw reply.failure(for: command) }
        var value = reply.text
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    /// The effective value after tmux resolves inherited option tables.
    ///
    /// - Throws: ``TmuxError/commandFailed(command:exitCode:reason:)`` for a
    ///   name tmux does not know, which it answers the same way as a server
    ///   it cannot reach. `nil` is reserved for a value tmux reported as
    ///   absent.
    public func resolvedOption(
        _ name: String,
        scope: OptionScope
    ) async throws(TmuxError) -> String? {
        let command = TmuxCommand(
            "show-options", ["-A"] + scope.selectorArguments + ["-v", name])
        let reply = try await runOptionCommand(command, in: scope)
        guard reply.isSuccess else { throw reply.failure(for: command) }
        var value = reply.text
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    /// Sets an option.
    ///
    /// A value tmux refuses throws ``TmuxError/invocationFailed(reason:)``
    /// with tmux's reason, as every other mutation does.
    ///
    /// A scope in the wrong table is not a value tmux refuses. For one of its
    /// own options tmux takes the table from the name, so the default `.server`
    /// scope with a session option such as `mouse` exits 0 and sets it on
    /// whichever session tmux considers current. A ``TmuxOptionKey`` knows its
    /// table, and ``setOption(_:to:scope:)-(TmuxOptionKey<Value>,_,_)`` refuses
    /// the mistake instead.
    public func setOption(
        _ name: String,
        to value: String,
        scope: OptionScope = .server
    ) async throws(TmuxError) {
        try await expectOptionSuccess(
            TmuxCommand(
                "set-option",
                scope.selectorArguments + [name, value]
            ),
            in: scope
        )
    }

    /// The value of a typed option, or `nil` if it is not set in that table.
    ///
    /// - Parameters:
    ///   - key: the option, the type of its value, and its table.
    ///   - scope: the table to read, or the key's global table when `nil`.
    /// - Throws: ``TmuxError/decodingFailed(_:)`` when the option holds text
    ///   that is not a `Value`, since `nil` already means "not set".
    public func option<Value: TmuxOptionValue>(
        _ key: TmuxOptionKey<Value>,
        scope: OptionScope? = nil
    ) async throws(TmuxError) -> Value? {
        guard let text = try await option(key.name, scope: key.scope(resolving: scope)) else {
            return nil
        }
        guard let value = Value(tmuxOptionText: text) else {
            throw .decodingFailed(.invalidValue(rowIndex: 0, field: key.name, raw: text))
        }
        return value
    }

    /// Every element of an array option, by index, or `nil` if the option is
    /// not set in that table.
    ///
    /// tmux arrays are sparse: `status-format[4]` can hold a value with
    /// nothing at 2 or 3, so an element keeps its index rather than taking one
    /// from its position. An array emptied by setting it to `""` reads as
    /// empty, not `nil`. Emptying is a string set, so name the table it
    /// empties; the string call's default `.server` scope would empty the
    /// current session's copy instead:
    ///
    /// ```swift
    /// try await server.setOption("update-environment", to: "", scope: .globalSession)
    /// ```
    ///
    /// The indices come from the table listing and the values from
    /// `show-options -v`, which prints them unquoted in the same order. An
    /// element holding a newline would break that correspondence, so the
    /// mismatch throws ``TmuxError/decodingFailed(_:)`` rather than pairing
    /// values with the wrong indices.
    public func option(
        _ key: TmuxOptionKey<[Int: String]>,
        scope: OptionScope? = nil
    ) async throws(TmuxError) -> [Int: String]? {
        let scope = try key.scope(resolving: scope)
        let prefix = key.name + "["
        var listed = false
        var indices: [Int] = []
        for option in try await options(scope) {
            if option.name == key.name {
                listed = true
            } else if option.name.hasPrefix(prefix), option.name.hasSuffix("]"),
                let index = Int(option.name.dropFirst(prefix.count).dropLast())
            {
                indices.append(index)
            }
        }
        guard !indices.isEmpty else { return listed ? [:] : nil }

        let command = TmuxCommand("show-options", scope.selectorArguments + ["-v", key.name])
        let reply = try await runOptionCommand(command, in: scope)
        guard reply.isSuccess else { throw reply.failure(for: command) }
        var text = reply.text
        if text.hasSuffix("\n") { text.removeLast() }
        let values = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard values.count == indices.count else {
            throw .decodingFailed(
                .fieldCountMismatch(rowIndex: 0, expected: indices.count, actual: values.count)
            )
        }
        return Dictionary(uniqueKeysWithValues: zip(indices, values.map(String.init)))
    }

    /// Sets a typed option.
    ///
    /// - Parameters:
    ///   - key: the option, the type of its value, and its table.
    ///   - value: the value, spelled the way tmux reads it.
    ///   - scope: the table to write, or the key's global table when `nil`. A
    ///     scope whose table cannot hold the option throws
    ///     ``TmuxError/rejectedLocally(reason:)`` without invoking tmux.
    public func setOption<Value: TmuxOptionValue>(
        _ key: TmuxOptionKey<Value>,
        to value: Value,
        scope: OptionScope? = nil
    ) async throws(TmuxError) {
        try await setOption(key.name, to: value.tmuxOptionText, scope: key.scope(resolving: scope))
    }

    /// Puts a typed option back the way it was before anyone set it.
    ///
    /// For an array this restores tmux's default elements rather than
    /// emptying it. Unsetting one element removes that element alone:
    ///
    /// ```swift
    /// try await server.unsetOption(TmuxOptionKey.updateEnvironment[3])
    /// ```
    public func unsetOption<Value>(
        _ key: TmuxOptionKey<Value>,
        scope: OptionScope? = nil
    ) async throws(TmuxError) {
        try await unsetOption(key.name, scope: key.scope(resolving: scope))
    }

    /// Whether panes in `scope` outlive the command they were created with.
    ///
    /// tmux destroys a pane as its command exits, which leaves nothing to ask
    /// how the command finished — so ``Pane/exitStatus`` is `nil` for a pane
    /// that is already gone. Setting this keeps the pane, and is what a caller
    /// waiting on an exit status needs:
    ///
    /// ```swift
    /// try await server.setPanesOutliveTheirCommand(true, scope: .globalWindow)
    /// let pane = try await server.splitWindow(window, running: ["sh", "-c", "exit 42"])
    /// ```
    ///
    /// Set it before creating the pane, not after: a command that exits
    /// quickly is gone before a second call could name the pane it created.
    /// The pane then stays until something kills it, which is the caller's to
    /// arrange.
    ///
    /// This is `remain-on-exit`, typed because it is the one option
    /// ``Pane/exitStatus`` depends on, and spelling it as a string is how a
    /// caller discovers that dependency only by not finding it.
    public func setPanesOutliveTheirCommand(
        _ outlive: Bool,
        scope: OptionScope = .globalWindow
    ) async throws(TmuxError) {
        try await setOption("remain-on-exit", to: outlive ? "on" : "off", scope: scope)
    }

    /// Whether panes in `scope` outlive the command they were created with.
    ///
    /// `nil` when tmux reports no value for the scope asked about. tmux also
    /// answers `failed`, which keeps a pane only when its command exited
    /// nonzero; that reads as `true` here, since a pane can then outlive its
    /// command.
    public func panesOutliveTheirCommand(
        scope: OptionScope = .globalWindow
    ) async throws(TmuxError) -> Bool? {
        guard let value = try await option("remain-on-exit", scope: scope) else { return nil }
        return value != "off"
    }

    /// Puts an option back the way it was before anyone set it.
    ///
    /// What that means depends on the option. A user option — `@`-prefixed,
    /// which tmux never interprets — is deleted outright and stops being
    /// listed. One of tmux's own reverts to its built-in default, so it is
    /// still listed, carrying a value nobody chose.
    ///
    /// Unsetting a user option nothing was set to succeeds and changes
    /// nothing. A name tmux does not know throws
    /// ``TmuxError/invocationFailed(reason:)``.
    public func unsetOption(
        _ name: String,
        scope: OptionScope = .server
    ) async throws(TmuxError) {
        try await expectOptionSuccess(
            TmuxCommand(
                "set-option",
                scope.selectorArguments + ["-u", name]
            ),
            in: scope
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
        let command = TmuxCommand("show-hooks", scope.arguments)
        let reply = try await run(command)
        guard reply.isSuccess else { throw reply.failure(for: command) }
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

    private func runOptionCommand(
        _ command: TmuxCommand,
        in scope: OptionScope
    ) async throws(TmuxError) -> TmuxReply {
        guard let guardedValue = scope.guardedValue else {
            return try await run(command)
        }
        return try await runGuarded(command, by: [guardedValue])
    }

    private func expectOptionSuccess(
        _ command: TmuxCommand,
        in scope: OptionScope
    ) async throws(TmuxError) {
        guard let guardedValue = scope.guardedValue else {
            return try await expectSuccess(command)
        }
        try await expectSuccess(command, guardedBy: [guardedValue])
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
