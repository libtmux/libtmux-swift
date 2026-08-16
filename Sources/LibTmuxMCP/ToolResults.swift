import Foundation
import LibTmux

// What the tools answer with. Every one is a plain `Codable` struct, so the
// same value reaches a client as `structuredContent` and as JSON text without
// being written twice.

/// What `describe_server` answers: the facts an agent otherwise spends a turn
/// each discovering.
public struct ServerDescription: Sendable, Hashable, Codable {
    public struct Capabilities: Sendable, Hashable, Codable {
        /// `refresh-client -B`, which `watch_format` is built on.
        public let formatSubscriptions: Bool
        /// `%output`, which `wait_for_output` is built on.
        public let pushOutput: Bool
        /// Numbered replies, which `run_commands` attributes results with.
        public let controlModeBatching: Bool
    }

    public let endpoint: String
    public let tmuxVersion: String?
    /// Whether that version is inside the range this package tests against.
    public let isSupported: Bool?
    public let serverProcessID: Int?
    public let sessionCount: Int
    public let safetyTier: SafetyTier
    public let waitCeilingSeconds: Double
    /// The pane this MCP server runs in, when it runs inside this tmux. The
    /// answer to "which pane am I in?", without a call spent on it.
    public let callerPane: String?
    public let callerSession: String?
    public let capabilities: Capabilities
}

public struct CaptureResult: Sendable, Hashable, Codable {
    public let pane: String
    public let lines: [String]
    /// How many older lines the cap dropped, so a truncated read says so
    /// rather than looking like a short pane.
    public let droppedLines: Int
}

public struct PaneMatch: Sendable, Hashable, Codable {
    public let pane: String
    /// One-based, counting from the top of what was searched.
    public let line: Int
    public let text: String
}

public struct SearchResult: Sendable, Hashable, Codable {
    public let matches: [PaneMatch]
    public let panesSearched: Int
    public let panesAvailable: Int
    /// Whether the limit stopped the search before it ran out of panes.
    public let truncated: Bool
}

/// What a format evaluated to.
///
/// Wrapped rather than returned as bare text so the answer stays distinct from
/// the absence of one: a target that no longer resolves reports `null`, where a
/// field that is legitimately empty reports `""`.
public struct FormatResult: Sendable, Hashable, Codable {
    public let value: String?
}

public struct OutputWaitResult: Sendable, Hashable, Codable {
    public let outcome: String
    public let matched: String?
    public let matchedIndex: Int?
    /// `false` with `outcome: "timedOut"` means the pane really was quiet —
    /// suspect the command never ran, because no change of pattern fixes it.
    public let sawNewOutput: Bool
    /// The pattern was on screen before the wait started. Not a match — but it
    /// means the thing happened and you asked afterwards, which is the opposite
    /// problem from it never happening, and waiting longer fixes neither.
    public let matchedAtEntry: Bool
    public let tail: [String]
    public let seconds: Double
    /// What the ceiling actually allowed, which may be less than was asked for.
    public let effectiveTimeout: Double

    init(_ wait: OutputWait, effectiveTimeout: Double) {
        self.outcome = wait.outcome.rawValue
        self.matched = wait.matched
        self.matchedIndex = wait.matchedIndex
        self.sawNewOutput = wait.sawNewOutput
        self.matchedAtEntry = wait.matchedAtEntry
        self.tail = wait.tail
        self.seconds = wait.seconds
        self.effectiveTimeout = effectiveTimeout
    }
}

public struct FormatWatchResult: Sendable, Hashable, Codable {
    public let outcome: String
    /// The value the format took, or its current value on a timeout.
    public let value: String?
    public let seconds: Double
    public let effectiveTimeout: Double
}

public struct ChannelWaitResult: Sendable, Hashable, Codable {
    public let channel: String
    /// `false` means the deadline came first. Whatever would have signalled the
    /// channel is still running; calling again resumes the wait.
    public let released: Bool
    public let seconds: Double
    public let effectiveTimeout: Double
}

public struct ChannelSignalResult: Sendable, Hashable, Codable {
    public let channel: String
    public let signalled: Bool
}

public struct RunShellResult: Sendable, Hashable, Codable {
    public let pane: String
    /// The command's exit status, or `null` when the wait timed out before it
    /// finished.
    public let exitStatus: Int?
    /// The command is still running in the pane when this is true — nothing was
    /// killed, so read the pane or call again.
    public let timedOut: Bool
    /// Only what this command printed. Lines already on screen are not
    /// repeated back.
    public let output: [String]
    public let droppedLines: Int
    public let seconds: Double
    public let effectiveTimeout: Double
}

public struct SentKeys: Sendable, Hashable, Codable {
    public let pane: String
    public let keys: [String]
}

public struct Killed: Sendable, Hashable, Codable {
    public let kind: String
    public let id: String
}

public struct WorkspaceResult: Sendable, Hashable, Codable {
    public let session: Session
    public let windows: [Window]
    public let panes: [Pane]
}

/// What tmux said, in a shape a client can read without knowing tmux's
/// conventions. A nonzero exit is reported, not thrown: a client asking whether
/// a session exists wants the answer, not an error.
public struct CommandResult: Sendable, Hashable, Codable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public struct StepResult: Sendable, Hashable, Codable {
    /// Its position in the batch, so a failure names the command that caused it.
    public let step: Int
    public let command: String
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public struct BatchResult: Sendable, Hashable, Codable {
    public let steps: [StepResult]
    public let requested: Int
    /// Whether a failure stopped the batch before every command ran, as tmux
    /// itself does with a command list.
    public let stoppedEarly: Bool
}

public struct CaptureSinceResult: Sendable, Hashable, Codable {
    public let pane: String
    /// Only what arrived since the cursor. Empty means the pane has been quiet.
    public let lines: [String]
    /// Hand this back on the next call. Opaque: what it holds is the server's
    /// business, and a caller that read the fields would depend on something
    /// free to change.
    public let cursor: String
    /// The pane scrolled past what its history keeps, so some output is gone.
    public let linesMissed: Bool
    /// The pane was respawned, so the cursor described a different program.
    public let restarted: Bool
}

public struct Renamed: Sendable, Hashable, Codable {
    public let kind: String
    public let id: String
    public let name: String
}

public struct Resized: Sendable, Hashable, Codable {
    public let pane: String
    public let width: Int
    public let height: Int
}

public struct LaidOut: Sendable, Hashable, Codable {
    public let window: String
    public let layout: String
}

public struct Respawned: Sendable, Hashable, Codable {
    public let pane: String
}

public struct Pasted: Sendable, Hashable, Codable {
    public let pane: String
    public let characters: Int
}

public struct EnvironmentSet: Sendable, Hashable, Codable {
    public let name: String
    /// Absent when the variable was unset rather than given a value.
    public let value: String?
}
