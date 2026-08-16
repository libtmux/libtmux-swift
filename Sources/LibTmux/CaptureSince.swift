import Foundation

/// Where a previous read of a pane stopped.
///
/// Opaque on purpose: what it holds is this implementation's business, and a
/// caller that reasons about the fields would be relying on something free to
/// change. Hand it back to ``Server/capture(_:since:limit:)`` to be told only what
/// has arrived since.
public struct CaptureCursor: Sendable, Hashable, Codable {
    let pane: String
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

    public init(
        lines: [String],
        cursor: CaptureCursor,
        linesMissed: Bool = false,
        restarted: Bool = false
    ) {
        self.lines = lines
        self.cursor = cursor
        self.linesMissed = linesMissed
        self.restarted = restarted
    }
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
        // The same printable separator the projections use: tmux strips the
        // actual control characters out of a format's output, so a real record
        // separator would arrive having silently joined the fields together.
        let separator = String(FormatProjection.separator)
        let state = try await format(
            "#{history_size}\(separator)#{cursor_y}\(separator)#{pane_pid}",
            for: pane
        )
        guard let fields = state?.components(separatedBy: separator), fields.count >= 3,
            let history = Int(fields[0]), let cursorRow = Int(fields[1])
        else {
            throw TmuxError.invocationFailed(reason: "pane \(pane.id) has gone")
        }
        let processID = fields[2]
        // The row the cursor is on, counted from the start of history.
        let now = history + cursorRow

        guard let cursor, cursor.pane == pane.id, cursor.processID == processID else {
            // Nothing to compare against, so this establishes the mark rather
            // than answering with a backlog nobody asked for.
            let restarted = cursor != nil
            return IncrementalCapture(
                lines: [],
                cursor: CaptureCursor(
                    pane: pane.id,
                    anchor: now,
                    tail: try await lastRow(of: pane),
                    processID: processID
                ),
                restarted: restarted
            )
        }

        // Reading from the anchor row itself, because it may have been
        // rewritten since — `tail` is what tells the two apart.
        let start = cursor.anchor - history
        let oldest = -history
        let linesMissed = start < oldest
        var rows = try await capture(pane, startingAt: .line(max(start, oldest)))
        if let tail = cursor.tail, rows.first == tail { rows.removeFirst() }
        // tmux pads the visible region with blank rows below the cursor; they
        // are not output and reporting them would be reporting the shape of the
        // terminal rather than what ran in it.
        while let last = rows.last, last.isEmpty { rows.removeLast() }

        return IncrementalCapture(
            lines: Array(rows.suffix(max(0, limit))),
            cursor: CaptureCursor(
                pane: pane.id,
                anchor: now,
                tail: rows.last ?? cursor.tail,
                processID: processID
            ),
            linesMissed: linesMissed
        )
    }

    private func lastRow(of pane: Pane) async throws(TmuxError) -> String? {
        var rows = try await capture(pane, startingAt: nil)
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows.last
    }
}
