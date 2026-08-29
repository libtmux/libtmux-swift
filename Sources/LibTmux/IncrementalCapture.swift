/// Where a previous read of a pane stopped.
///
/// Opaque on purpose: what it holds is this implementation's business, and a
/// caller that reasons about the fields would be relying on something free to
/// change. Hand it back to ``Server/capture(_:since:limit:)`` to be told only what
/// has arrived since.
public struct CaptureCursor: Sendable, Hashable, Codable {
    let pane: String
    /// The daemon whose pane history the cursor counted.
    let incarnation: ServerIncarnation
    /// The grid row where the last read ended, realigned through `checkpoint`
    /// when tmux discards old history and moves the grid's origin.
    let anchor: Int
    /// What that row said. A row can be rewritten in place — a spinner, a
    /// progress bar, a prompt being redrawn — so position alone cannot tell a
    /// row already reported from the same row saying something new.
    let tail: String?
    /// The process in the pane. A respawn keeps the pane id and replaces
    /// everything the cursor described, so this is what makes that detectable
    /// rather than silently reporting one program's output as another's.
    let processID: String?
    let historySize: Int
    let historyLimit: Int
    let paneWidth: Int
    let paneHeight: Int
    let alternateScreen: Bool
    let checkpoint: [String]
    let checkpointAnchor: Int?

    private enum CodingKeys: String, CodingKey {
        case pane, incarnation, anchor, tail, processID, historySize, historyLimit
        case paneWidth, paneHeight, alternateScreen, checkpoint, checkpointAnchor
    }

    init(
        pane: String,
        incarnation: ServerIncarnation,
        anchor: Int,
        tail: String?,
        processID: String?,
        historySize: Int,
        historyLimit: Int,
        paneWidth: Int,
        paneHeight: Int,
        alternateScreen: Bool,
        checkpoint: [String],
        checkpointAnchor: Int?
    ) {
        self.pane = pane
        self.incarnation = incarnation
        self.anchor = anchor
        self.tail = tail
        self.processID = processID
        self.historySize = historySize
        self.historyLimit = historyLimit
        self.paneWidth = paneWidth
        self.paneHeight = paneHeight
        self.alternateScreen = alternateScreen
        self.checkpoint = checkpoint
        self.checkpointAnchor = checkpointAnchor
    }

    static let maximumCheckpointRows = 3
}

extension CaptureCursor {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pane = try container.decode(String.self, forKey: .pane)
        incarnation = try container.decode(ServerIncarnation.self, forKey: .incarnation)
        anchor = try container.decode(Int.self, forKey: .anchor)
        guard anchor >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .anchor,
                in: container,
                debugDescription: "a capture cursor anchor cannot be negative"
            )
        }
        tail = try container.decodeIfPresent(String.self, forKey: .tail)
        processID = try container.decodeIfPresent(String.self, forKey: .processID)
        historySize = try container.decode(Int.self, forKey: .historySize)
        historyLimit = try container.decode(Int.self, forKey: .historyLimit)
        paneWidth = try container.decode(Int.self, forKey: .paneWidth)
        paneHeight = try container.decode(Int.self, forKey: .paneHeight)
        alternateScreen = try container.decode(Bool.self, forKey: .alternateScreen)
        checkpoint = try container.decode([String].self, forKey: .checkpoint)
        checkpointAnchor = try container.decodeIfPresent(Int.self, forKey: .checkpointAnchor)
        guard historySize >= 0, historyLimit >= 0, paneWidth > 0, paneHeight > 0,
            checkpoint.count <= Self.maximumCheckpointRows,
            checkpoint.isEmpty == (checkpointAnchor == nil),
            checkpointAnchor.map({ $0 >= checkpoint.count - 1 && $0 < anchor }) ?? true
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .checkpoint,
                in: container,
                debugDescription: "a capture cursor contains invalid pane coordinates"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pane, forKey: .pane)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(anchor, forKey: .anchor)
        try container.encodeIfPresent(tail, forKey: .tail)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encode(historySize, forKey: .historySize)
        try container.encode(historyLimit, forKey: .historyLimit)
        try container.encode(paneWidth, forKey: .paneWidth)
        try container.encode(paneHeight, forKey: .paneHeight)
        try container.encode(alternateScreen, forKey: .alternateScreen)
        try container.encode(checkpoint, forKey: .checkpoint)
        try container.encodeIfPresent(checkpointAnchor, forKey: .checkpointAnchor)
    }
}

/// What a pane has said since a cursor was taken.
public struct IncrementalCapture: Sendable, Hashable, Codable {
    /// Only what is new. Empty when nothing has happened, which is the point:
    /// watching a quiet pane costs one call and no content.
    public let lines: [String]
    /// Hand this to the next call.
    public let cursor: CaptureCursor
    /// The old mark no longer survives or the grid changed, so continuity
    /// cannot be proved. In that case ``lines`` is empty and the cursor resets.
    public let linesMissed: Bool
    /// The pane was respawned, so the cursor described a program that is no
    /// longer running and everything here is from the new one.
    public let restarted: Bool
    /// The number of older rows omitted to keep ``lines`` within `limit`.
    public let droppedLines: Int

    public init(
        lines: [String],
        cursor: CaptureCursor,
        linesMissed: Bool = false,
        restarted: Bool = false,
        droppedLines: Int = 0
    ) {
        self.lines = lines
        self.cursor = cursor
        self.linesMissed = linesMissed
        self.restarted = restarted
        self.droppedLines = droppedLines
    }
}

package struct ForwardCaptureResult: Sendable, Hashable {
    package let cursor: CaptureCursor
    package let linesMissed: Bool
    package let restarted: Bool
    package let droppedLines: Int
    package let hasMore: Bool
    /// The rows came from the grid a full-screen program paints, which tmux
    /// keeps out of history, so they were not printed by the pane.
    package let alternateScreen: Bool
}
