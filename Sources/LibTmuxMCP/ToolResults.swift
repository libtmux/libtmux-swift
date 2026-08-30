import Foundation
import LibTmux

// What the tools answer with. Every one is a plain `Codable` struct, so the
// same value reaches a client as `structuredContent` and as JSON text without
// being written twice.

/// What `describe_server` answers: the facts an agent otherwise spends a turn
/// each discovering.
struct ServerDescription: Sendable, Hashable, Codable {
    struct Capabilities: Sendable, Hashable, Codable {
        /// `refresh-client -B`, which `watch_format` is built on.
        public let formatSubscriptions: Bool
        /// `%output`, which `wait_for_output` is built on.
        public let pushOutput: Bool
        /// Numbered replies available to connected-mode consumers.
        public let controlModeBatching: Bool
    }

    let ref: String
    let endpoint: String
    let tmuxVersion: String?
    /// Whether that version is inside the range this package tests against.
    let isSupported: Bool?
    let serverProcessID: Int?
    let sessionCount: Int
    let safetyTier: SafetyTier
    let waitCeilingSeconds: Double
    /// The pane this MCP server runs in, when it runs inside this tmux. The
    /// answer to "which pane am I in?", without a call spent on it.
    let callerPane: String?
    let callerSession: String?
    let capabilities: Capabilities
}

struct SessionResult: Sendable, Hashable, Codable {
    let ref: String
    let id: String
    let name: String
    let windowCount: Int
    let isAttached: Bool
    let createdAt: Int

    init(_ session: Session, references: WireReferenceCodec = .processLocal) {
        self.ref = references.reference(to: session)
        self.id = session.id.rawValue
        self.name = session.name
        self.windowCount = session.windowCount
        self.isAttached = session.isAttached
        self.createdAt = session.createdAt
    }
}

struct WindowResult: Sendable, Hashable, Codable {
    let ref: String
    let id: String
    let name: String
    let paneCount: Int
    let width: Int
    let height: Int

    init(_ window: Window, references: WireReferenceCodec = .processLocal) {
        self.ref = references.reference(to: window)
        self.id = window.id.rawValue
        self.name = window.name
        self.paneCount = window.paneCount
        self.width = window.width
        self.height = window.height
    }
}

struct WindowLinkResult: Sendable, Hashable, Codable {
    let ref: String
    let sessionID: String
    let windowID: String
    let index: Int
    let isActive: Bool
    let target: String

    init(_ link: WindowLink, references: WireReferenceCodec = .processLocal) {
        self.ref = references.reference(to: link)
        self.sessionID = link.sessionID.rawValue
        self.windowID = link.windowID.rawValue
        self.index = link.index
        self.isActive = link.isActive
        self.target = link.target
    }
}

struct WindowOccurrenceResult: Sendable, Hashable, Codable {
    let windowRef: String
    let linkRef: String
    let id: String
    let name: String
    let paneCount: Int
    let width: Int
    let height: Int
    let sessionID: String
    let index: Int
    let isActive: Bool
    let target: String

    init(
        window: Window,
        link: WindowLink,
        references: WireReferenceCodec = .processLocal
    ) {
        self.windowRef = references.reference(to: window)
        self.linkRef = references.reference(to: link)
        self.id = window.id.rawValue
        self.name = window.name
        self.paneCount = window.paneCount
        self.width = window.width
        self.height = window.height
        self.sessionID = link.sessionID.rawValue
        self.index = link.index
        self.isActive = link.isActive
        self.target = link.target
    }

    static func projecting(_ windows: [Window], through links: [WindowLink])
        -> [WindowOccurrenceResult]
    {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return links.compactMap { link in
            byID[link.windowID].map { WindowOccurrenceResult(window: $0, link: link) }
        }
    }
}

struct PaneResult: Sendable, Hashable, Codable {
    let ref: String
    let id: String
    let index: Int
    let width: Int
    let height: Int
    let isActive: Bool
    let currentCommand: String
    let currentPath: String
    let isAtTop: Bool
    let isAtBottom: Bool
    let isAtLeft: Bool
    let isAtRight: Bool
    let windowID: String

    init(_ pane: Pane, references: WireReferenceCodec = .processLocal) {
        self.ref = references.reference(to: pane)
        self.id = pane.id.rawValue
        self.index = pane.index
        self.width = pane.width
        self.height = pane.height
        self.isActive = pane.isActive
        self.currentCommand = pane.currentCommand
        self.currentPath = pane.currentPath
        self.isAtTop = pane.isAtTop
        self.isAtBottom = pane.isAtBottom
        self.isAtLeft = pane.isAtLeft
        self.isAtRight = pane.isAtRight
        self.windowID = pane.windowID.rawValue
    }
}

struct ClientResult: Sendable, Hashable, Codable {
    let ref: String
    let name: String
    let tty: String
    let processID: Int
    let width: Int?
    let height: Int?
    let isControlMode: Bool
    let sessionID: String

    init(_ client: Client, references: WireReferenceCodec = .processLocal) {
        self.ref = references.reference(to: client)
        self.name = client.name
        self.tty = client.tty
        self.processID = client.processID
        self.width = client.width
        self.height = client.height
        self.isControlMode = client.isControlMode
        self.sessionID = client.sessionID.rawValue
    }
}

struct SnapshotResult: Sendable, Hashable, Codable {
    let sessions: [SessionResult]
    let windows: [WindowResult]
    let windowLinks: [WindowLinkResult]
    let panes: [PaneResult]
    let clients: [ClientResult]

    init(_ snapshot: Snapshot) {
        self.sessions = snapshot.sessions.map { SessionResult($0) }
        self.windows = snapshot.windows.map { WindowResult($0) }
        self.windowLinks = snapshot.windowLinks.map { WindowLinkResult($0) }
        self.panes = snapshot.panes.map { PaneResult($0) }
        self.clients = snapshot.clients.map { ClientResult($0) }
    }
}

struct CaptureResult: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    let lines: [String]
    /// How many older lines the cap dropped, so a truncated read says so
    /// rather than looking like a short pane.
    let droppedLines: Int
}

struct PaneMatch: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    /// One-based, counting from the top of the pane contents requested.
    let line: Int
    let text: String
}

struct SearchResult: Sendable, Hashable, Codable {
    let matches: [PaneMatch]
    let panesSearched: Int
    let panesAvailable: Int
    /// Whether a line, byte, or match limit left pane contents unsearched.
    let truncated: Bool
}

/// What a format evaluated to.
///
/// Wrapped rather than returned as bare text so the answer stays distinct from
/// the absence of a server-level value. A stale target reference is refused;
/// a field that is legitimately empty reports `""`.
struct FormatResult: Sendable, Hashable, Codable {
    let value: String?
}

struct OutputWaitResult: Sendable, Hashable, Codable {
    let paneRef: String
    let outcome: String
    let matched: String?
    let matchedIndex: Int?
    /// `false` with `outcome: "timedOut"` means the pane really was quiet —
    /// suspect the command never ran, because no change of pattern fixes it.
    /// With `outcome: "expiredWhileReading"` it means nothing: the reads that
    /// would have seen output never finished.
    let sawNewOutput: Bool
    /// The pattern was on screen before the wait started. Not a match — but it
    /// means the thing happened and you asked afterwards, which is the opposite
    /// problem from it never happening, and waiting longer fixes neither.
    let matchedAtEntry: Bool
    let tail: [String]
    let seconds: Double
    /// What the ceiling actually allowed, which may be less than was asked for.
    let effectiveTimeout: Double

    init(_ wait: OutputWait, pane: Pane, effectiveTimeout: Double) {
        self.paneRef = WireReferenceCodec.processLocal.reference(to: pane)
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

struct FormatWatchResult: Sendable, Hashable, Codable {
    let paneRef: String
    let linkRef: String
    let outcome: String
    /// The value the format took, or its current value on a timeout.
    let value: String?
    let seconds: Double
    let effectiveTimeout: Double
}

struct ChannelWaitResult: Sendable, Hashable, Codable {
    let channel: String
    /// `false` means the deadline came first. Whatever would have signalled the
    /// channel is still running; calling again resumes the wait.
    let released: Bool
    let seconds: Double
    let effectiveTimeout: Double
}

struct ChannelSignalResult: Sendable, Hashable, Codable {
    let channel: String
    let signalled: Bool
}

struct RunShellResult: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    /// The command's exit status, or `null` when the wait timed out before it
    /// finished.
    let exitStatus: Int?
    /// The command is still running in the pane when this is true — nothing was
    /// killed, so read the pane or call again.
    let timedOut: Bool
    /// The newest captured rows. When `linesMissed` is false, these contain
    /// only what this command printed rather than lines already on screen.
    let output: [String]
    /// The start marker fell outside the bounded capture or tmux history, so
    /// `output` is only the newest partial tail.
    let linesMissed: Bool
    /// Rows known to have been omitted from `output`. More can be missing when
    /// `linesMissed` is true.
    let droppedLines: Int
    let seconds: Double
    let effectiveTimeout: Double
}

struct SentKeys: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    let keys: [String]
}

struct Killed: Sendable, Hashable, Codable {
    let ref: String
    let kind: String
    let id: String
}

struct WorkspaceResult: Sendable, Hashable, Codable {
    let session: SessionResult
    let windows: [WindowOccurrenceResult]
    let panes: [PaneResult]
}

/// What tmux said, in a shape a client can read without knowing tmux's
/// conventions. A nonzero exit is reported, not thrown: a client asking whether
/// a session exists wants the answer, not an error.
struct CommandResult: Sendable, Hashable, Codable {
    let serverRef: String
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

struct StepResult: Sendable, Hashable, Codable {
    /// Its position in the batch, so a failure names the command that caused it.
    let step: Int
    let command: String
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

struct BatchResult: Sendable, Hashable, Codable {
    let serverRef: String
    let steps: [StepResult]
    let requested: Int
    /// Whether a failure stopped the batch before every command ran, as tmux
    /// itself does with a command list.
    let stoppedEarly: Bool
}

struct CaptureSinceResult: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    /// Only what arrived since the cursor. Empty means the pane has been quiet.
    let lines: [String]
    /// Hand this back on the next call. Opaque: what it holds is the server's
    /// business, and a caller that read the fields would depend on something
    /// free to change.
    let cursor: String
    /// The old mark no longer survives or the pane grid changed, so continuity
    /// cannot be proved. `lines` is empty and `cursor` is a fresh mark.
    let linesMissed: Bool
    /// The pane was respawned, so the cursor described a different program.
    let restarted: Bool
    /// Candidate rows omitted by the requested line or raw-text byte limit.
    let droppedLines: Int
}

struct Renamed: Sendable, Hashable, Codable {
    let ref: String
    let kind: String
    let id: String
    let name: String
}

struct Resized: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    let width: Int
    let height: Int
}

struct LaidOut: Sendable, Hashable, Codable {
    let windowRef: String
    let window: String
    let layout: String
}

struct Respawned: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
}

struct Pasted: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    let characters: Int
}

struct EnvironmentSet: Sendable, Hashable, Codable {
    let serverRef: String
    let name: String
    /// Absent when the variable was unset rather than given a value.
    let value: String?
}
