import Foundation
import LibTmux

#if YAMLWorkspaces
    import Yams
#endif

/// A tmux layout described as data, in tmuxp's vocabulary.
///
/// The modelled keys use tmuxp's spelling, so files limited to this structural
/// subset need no translation. tmuxp's plugins, hooks, and environment runtime
/// are ignored.
public struct Workspace: Sendable, Hashable, Codable {
    /// What the session is called once built.
    public let sessionName: String
    /// Where every window starts unless it names its own. Left out, tmux uses
    /// whatever directory it was started from.
    public let startDirectory: String?
    /// The windows to build, in the order they are written.
    public let windows: [WindowPlan]

    public init(
        sessionName: String,
        startDirectory: String? = nil,
        windows: [WindowPlan]
    ) {
        self.sessionName = sessionName
        self.startDirectory = startDirectory
        self.windows = windows
    }

    enum CodingKeys: String, CodingKey {
        case sessionName = "session_name"
        case startDirectory = "start_directory"
        case windows
    }

    /// Reads a workspace from JSON.
    ///
    /// - Parameters:
    ///   - json: the workspace document.
    ///   - strict: refuses a key this type does not model instead of dropping
    ///     it. tmuxp's format is larger than the structural subset built here
    ///     — `shell_command_before`, `sleep_before`, `options`, plugins and
    ///     hooks among them — and a file carrying one decodes cleanly and
    ///     builds a session that is quietly not what the file described.
    ///     Pass `true` when the file came from someone else.
    public static func decode(json: Data, strict: Bool = false) throws -> Workspace {
        if strict {
            let raw = try JSONSerialization.jsonObject(with: json)
            try requireOnlyModelledKeys(in: raw)
        }
        return try JSONDecoder().decode(Workspace.self, from: json)
    }

    /// Every key this type reads, by the level it appears at.
    ///
    /// `cmd` and `enter` belong to an entry inside `shell_command`, not to a
    /// pane. tmuxp does take `enter` on a pane, applying it to every command
    /// there; this type does not read it, so strict decoding refuses it
    /// rather than dropping a "leave this line unrun" the file asked for.
    static let modelledKeys:
        (root: Set<String>, window: Set<String>, pane: Set<String>, command: Set<String>) = (
            root: ["session_name", "start_directory", "windows"],
            window: ["window_name", "start_directory", "layout", "panes"],
            pane: ["shell_command", "start_directory"],
            command: ["cmd", "enter"]
        )

    /// Refuses a document carrying a key no level of this type reads.
    static func requireOnlyModelledKeys(in raw: Any) throws {
        var unsupported: [String] = []

        func check(_ value: Any, against known: Set<String>, at level: String) {
            guard let object = value as? [String: Any] else { return }
            for key in object.keys.sorted() where !known.contains(key) {
                unsupported.append("\(level).\(key)")
            }
        }

        check(raw, against: modelledKeys.root, at: "workspace")
        let windows = (raw as? [String: Any])?["windows"] as? [Any] ?? []
        for window in windows {
            check(window, against: modelledKeys.window, at: "window")
            let panes = (window as? [String: Any])?["panes"] as? [Any] ?? []
            for pane in panes {
                // A pane may be a bare command string rather than a mapping.
                check(pane, against: modelledKeys.pane, at: "pane")
                let commands = (pane as? [String: Any])?["shell_command"]
                for command in commands as? [Any] ?? [commands as Any] {
                    // So may a command: only the long form has keys at all.
                    check(command, against: modelledKeys.command, at: "shell_command")
                }
            }
        }

        guard unsupported.isEmpty else {
            throw WorkspaceDecodingError.unsupportedKeys(Array(Set(unsupported)).sorted())
        }
    }

    #if YAMLWorkspaces
        /// Reads a workspace from YAML, which is how tmuxp files are usually
        /// written.
        ///
        /// Available when the `YAMLWorkspaces` trait is enabled, which is what
        /// pulls in the YAML parser:
        ///
        /// ```swift
        /// .package(
        ///     url: "https://github.com/libtmux/libtmux-swift.git",
        ///     exact: "0.1.0-alpha.5",
        ///     traits: ["YAMLWorkspaces"]
        /// )
        /// ```
        public static func decode(yaml: String, strict: Bool = false) throws -> Workspace {
            if strict, let raw = try Yams.load(yaml: yaml) {
                try requireOnlyModelledKeys(in: raw)
            }
            return try YAMLDecoder().decode(Workspace.self, from: yaml)
        }
    #endif
}

/// Why a workspace document was refused.
public enum WorkspaceDecodingError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Keys no level of ``Workspace`` reads, qualified by where they appeared.
    ///
    /// tmuxp's format is larger than the structural subset modelled here, and
    /// a file carrying one of its other keys would otherwise build a session
    /// that is quietly not what the file described.
    case unsupportedKeys([String])

    public var description: String {
        switch self {
        case let .unsupportedKeys(keys):
            "the workspace carries keys this type does not model: "
                + keys.joined(separator: ", ")
        }
    }
}

/// One window, and the panes in it.
public struct WindowPlan: Sendable, Hashable, Codable {
    /// What to call it. Left out, tmux names it after what runs in it.
    public let windowName: String?
    /// Where this window's panes start, overriding the workspace's own.
    public let startDirectory: String?
    /// tmux's own layout name — `even-horizontal`, `tiled`, and the rest —
    /// applied after the panes exist.
    public let layout: String?
    /// The panes to open. The first is the window itself; each one after it
    /// splits what is already there.
    public let panes: [PanePlan]

    public init(
        windowName: String? = nil,
        startDirectory: String? = nil,
        layout: String? = nil,
        panes: [PanePlan]
    ) {
        self.windowName = windowName
        self.startDirectory = startDirectory
        self.layout = layout
        self.panes = panes
    }

    /// Describes a window using a named or custom typed layout.
    ///
    /// The stored ``layout`` and its JSON/YAML representation remain strings.
    public init(
        windowName: String? = nil,
        startDirectory: String? = nil,
        layout: WindowLayout,
        panes: [PanePlan]
    ) {
        self.init(
            windowName: windowName, startDirectory: startDirectory,
            layout: layout.rawValue, panes: panes
        )
    }

    enum CodingKeys: String, CodingKey {
        case windowName = "window_name"
        case startDirectory = "start_directory"
        case layout
        case panes
    }
}

/// A command to put in a pane, and whether to run it.
///
/// tmuxp writes most commands as a bare string, and that is what a string
/// literal here means — type it and press enter. The long form, `{cmd:,
/// enter:}`, exists to leave a command sitting in the pane unrun, which is why
/// `enter` is modelled rather than dropped.
public struct TmuxShellCommand: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
    /// The line to type into the pane.
    public let command: String
    /// Whether to press enter after typing it. False leaves the line sitting
    /// at the prompt, ready but not run.
    public let enter: Bool

    public init(_ command: String, enter: Bool = true) {
        self.command = command
        self.enter = enter
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    enum CodingKeys: String, CodingKey {
        case command = "cmd"
        case enter
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
            let command = try? single.decode(String.self)
        {
            self.init(command)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(String.self, forKey: .command),
            enter: try container.decodeIfPresent(Bool.self, forKey: .enter) ?? true
        )
    }

    /// Written back the way it was most likely written: a bare string unless
    /// `enter` carries information a string cannot.
    public func encode(to encoder: any Encoder) throws {
        guard enter else {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .command)
            try container.encode(enter, forKey: .enter)
            return
        }
        var single = encoder.singleValueContainer()
        try single.encode(command)
    }
}

/// One pane, and what to run in it.
///
/// tmuxp lets a pane be written as a bare string, which means "run this", so
/// that spelling decodes too.
public struct PanePlan: Sendable, Hashable, Codable {
    /// What to run in the pane, in order, once it exists.
    public let shellCommands: [TmuxShellCommand]
    /// Where this pane starts, overriding the window's and the workspace's.
    public let startDirectory: String?

    public init(shellCommands: [TmuxShellCommand] = [], startDirectory: String? = nil) {
        self.shellCommands = shellCommands
        self.startDirectory = startDirectory
    }

    enum CodingKeys: String, CodingKey {
        case shellCommands = "shell_command"
        case startDirectory = "start_directory"
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            // tmuxp writes a pane with nothing to run as null: a pane holding
            // just a shell, not a missing one.
            if single.decodeNil() {
                self.init()
                return
            }
            if let command = try? single.decode(String.self) {
                self.init(shellCommands: [TmuxShellCommand(command)])
                return
            }
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let directory = try container.decodeIfPresent(
            String.self,
            forKey: .startDirectory
        )
        // `shell_command` is a string or a list of them, depending on who wrote
        // the file.
        // Elements are optional because a list is allowed to hold a null
        // where a command would go, which means there is no command there.
        if let list = try? container.decodeIfPresent(
            [TmuxShellCommand?].self,
            forKey: .shellCommands
        ) {
            self.init(shellCommands: list.compactMap { $0 }, startDirectory: directory)
        } else {
            let single = try container.decodeIfPresent(
                TmuxShellCommand.self,
                forKey: .shellCommands
            )
            self.init(
                shellCommands: single.map { [$0] } ?? [],
                startDirectory: directory
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shellCommands, forKey: .shellCommands)
        try container.encodeIfPresent(startDirectory, forKey: .startDirectory)
    }
}
