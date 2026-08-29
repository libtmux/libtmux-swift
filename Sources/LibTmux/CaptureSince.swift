import Foundation

private struct IncrementalPaneState {
    let bounds: PaneCaptureBounds
    let processID: String
    let absoluteCursorRow: Int
    let historyLimit: Int
    let paneWidth: Int
    let alternateScreen: Bool
}

/// What an output wait knows on entry: the rows a match scans, and the cursor
/// its forward scans continue from.
struct EntryCapture: Sendable {
    let rows: [String]
    let cursor: CaptureCursor
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
            perStreamOutputLimit: Self.captureOutputByteLimit
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
    /// At most `maximumChunks` are read; `hasMore` tells the caller to resume.
    /// Returning `true` from `visit` stops before the remaining rows are read.
    package func scanForward(
        _ pane: Pane,
        since cursor: CaptureCursor,
        sourceLinesPerChunk: Int,
        maximumChunks: Int,
        perStreamOutputLimit: Int,
        _ visit: ([String]) -> Bool
    ) async throws(TmuxError) -> ForwardCaptureResult {
        guard sourceLinesPerChunk > 1 else {
            throw .invocationFailed(reason: "a forward capture chunk needs at least two lines")
        }
        guard maximumChunks > 0 else {
            throw .invocationFailed(reason: "a forward capture needs at least one chunk")
        }
        guard perStreamOutputLimit > 0 else {
            throw .invocationFailed(reason: "a forward capture needs a positive output limit")
        }
        var previousCursor = cursor
        var remainingAttempts = Self.incrementalCaptureAttempts
        var completedChunks = 0
        while true {
            do {
                let state = try await incrementalPaneState(for: pane)
                guard previousCursor.pane == pane.id.rawValue,
                    previousCursor.incarnation == pane.incarnation,
                    previousCursor.processID == state.processID
                else {
                    let reset = try await markIncremental(
                        pane,
                        state: state,
                        perStreamOutputLimit: perStreamOutputLimit,
                        restarted: true
                    )
                    return ForwardCaptureResult(
                        cursor: reset.cursor,
                        linesMissed: reset.linesMissed,
                        restarted: reset.restarted,
                        droppedLines: reset.droppedLines,
                        hasMore: false
                    )
                }
                guard
                    let aligned = try await align(
                        previousCursor,
                        in: pane,
                        state: state,
                        perStreamOutputLimit: perStreamOutputLimit
                    )
                else {
                    let reset = try await markIncremental(
                        pane,
                        state: state,
                        perStreamOutputLimit: perStreamOutputLimit,
                        linesMissed: true
                    )
                    return ForwardCaptureResult(
                        cursor: reset.cursor,
                        linesMissed: true,
                        restarted: false,
                        droppedLines: 0,
                        hasMore: false
                    )
                }

                let start = aligned.anchor
                let (candidateEnd, endOverflowed) = start.addingReportingOverflow(
                    sourceLinesPerChunk - 1
                )
                let end =
                    endOverflowed
                    ? state.absoluteCursorRow
                    : min(candidateEnd, state.absoluteCursorRow)
                let rawRows = try await captureExactRows(
                    pane,
                    from: start,
                    through: end,
                    state: state,
                    perStreamOutputLimit: perStreamOutputLimit
                )
                var rows = rawRows
                let advanced = end > aligned.anchor
                // Keep a completed blank anchor, but not the empty row the cursor lands on.
                let completedBlankAnchor =
                    advanced && aligned.tail == nil && rows.first?.isEmpty == true
                if rows.first == (aligned.tail ?? "") { rows.removeFirst() }
                if completedBlankAnchor { rows.insert("", at: 0) }
                if advanced, rows.last?.isEmpty == true {
                    rows.removeLast()
                }
                let nextCursor = try makeCursor(
                    for: pane,
                    state: state,
                    anchor: end,
                    rawRows: rawRows,
                    fallback: aligned
                )
                previousCursor = nextCursor
                remainingAttempts = Self.incrementalCaptureAttempts
                completedChunks += 1
                let stopped = visit(rows)
                let hasMore = end != state.absoluteCursorRow
                let result = ForwardCaptureResult(
                    cursor: nextCursor,
                    linesMissed: false,
                    restarted: false,
                    droppedLines: 0,
                    hasMore: hasMore
                )
                if stopped || !hasMore || completedChunks == maximumChunks {
                    return result
                }
            } catch let error {
                remainingAttempts -= 1
                guard case .staleServerValue = error, remainingAttempts > 0 else {
                    throw error
                }
                guard !Task.isCancelled else { throw .cancelled }
                await Task.yield()
            }
        }
    }

    private func captureIncremental(
        _ pane: Pane,
        since cursor: CaptureCursor?,
        limit: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> IncrementalCapture {
        var remainingAttempts = Self.incrementalCaptureAttempts
        while true {
            do {
                return try await captureIncrementalAttempt(
                    pane,
                    since: cursor,
                    limit: limit,
                    perStreamOutputLimit: perStreamOutputLimit
                )
            } catch let error {
                remainingAttempts -= 1
                guard case .staleServerValue = error, remainingAttempts > 0 else {
                    throw error
                }
                guard !Task.isCancelled else { throw .cancelled }
                await Task.yield()
            }
        }
    }

    private func captureIncrementalAttempt(
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
            return try await markIncremental(
                pane,
                state: state,
                perStreamOutputLimit: perStreamOutputLimit,
                restarted: cursor != nil
            )
        }
        guard
            let cursor = try await align(
                cursor,
                in: pane,
                state: state,
                perStreamOutputLimit: perStreamOutputLimit
            )
        else {
            return try await markIncremental(
                pane,
                state: state,
                perStreamOutputLimit: perStreamOutputLimit,
                linesMissed: true
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
        guard start >= oldest, start <= cursorRow else {
            return try await markIncremental(
                pane,
                state: state,
                perStreamOutputLimit: perStreamOutputLimit,
                linesMissed: true
            )
        }
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
            startingAt: .line(start),
            endingAt: cursorRow,
            bounds: bounds,
            maximumLines: sourceLimit,
            perStreamOutputLimit: perStreamOutputLimit
        )
        let rawRows = bounded.lines
        var rows = rawRows
        let sourceDropped = bounded.droppedLines
        if sourceDropped == 0, let tail = cursor.tail, rows.first == tail {
            rows.removeFirst()
        }
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
            cursor: try makeCursor(
                for: pane,
                state: state,
                anchor: now,
                rawRows: rawRows,
                fallback: cursor
            ),
            linesMissed: false,
            droppedLines: droppedLines
        )
    }

    private func incrementalPaneState(
        for pane: Pane
    ) async throws(TmuxError) -> IncrementalPaneState {
        let separator = String(FormatProjection.separator)
        let state = try await formatGlobal(
            "#{history_size}\(separator)#{cursor_y}\(separator)#{pane_pid}"
                + "\(separator)#{pane_height}\(separator)#{history_bytes}"
                + "\(separator)#{history_limit}\(separator)#{pane_width}"
                + "\(separator)#{alternate_on}",
            for: pane
        )
        guard let state else { throw .staleServerValue }
        let fields = state.components(separatedBy: separator)
        guard fields.count >= 8,
            let history = Int(fields[0]), history >= 0,
            let cursorRow = Int(fields[1]), cursorRow >= 0,
            let paneHeight = Int(fields[3]), paneHeight > 0,
            let historyBytes = Int(fields[4]), historyBytes >= 0,
            let historyLimit = Int(fields[5]), historyLimit >= 0,
            let paneWidth = Int(fields[6]), paneWidth > 0,
            fields[7] == "0" || fields[7] == "1",
            cursorRow < paneHeight
        else {
            throw .invocationFailed(reason: "tmux returned invalid incremental pane state")
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
            absoluteCursorRow: absoluteCursorRow,
            historyLimit: historyLimit,
            paneWidth: paneWidth,
            alternateScreen: fields[7] == "1"
        )
    }

    /// Answers both entry questions in one state read and one capture.
    ///
    /// A wait needs the rows a match scans and the cursor its later scans
    /// continue from. Read separately those cost two state reads and two
    /// captures of overlapping rows, and the pane can move between them. One
    /// read keeps them consistent and halves the round-trips a wait pays before
    /// it can answer "that is already on screen".
    func captureEntry(
        _ pane: Pane,
        historyLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> EntryCapture {
        guard historyLines >= 0 else {
            throw .invocationFailed(reason: "pane capture lookback cannot be negative")
        }
        let state = try await incrementalPaneState(for: pane)
        let bounds = state.bounds
        // The cursor's checkpoint is taken from the end of these same rows, so
        // the window never narrows below what one needs, however little
        // lookback a caller asks for.
        let lookback = max(historyLines, CaptureCursor.maximumCheckpointRows)
        let start = max(-lookback, -bounds.historySize)
        let (span, spanOverflowed) = bounds.cursorRow.subtractingReportingOverflow(start)
        let (requested, countOverflowed) = span.addingReportingOverflow(1)
        guard !spanOverflowed, !countOverflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        let capture = try await captureTail(
            pane,
            startingAt: .line(start),
            endingAt: bounds.cursorRow,
            bounds: bounds,
            maximumLines: requested,
            perStreamOutputLimit: perStreamOutputLimit
        )
        var rows = capture.lines
        if requested == 1, rows.isEmpty { rows = [""] }
        // The cursor is anchored on the last row read. A short capture would
        // anchor it above the real cursor, and every later scan would re-read
        // or skip rows from there on.
        guard capture.droppedLines == 0, rows.count == requested else {
            throw .invocationFailed(reason: "tmux returned an incomplete pane capture")
        }
        return EntryCapture(
            rows: rows,
            cursor: try makeCursor(
                for: pane,
                state: state,
                anchor: state.absoluteCursorRow,
                rawRows: Array(rows.suffix(CaptureCursor.maximumCheckpointRows + 1)),
                fallback: nil
            )
        )
    }

    private func markIncremental(
        _ pane: Pane,
        state: IncrementalPaneState,
        perStreamOutputLimit: Int,
        linesMissed: Bool = false,
        restarted: Bool = false
    ) async throws(TmuxError) -> IncrementalCapture {
        let first = max(
            0,
            state.absoluteCursorRow - CaptureCursor.maximumCheckpointRows
        )
        let rows = try await captureExactRows(
            pane,
            from: first,
            through: state.absoluteCursorRow,
            state: state,
            perStreamOutputLimit: perStreamOutputLimit
        )
        return IncrementalCapture(
            lines: [],
            cursor: try makeCursor(
                for: pane,
                state: state,
                anchor: state.absoluteCursorRow,
                rawRows: rows,
                fallback: nil
            ),
            linesMissed: linesMissed,
            restarted: restarted
        )
    }

    private func align(
        _ cursor: CaptureCursor,
        in pane: Pane,
        state: IncrementalPaneState,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> CaptureCursor? {
        guard cursor.historyLimit == state.historyLimit,
            cursor.paneWidth == state.paneWidth,
            cursor.paneHeight == state.bounds.paneHeight,
            cursor.alternateScreen == state.alternateScreen
        else { return nil }

        let collectionRows = max(1, state.historyLimit / 10)
        let firstPostCollectionSize = max(
            0,
            state.historyLimit - collectionRows + 1
        )
        let nearCollection =
            state.historyLimit == 0
            || cursor.historySize >= firstPostCollectionSize
            || state.bounds.historySize >= firstPostCollectionSize
        guard
            state.bounds.historySize < cursor.historySize
                || state.absoluteCursorRow < cursor.anchor
                || nearCollection
        else { return cursor }
        guard let checkpointAnchor = cursor.checkpointAnchor,
            !cursor.checkpoint.isEmpty
        else { return nil }
        guard
            let relocatedCheckpoint = try await findCheckpoint(
                for: cursor,
                collectionRows: collectionRows,
                in: pane,
                state: state,
                perStreamOutputLimit: perStreamOutputLimit
            )
        else { return nil }
        let (delta, deltaOverflowed) = relocatedCheckpoint.subtractingReportingOverflow(
            checkpointAnchor
        )
        let (anchor, anchorOverflowed) = cursor.anchor.addingReportingOverflow(delta)
        guard !deltaOverflowed, !anchorOverflowed,
            anchor >= 0, anchor <= state.absoluteCursorRow
        else { return nil }
        return updatedCursor(
            cursor,
            state: state,
            anchor: anchor,
            checkpointAnchor: relocatedCheckpoint
        )
    }

    private func updatedCursor(
        _ cursor: CaptureCursor,
        state: IncrementalPaneState,
        anchor: Int,
        checkpointAnchor: Int
    ) -> CaptureCursor {
        CaptureCursor(
            pane: cursor.pane,
            incarnation: cursor.incarnation,
            anchor: anchor,
            tail: cursor.tail,
            processID: cursor.processID,
            historySize: state.bounds.historySize,
            historyLimit: state.historyLimit,
            paneWidth: state.paneWidth,
            paneHeight: state.bounds.paneHeight,
            alternateScreen: state.alternateScreen,
            checkpoint: cursor.checkpoint,
            checkpointAnchor: checkpointAnchor
        )
    }

    private func findCheckpoint(
        for cursor: CaptureCursor,
        collectionRows: Int,
        in pane: Pane,
        state: IncrementalPaneState,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> Int? {
        let (rowBytes, widthOverflowed) = state.paneWidth.multipliedReportingOverflow(by: 4)
        guard !widthOverflowed else { return nil }
        let budgetedRows = perStreamOutputLimit / max(1, rowBytes + 1)
        guard budgetedRows >= cursor.checkpoint.count,
            let checkpointAnchor = cursor.checkpointAnchor
        else { return nil }
        let firstPossibleAnchor = cursor.checkpoint.count - 1
        let maximumCollections = (checkpointAnchor - firstPossibleAnchor) / collectionRows
        let historyRegression = max(0, cursor.historySize - state.bounds.historySize)
        let anchorRegression = max(0, cursor.anchor - state.absoluteCursorRow)
        let requiredShift = max(historyRegression, anchorRegression)
        let minimumCollections =
            requiredShift / collectionRows
            + (requiredShift.isMultiple(of: collectionRows) ? 0 : 1)
        guard minimumCollections <= maximumCollections,
            maximumCollections - minimumCollections < Self.maximumCheckpointCandidates
        else { return nil }

        var match: Int?
        for collections in minimumCollections...maximumCollections {
            let candidate = checkpointAnchor - collections * collectionRows
            let start = candidate - cursor.checkpoint.count + 1
            let rows = try await captureExactRows(
                pane,
                from: start,
                through: candidate,
                state: state,
                perStreamOutputLimit: perStreamOutputLimit
            )
            guard rows == cursor.checkpoint else { continue }
            if match != nil { return nil }
            match = candidate
        }
        return match
    }

    private func captureExactRows(
        _ pane: Pane,
        from first: Int,
        through last: Int,
        state: IncrementalPaneState,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> [String] {
        guard first >= 0, last >= first, last <= state.absoluteCursorRow else {
            throw .invocationFailed(reason: "pane reported an invalid capture range")
        }
        let (relativeFirst, firstOverflowed) = first.subtractingReportingOverflow(
            state.bounds.historySize
        )
        let (relativeLast, lastOverflowed) = last.subtractingReportingOverflow(
            state.bounds.historySize
        )
        let (span, spanOverflowed) = last.subtractingReportingOverflow(first)
        let (count, countOverflowed) = span.addingReportingOverflow(1)
        guard !firstOverflowed, !lastOverflowed, !spanOverflowed, !countOverflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        let capture = try await captureTail(
            pane,
            startingAt: .line(relativeFirst),
            endingAt: relativeLast,
            bounds: state.bounds,
            maximumLines: count,
            perStreamOutputLimit: perStreamOutputLimit
        )
        var rows = capture.lines
        if count == 1, rows.isEmpty { rows = [""] }
        guard capture.droppedLines == 0, rows.count == count else {
            throw .invocationFailed(reason: "tmux returned an incomplete pane capture")
        }
        return rows
    }

    private func makeCursor(
        for pane: Pane,
        state: IncrementalPaneState,
        anchor: Int,
        rawRows: [String],
        fallback: CaptureCursor?
    ) throws(TmuxError) -> CaptureCursor {
        let priorRows = rawRows.dropLast()
        let trailingEmptyRows = priorRows.reversed().prefix(while: \.isEmpty).count
        let checkpointEnd = priorRows.count - trailingEmptyRows
        let checkpoint: [String]
        let checkpointAnchor: Int?
        if checkpointEnd > 0 {
            checkpoint = Array(
                priorRows[..<checkpointEnd].suffix(CaptureCursor.maximumCheckpointRows)
            )
            let (distance, distanceOverflowed) = trailingEmptyRows.addingReportingOverflow(1)
            let (candidate, anchorOverflowed) = anchor.subtractingReportingOverflow(
                distance
            )
            guard !distanceOverflowed, !anchorOverflowed,
                candidate >= checkpoint.count - 1
            else {
                throw .invocationFailed(reason: "pane reported an invalid cursor checkpoint")
            }
            checkpointAnchor = candidate
        } else {
            checkpoint = fallback?.checkpoint ?? []
            checkpointAnchor = fallback?.checkpointAnchor
        }
        return CaptureCursor(
            pane: pane.id.rawValue,
            incarnation: pane.incarnation,
            anchor: anchor,
            tail: rawRows.last.flatMap { $0.isEmpty ? nil : $0 },
            processID: state.processID,
            historySize: state.bounds.historySize,
            historyLimit: state.historyLimit,
            paneWidth: state.paneWidth,
            paneHeight: state.bounds.paneHeight,
            alternateScreen: state.alternateScreen,
            checkpoint: checkpoint,
            checkpointAnchor: checkpointAnchor
        )
    }

    private static let incrementalCaptureAttempts = 3
    private static let maximumCheckpointCandidates = 128
}
