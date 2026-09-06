import Foundation
import LibTmux

// What the tools answer with. Every one is a plain `Codable` struct, so the
// same value reaches a client as `structuredContent` and as JSON text without
// being written twice.

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
    /// Exact work or result ceilings that omitted otherwise eligible rows.
    let truncatedBy: [String]
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
    let cursor: String?
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let cursor = wait.cursor,
            let data = try? encoder.encode(cursor)
        {
            self.cursor = String(decoding: data, as: UTF8.self)
        } else {
            self.cursor = nil
        }
        self.seconds = wait.seconds
        self.effectiveTimeout = effectiveTimeout
    }
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
    let resolvedPaneIds: [String]
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

struct Respawned: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
}

struct Pasted: Sendable, Hashable, Codable {
    let paneRef: String
    let pane: String
    let characters: Int
}
