import Foundation
import LibTmux

#if YAMLWorkspaces
    import Yams
#endif

/// A tmux layout described as data, in tmuxp's vocabulary.
///
/// The keys match tmuxp's so an existing workspace file is readable without
/// translation. This is a useful subset, not a reimplementation: tmuxp's
/// runtime — plugins, before/after hooks, environment inheritance — is not
/// modelled, and a file using them will build its windows and ignore the rest.
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
    /// YAML is a superset of JSON, so a file written either way loads.
    public static func decode(json: Data) throws -> Workspace {
        try JSONDecoder().decode(Workspace.self, from: json)
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
        ///     exact: "0.1.0-alpha.1",
        ///     traits: ["YAMLWorkspaces"]
        /// )
        /// ```
        public static func decode(yaml: String) throws -> Workspace {
            try YAMLDecoder().decode(Workspace.self, from: yaml)
        }
    #endif
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
public struct ShellCommand: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
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
    public let shellCommands: [ShellCommand]
    /// Where this pane starts, overriding the window's and the workspace's.
    public let startDirectory: String?

    public init(shellCommands: [ShellCommand] = [], startDirectory: String? = nil) {
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
                self.init(shellCommands: [ShellCommand(command)])
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
            [ShellCommand?].self,
            forKey: .shellCommands
        ) {
            self.init(shellCommands: list.compactMap { $0 }, startDirectory: directory)
        } else {
            let single = try container.decodeIfPresent(
                ShellCommand.self,
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
