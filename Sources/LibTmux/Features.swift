import Foundation

/// An operation that needs a newer tmux than the core floor.
///
/// Each names the release it needs and what it protects, so a refusal can say
/// both. None raises the floor for the rest of the library: ordinary commands,
/// polling and workspace construction keep working on every supported daemon.
enum TmuxFeature: Sendable {
    case controlConnection
    case namedBufferEditing

    var operation: String {
        switch self {
        case .controlConnection: "library-managed control-mode connections"
        case .namedBufferEditing: "named buffer deletion and rename"
        }
    }

    /// Read from the capability table, so the gate and the published manifest
    /// cannot disagree.
    var minimum: TmuxVersion {
        switch self {
        case .controlConnection: Support.Capabilities.capability("control-mode").minimum
        case .namedBufferEditing: Support.Capabilities.capability("buffer-delete-named").minimum
        }
    }

    func require(_ checked: ServerVersion) throws(TmuxError) {
        guard checked.version >= minimum else {
            throw .unsupportedTmuxVersion(
                reported: checked.token, required: "\(minimum)", operation: operation)
        }
    }
}

extension Server {
    /// Refuses an operation the daemon's release cannot serve safely, before
    /// the operation creates any state.
    func require(_ feature: TmuxFeature) async throws(TmuxError) {
        try feature.require(try await versionCheck().version)
    }

    /// Whether the daemon at this endpoint can be attached to with control
    /// mode. An unsupported release answers `false`; a release too old to be
    /// checked at all still throws.
    func supportsControl() async throws(TmuxError) -> Bool {
        (try await versionCheck().version).version >= TmuxFeature.controlConnection.minimum
    }

    /// Refuses a staged buffer on a release that cannot delete it exactly.
    package func requireNamedBufferEditing() async throws(TmuxError) {
        try await require(.namedBufferEditing)
    }
}

/// What a literal batch asks of the daemon it is about to reach.
///
/// Only commands written as argv are read, and each is named the way tmux
/// names it: the full name, its alias, any unique prefix of a name (`break-p`,
/// `br`) and the default `command-alias` spellings of `split-window`
/// (`TmuxCommandTable`). A `;`-separated list is read command by command.
///
/// What a command carries as a string for tmux to parse again is not read.
/// For example, the body of `if-shell`, `run-shell -C` and `confirm-before`,
/// the template of `command-prompt`, `display-menu` and the `choose-*`
/// commands, a file named to `source-file`, a brace block, a hook or key
/// binding, and a `command-alias` the caller set. Any command that takes
/// tmux commands as text is in this group. Do not nest a command that this
/// guard refuses; it reaches the daemon unchecked there.
/// A shell command is the caller's own program.
enum TmuxCommandGuard {
    /// Throws for the first command the release cannot run safely.
    static func check(
        _ arguments: [String],
        against checked: ServerVersion
    ) throws(TmuxError) {
        for command in commands(in: arguments) {
            guard let word = command.first,
                let name = TmuxCommandTable.resolve(word, on: checked.version)
            else { continue }
            try check(name, Array(command.dropFirst()), checked)
        }
    }

    private static func check(
        _ name: String, _ arguments: [String], _ checked: ServerVersion
    ) throws(TmuxError) {
        let version = checked.version
        func refuse(_ required: TmuxVersion, _ operation: String) -> TmuxError {
            .unsupportedTmuxVersion(
                reported: checked.token, required: "\(required)", operation: operation)
        }
        let deleteNamed = Support.Capabilities.capability("buffer-delete-named").minimum
        let renameBuffer = Support.Capabilities.capability("buffer-rename").minimum
        let breakPane = Support.Capabilities.workaround("break-pane-misnames-windows")
        let separators = Support.Capabilities.workaround("name-separators-rejected")
        let percentSplit = Support.Capabilities.workaround("split-window-percent-size")
        let parsed = ParsedArguments(arguments, template: templates[name] ?? "")
        switch name {
        case "delete-buffer":
            if parsed.value(of: "b") != nil, version < deleteNamed {
                throw refuse(deleteNamed, "delete-buffer -b")
            }
        case "set-buffer":
            if parsed.value(of: "n") != nil, version < renameBuffer {
                throw refuse(renameBuffer, "set-buffer -n")
            }
        case "break-pane":
            let named = parsed.value(of: "n")
            if named == nil, breakPane.affects(version) {
                throw refuse(breakPane.fixed, "break-pane without -n")
            }
            if let named, separators.affects(version), hasSeparator(named) {
                throw refuse(separators.fixed, "a window name containing ':' or '.'")
            }
        case "new-window":
            try checkName(parsed.value(of: "n"), version, checked)
        case "new-session":
            try checkName(parsed.value(of: "s"), version, checked)
            try checkName(parsed.value(of: "n"), version, checked)
        case "rename-window", "rename-session":
            try checkName(parsed.operands.first, version, checked)
        case "split-window":
            if percentSplit.affects(version), parsed.value(of: "p") != nil {
                throw refuse(percentSplit.fixed, "split-window -p")
            }
        case "refresh-client":
            let clipboard = Support.Capabilities.capability("clipboard-query").minimum
            if parsed.has("l"), version < clipboard {
                throw refuse(clipboard, "refresh-client -l")
            }
        case "select-layout":
            let beforeValidation = Support.Capabilities.capability("layout-without-checksum")
                .minimum
            guard version < beforeValidation else { return }
            guard !(["n", "o", "p"] as [Character]).contains(where: parsed.has) else { return }
            if let layout = parsed.operands.first,
                !LayoutSyntax.accepts(layout, version: version, panes: 1)
            {
                throw refuse(beforeValidation, "select-layout with an unvalidated layout")
            }
        default:
            return
        }
    }

    /// The arguments of each command as tmux's own `args_parse` reads them,
    /// from the `args` string in the command's `cmd-*.c` file: a letter, and a
    /// colon after it when the flag takes a value. The newest release's string
    /// is used for every release. An older release accepts a subset of its
    /// flags and rejects the rest, and a command tmux rejects does not run.
    static let templates: [String: String] = [
        "break-pane": "abdPF:n:s:t:Wx:X:y:Y:",
        "delete-buffer": "b:",
        "new-session": "Ac:dDe:EF:f:n:Ps:t:x:Xy:",
        "new-window": "abc:de:EF:kn:PSt:",
        "refresh-client": "A:B:cC:Df:r:F:l::LRSt:U",
        "rename-session": "t:",
        "rename-window": "t:",
        "select-layout": "Enopt:",
        "set-buffer": "ab:t:n:w",
        "split-window": "bB:c:de:EfF:hIkl:m:p:PR:s:S:t:T:vWZ",
    ]

    private static func hasSeparator(_ name: String) -> Bool {
        name.contains(":") || name.contains(".")
    }

    private static func checkName(
        _ name: String?, _ version: TmuxVersion, _ checked: ServerVersion
    ) throws(TmuxError) {
        let separators = Support.Capabilities.workaround("name-separators-rejected")
        guard separators.affects(version), let name, hasSeparator(name) else { return }
        throw .unsupportedTmuxVersion(
            reported: checked.token, required: "\(separators.fixed)",
            operation: "a name containing ':' or '.'")
    }

    /// The commands of a batch: arguments up to each separator argument.
    private static func commands(in arguments: [String]) -> [[String]] {
        var result: [[String]] = [[]]
        for argument in arguments {
            if argument == ";" {
                result.append([])
            } else if argument.hasSuffix(";"), !argument.hasSuffix(#"\;"#) {
                result[result.count - 1].append(String(argument.dropLast()))
                result.append([])
            } else {
                result[result.count - 1].append(argument)
            }
        }
        return result.filter { !$0.isEmpty }
    }
}

/// One command's arguments, split the way tmux's `args_parse` splits them.
///
/// Flags are read until the first argument that is not one, or a `--`. A flag
/// the template gives a colon takes the rest of its cluster as its value, or
/// the next argument when nothing is left. A repeated flag keeps its last
/// value. A letter the template does not list is read as a flag without a
/// value: tmux rejects it, so the command does not run, and reading on keeps
/// the arguments after it from being misread.
struct ParsedArguments {
    /// Each flag given, with its value, or an empty string when it takes none.
    private(set) var flags: [Character: String] = [:]
    private(set) var operands: [String] = []

    /// The flags of `template` that take a value.
    static func valuedFlags(in template: String) -> Set<Character> {
        let letters = Array(template)
        var valued: Set<Character> = []
        for (position, letter) in letters.enumerated()
        where
            letter != ":" && position + 1 < letters.count && letters[position + 1] == ":"
            && !(position + 2 < letters.count && letters[position + 2] == ":")
        {
            valued.insert(letter)
        }
        return valued
    }

    /// The flags of `template` that take a value only when it is attached to
    /// the flag (`-lvalue`), written with two colons.
    static func optionallyValuedFlags(in template: String) -> Set<Character> {
        let letters = Array(template)
        var optional: Set<Character> = []
        for (position, letter) in letters.enumerated()
        where
            letter != ":" && position + 2 < letters.count && letters[position + 1] == ":"
            && letters[position + 2] == ":"
        {
            optional.insert(letter)
        }
        return optional
    }

    init(_ arguments: [String], template: String) {
        let valued = Self.valuedFlags(in: template)
        let optional = Self.optionallyValuedFlags(in: template)
        var index = 0
        scan: while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-"), argument.count >= 2 else { break }
            index += 1
            if argument == "--" { break }
            let cluster = Array(argument.dropFirst())
            for (position, flag) in cluster.enumerated() {
                if optional.contains(flag) {
                    flags[flag] = String(cluster[(position + 1)...])
                    continue scan
                }
                guard valued.contains(flag) else {
                    flags[flag] = ""
                    continue
                }
                let inline = String(cluster[(position + 1)...])
                if !inline.isEmpty {
                    flags[flag] = inline
                } else if index < arguments.count {
                    flags[flag] = arguments[index]
                    index += 1
                } else {
                    flags[flag] = ""
                }
                continue scan
            }
        }
        operands = Array(arguments[index...])
    }

    func has(_ flag: Character) -> Bool { flags[flag] != nil }

    /// The value of `flag`, or an empty string for a flag without one; `nil`
    /// when the flag is absent.
    func value(of flag: Character) -> String? { flags[flag] }
}
