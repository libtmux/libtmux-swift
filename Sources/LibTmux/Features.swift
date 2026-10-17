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

    var minimum: TmuxVersion {
        switch self {
        case .controlConnection: TmuxVersion(major: 3, minor: 7)
        case .namedBufferEditing: TmuxVersion(major: 3, minor: 4)
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
/// Only commands written as argv are read. A shell command, an `if-shell` body
/// or a configured alias is the caller's own program and stays outside it.
enum TmuxCommandGuard {
    /// Throws for the first command the release cannot run safely.
    static func check(
        _ arguments: [String],
        against checked: ServerVersion
    ) throws(TmuxError) {
        for command in commands(in: arguments) {
            guard let name = command.first.map(canonicalName) else { continue }
            let rest = Array(command.dropFirst())
            try check(name, rest, checked)
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
        let namedBufferEditing = TmuxFeature.namedBufferEditing.minimum
        switch name {
        case "delete-buffer":
            if value(of: "-b", in: arguments, takingValue: ["-b"]) != nil,
                version < namedBufferEditing
            {
                throw refuse(namedBufferEditing, "delete-buffer -b")
            }
        case "set-buffer":
            if value(of: "-n", in: arguments, takingValue: ["-a", "-b", "-n", "-w"]) != nil,
                version < namedBufferEditing
            {
                throw refuse(namedBufferEditing, "set-buffer -n")
            }
        case "break-pane":
            let named = value(of: "-n", in: arguments, takingValue: breakPaneValues)
            if named == nil, isExactly(version, 3, 7) {
                throw refuse(
                    TmuxVersion(major: 3, minor: 7, pointRelease: "a"), "break-pane without -n")
            }
            if let named, isExactly(version, 3, 7), named.contains(":") || named.contains(".") {
                throw refuse(
                    TmuxVersion(major: 3, minor: 7, pointRelease: "a"),
                    "a window name containing ':' or '.'")
            }
        case "new-window":
            try checkName("-n", arguments, ["-c", "-e", "-F", "-n", "-t"], version, checked)
        case "new-session":
            try checkName("-s", arguments, newSessionValues, version, checked)
            try checkName("-n", arguments, newSessionValues, version, checked)
        case "rename-window", "rename-session":
            if isExactly(version, 3, 7), let target = arguments.last,
                !target.hasPrefix("-"), target.contains(":") || target.contains(".")
            {
                throw refuse(
                    TmuxVersion(major: 3, minor: 7, pointRelease: "a"),
                    "a name containing ':' or '.'")
            }
        case "split-window":
            if isExactly(version, 3, 4),
                value(of: "-p", in: arguments, takingValue: splitValues) != nil
            {
                throw refuse(TmuxVersion(major: 3, minor: 5), "split-window -p")
            }
        case "select-layout":
            let beforeValidation = TmuxVersion(major: 3, minor: 4)
            guard version < beforeValidation else { return }
            let flags = arguments.filter { $0.hasPrefix("-") && $0.count == 2 }
            guard !flags.contains(where: { ["-n", "-o", "-p"].contains($0) }) else { return }
            let layout = positional(arguments, takingValue: ["-t"])
            if let layout, !LayoutSyntax.accepts(layout, version: version, panes: 1) {
                throw refuse(beforeValidation, "select-layout with an unvalidated layout")
            }
        default:
            return
        }
    }

    private static let breakPaneValues: Set<String> = ["-F", "-n", "-s", "-t"]
    private static let newSessionValues: Set<String> = [
        "-c", "-e", "-f", "-F", "-n", "-s", "-t", "-x", "-y",
    ]
    private static let splitValues: Set<String> = ["-c", "-e", "-F", "-l", "-p", "-t"]

    private static func checkName(
        _ flag: String, _ arguments: [String], _ valued: Set<String>,
        _ version: TmuxVersion, _ checked: ServerVersion
    ) throws(TmuxError) {
        guard isExactly(version, 3, 7),
            let name = value(of: flag, in: arguments, takingValue: valued),
            name.contains(":") || name.contains(".")
        else { return }
        throw .unsupportedTmuxVersion(
            reported: checked.token, required: "3.7a",
            operation: "a name containing ':' or '.'")
    }

    /// Exactly the release `major.minor`, with no patch letter or build: the
    /// one release a defect shipped in.
    private static func isExactly(_ version: TmuxVersion, _ major: Int, _ minor: Int) -> Bool {
        version.major == major && version.minor == minor && version.pointRelease.isEmpty
            && version.build == nil
    }

    private static func canonicalName(_ name: String) -> String {
        switch name {
        case "deleteb": "delete-buffer"
        case "setb": "set-buffer"
        case "breakp": "break-pane"
        case "neww": "new-window"
        case "new": "new-session"
        case "renamew": "rename-window"
        case "rename": "rename-session"
        case "splitw": "split-window"
        case "selectl": "select-layout"
        default: name
        }
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

    /// The value of `flag` when it appears as a flag of the command, reading
    /// bundled flags and skipping the values of the flags that take one.
    private static func value(
        of flag: String, in arguments: [String], takingValue valued: Set<String>
    ) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return nil }
            guard argument.hasPrefix("-"), argument.count >= 2 else { return nil }
            let letters = Array(argument.dropFirst())
            var position = 0
            while position < letters.count {
                let current = "-\(letters[position])"
                if valued.contains(current) {
                    let inline = String(letters[(position + 1)...])
                    let found: String? =
                        inline.isEmpty
                        ? (index + 1 < arguments.count ? arguments[index + 1] : nil) : inline
                    if current == flag { return found ?? "" }
                    index += inline.isEmpty ? 1 : 0
                    break
                }
                if current == flag { return "" }
                position += 1
            }
            index += 1
        }
        return nil
    }

    /// The first operand that is not a flag or a flag's value.
    private static func positional(
        _ arguments: [String], takingValue valued: Set<String>
    ) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return index + 1 < arguments.count ? arguments[index + 1] : nil }
            if argument.hasPrefix("-"), argument.count >= 2 {
                if valued.contains(argument) { index += 1 }
                index += 1
                continue
            }
            return argument
        }
        return nil
    }
}
