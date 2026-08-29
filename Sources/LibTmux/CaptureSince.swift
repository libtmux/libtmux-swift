import Foundation

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
    /// The absolute row the last read ended on, counted from the start of the
    /// pane's history rather than from the top of the screen. Screen-relative
    /// numbers move as content scrolls; this one does not.
    let anchor: Int
    /// What that row said. A row can be rewritten in place — a spinner, a
    /// progress bar, a prompt being redrawn — so position alone cannot tell a
    /// row already reported from the same row saying something new.
    let tail: String?
    /// The process in the pane. A respawn keeps the pane id and replaces
    /// everything the cursor described, so this is what makes that detectable
    /// rather than silently reporting one program's output as another's.
    let processID: String?

    private enum CodingKeys: String, CodingKey {
        case pane, incarnation, anchor, tail, processID
    }

    init(
        pane: String,
        incarnation: ServerIncarnation,
        anchor: Int,
        tail: String?,
        processID: String?
    ) {
        self.pane = pane
        self.incarnation = incarnation
        self.anchor = anchor
        self.tail = tail
        self.processID = processID
    }
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
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pane, forKey: .pane)
        try container.encode(incarnation, forKey: .incarnation)
        try container.encode(anchor, forKey: .anchor)
        try container.encodeIfPresent(tail, forKey: .tail)
        try container.encodeIfPresent(processID, forKey: .processID)
    }
}

/// What a pane has said since a cursor was taken.
public struct IncrementalCapture: Sendable, Hashable, Codable {
    /// Only what is new. Empty when nothing has happened, which is the point:
    /// watching a quiet pane costs one command and no content.
    public let lines: [String]
    /// Hand this to the next call.
    public let cursor: CaptureCursor
    /// The pane scrolled further than its history keeps, so some output is
    /// gone for good. What is here is still correct, just not complete.
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
}

private struct IncrementalPaneState {
    let bounds: PaneCaptureBounds
    let processID: String
    let absoluteCursorRow: Int
}

extension Server {
    /// Reads only what a pane has printed since `cursor`.
    ///
    /// Watching a pane by capturing it repeatedly sends the whole screen every
    /// time, nearly all of which the caller has already seen — which for an
    /// agent is context spent on nothing. This sends the difference.
    ///
    /// Pass `nil` to start: the first read establishes where the pane is
    /// without returning its backlog, so a watcher begins at "from now on"
    /// rather than with a screenful of history.
    /// The source read is capped at 1 MiB; a wider result fails instead of
    /// allocating output the line limit would later discard.
    ///
    /// - Parameters:
    ///   - pane: the pane to read.
    ///   - cursor: where the last read stopped, or `nil` to start watching.
    ///   - limit: the most lines to return, keeping the newest.
    public func capture(
        _ pane: Pane,
        since cursor: CaptureCursor?,
        limit: Int = 500
    ) async throws(TmuxError) -> IncrementalCapture {
        try await captureIncremental(
            pane,
            since: cursor,
            limit: limit,
            perStreamOutputLimit: Self.incrementalCaptureOutputLimit
        )
    }

    package func captureBounded(
        _ pane: Pane,
        since cursor: CaptureCursor?,
        maximumLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> IncrementalCapture {
        guard maximumLines > 0 else {
            throw .invocationFailed(reason: "a bounded capture needs at least one line")
        }
        return try await captureIncremental(
            pane,
            since: cursor,
            limit: maximumLines,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }

    /// Visits unseen rows oldest-first without retaining completed chunks.
    /// Returning `true` from `visit` stops before the remaining rows are read.
    package func scanForward(
        _ pane: Pane,
        since cursor: CaptureCursor,
        sourceLinesPerChunk: Int,
        perStreamOutputLimit: Int,
        _ visit: ([String]) -> Bool
    ) async throws(TmuxError) -> ForwardCaptureResult {
        guard sourceLinesPerChunk > 1 else {
            throw .invocationFailed(reason: "a forward capture chunk needs at least two lines")
        }
        guard perStreamOutputLimit > 0 else {
            throw .invocationFailed(reason: "a forward capture needs a positive output limit")
        }
        let state = try await incrementalPaneState(for: pane)
        guard cursor.pane == pane.id.rawValue,
            cursor.incarnation == pane.incarnation,
            cursor.processID == state.processID
        else {
            let reset = try await captureIncremental(
                pane,
                since: cursor,
                limit: 0,
                perStreamOutputLimit: perStreamOutputLimit
            )
            return ForwardCaptureResult(
                cursor: reset.cursor,
                linesMissed: reset.linesMissed,
                restarted: reset.restarted,
                droppedLines: reset.droppedLines
            )
        }

        let (relativeStart, startOverflowed) = cursor.anchor.subtractingReportingOverflow(
            state.bounds.historySize
        )
        guard !startOverflowed else {
            throw .invocationFailed(reason: "pane reported an invalid history size")
        }
        let oldest = -state.bounds.historySize
        let linesMissed = relativeStart < oldest
        let firstRelativeRow = max(relativeStart, oldest)
        let (firstAbsoluteRow, firstOverflowed) = state.bounds.historySize
            .addingReportingOverflow(firstRelativeRow)
        guard !firstOverflowed, firstAbsoluteRow <= state.absoluteCursorRow else {
            throw .invocationFailed(reason: "pane reported an invalid cursor")
        }

        var start = firstAbsoluteRow
        var tail = cursor.tail
        var droppedLines = 0
        while true {
            let (candidateEnd, endOverflowed) = start.addingReportingOverflow(
                sourceLinesPerChunk - 1
            )
            let end =
                endOverflowed
                ? state.absoluteCursorRow
                : min(
                    candidateEnd,
                    state.absoluteCursorRow
                )
            let capture = try await captureTail(
                pane,
                fromAbsoluteRow: start,
                throughAbsoluteRow: end,
                maximumLines: sourceLinesPerChunk,
                perStreamOutputLimit: perStreamOutputLimit
            )
            let (nextDroppedLines, droppedOverflowed) = droppedLines.addingReportingOverflow(
                capture.droppedLines
            )
            guard !droppedOverflowed else {
                throw .invocationFailed(reason: "pane capture size overflowed")
            }
            droppedLines = nextDroppedLines

            var rows = capture.lines
            if let tail, rows.first == tail { rows.removeFirst() }
            if end == state.absoluteCursorRow {
                while rows.last?.isEmpty == true { rows.removeLast() }
            }
            tail = rows.last ?? tail
            let result = ForwardCaptureResult(
                cursor: CaptureCursor(
                    pane: pane.id.rawValue,
                    incarnation: pane.incarnation,
                    anchor: end,
                    tail: tail,
                    processID: state.processID
                ),
                linesMissed: linesMissed,
                restarted: false,
                droppedLines: droppedLines
            )
            if visit(rows) || end == state.absoluteCursorRow { return result }
            start = end
        }
    }

    private func captureIncremental(
        _ pane: Pane,
        since cursor: CaptureCursor?,
        limit: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> IncrementalCapture {
        guard limit >= 0 else {
            throw .invocationFailed(reason: "an incremental capture limit cannot be negative")
        }
        let state = try await incrementalPaneState(for: pane)
        let bounds = state.bounds
        let history = bounds.historySize
        let cursorRow = bounds.cursorRow
        let processID = state.processID
        let now = state.absoluteCursorRow

        guard let cursor, cursor.pane == pane.id.rawValue,
            cursor.incarnation == pane.incarnation, cursor.processID == processID
        else {
            // Nothing to compare against, so this establishes the mark rather
            // than answering with a backlog nobody asked for.
            let restarted = cursor != nil
            let tail = try await captureTail(
                pane,
                startingAt: .line(cursorRow),
                endingAt: cursorRow,
                bounds: bounds,
                maximumLines: 1,
                perStreamOutputLimit: perStreamOutputLimit
            ).lines.first
            return IncrementalCapture(
                lines: [],
                cursor: CaptureCursor(
                    pane: pane.id.rawValue,
                    incarnation: pane.incarnation,
                    anchor: now,
                    tail: tail,
                    processID: processID
                ),
                restarted: restarted
            )
        }

        // Reading from the anchor row itself, because it may have been
        // rewritten since — `tail` is what tells the two apart.
        let (start, anchorOverflowed) = cursor.anchor.subtractingReportingOverflow(history)
        guard !anchorOverflowed else {
            throw TmuxError.invocationFailed(
                reason: "pane \(pane.id.rawValue) reported an invalid history size"
            )
        }
        let oldest = -history
        let linesMissed = start < oldest
        let earliest = max(start, oldest)
        let sourceLimit: Int
        if limit == .max {
            sourceLimit = .max
        } else {
            let (incremented, overflowed) = limit.addingReportingOverflow(1)
            guard !overflowed else {
                throw TmuxError.invocationFailed(reason: "pane capture size overflowed")
            }
            sourceLimit = incremented
        }
        let bounded = try await captureTail(
            pane,
            startingAt: .line(earliest),
            endingAt: cursorRow,
            bounds: bounds,
            maximumLines: sourceLimit,
            perStreamOutputLimit: perStreamOutputLimit
        )
        var rows = bounded.lines
        let sourceDropped = bounded.droppedLines
        if let tail = cursor.tail, rows.first == tail { rows.removeFirst() }
        // tmux pads the visible region with blank rows below the cursor; they
        // are not output and reporting them would be reporting the shape of the
        // terminal rather than what ran in it.
        while let last = rows.last, last.isEmpty { rows.removeLast() }

        let kept = rows.suffix(max(0, limit))
        let (droppedLines, droppedOverflowed) = sourceDropped.addingReportingOverflow(
            rows.count - kept.count
        )
        guard !droppedOverflowed else {
            throw TmuxError.invocationFailed(reason: "pane capture size overflowed")
        }
        return IncrementalCapture(
            lines: Array(kept),
            cursor: CaptureCursor(
                pane: pane.id.rawValue,
                incarnation: pane.incarnation,
                anchor: now,
                tail: rows.last ?? cursor.tail,
                processID: processID
            ),
            linesMissed: linesMissed,
            droppedLines: droppedLines
        )
    }

    private func incrementalPaneState(
        for pane: Pane
    ) async throws(TmuxError) -> IncrementalPaneState {
        let separator = String(FormatProjection.separator)
        let state = try await formatGlobal(
            "#{history_size}\(separator)#{cursor_y}\(separator)#{pane_pid}"
                + "\(separator)#{pane_height}\(separator)#{history_bytes}",
            for: pane
        )
        guard let fields = state?.components(separatedBy: separator), fields.count >= 5,
            let history = Int(fields[0]), history >= 0,
            let cursorRow = Int(fields[1]), cursorRow >= 0,
            let paneHeight = Int(fields[3]), paneHeight > 0,
            let historyBytes = Int(fields[4]), historyBytes >= 0,
            cursorRow < paneHeight
        else {
            throw .invocationFailed(reason: "pane \(pane.id.rawValue) has gone")
        }
        let (absoluteCursorRow, overflowed) = history.addingReportingOverflow(cursorRow)
        guard !overflowed else {
            throw .invocationFailed(reason: "pane reported an invalid cursor")
        }
        return IncrementalPaneState(
            bounds: PaneCaptureBounds(
                historySize: history,
                historyBytes: historyBytes,
                paneHeight: paneHeight,
                cursorRow: cursorRow
            ),
            processID: fields[2],
            absoluteCursorRow: absoluteCursorRow
        )
    }

    private static let incrementalCaptureOutputLimit = 1_048_576
}
