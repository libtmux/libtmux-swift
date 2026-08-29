import Foundation

/// A bounded read of a pane.
public struct PaneCapture: Sendable, Hashable {
    /// The newest rows, in terminal order.
    public let lines: [String]
    /// Older rows omitted to honor the requested limit.
    public let droppedLines: Int

    public init(lines: [String], droppedLines: Int = 0) {
        self.lines = lines
        self.droppedLines = droppedLines
    }
}

struct PaneCaptureBounds: Sendable, Hashable {
    let historySize: Int
    let historyBytes: Int
    let paneHeight: Int
    let cursorRow: Int
}

extension Server {
    static let captureOutputByteLimit = defaultTmuxReplyByteLimit

    // MARK: Talking to a pane

    /// Sends keys to a pane.
    ///
    /// - Parameters:
    ///   - keys: what to send, one argument per key or literal string.
    ///   - pane: the pane to send them to.
    ///   - literally: sends the text as characters rather than letting tmux
    ///     read names like `Enter` or `C-c` out of it. Use it for anything
    ///     that came from a user.
    public func sendKeys(
        _ keys: [String],
        to pane: Pane,
        literally: Bool = false
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id.rawValue]
        if literally { arguments.append("-l") }
        try await expectSuccess(
            TmuxCommand("send-keys", arguments + keys),
            guardedBy: [.pane(pane)]
        )
    }

    /// Runs a shell command line in a pane, as if typed.
    public func run(
        _ commandLine: String,
        in pane: Pane
    ) async throws(TmuxError) {
        try await sendKeys([commandLine, "Enter"], to: pane)
    }

    /// How a command running *inside* a pane spells a tmux that reaches this
    /// server.
    ///
    /// A bare `tmux` there is whichever one is on the pane's `PATH`, which is
    /// not necessarily this one — and a client whose protocol version differs
    /// from the server's is refused with `server exited unexpectedly` rather
    /// than anything that names the cause. Composing a command with this
    /// instead removes both the `PATH` lookup and the guess about which server
    /// `$TMUX` refers to:
    ///
    /// ```swift
    /// try await server.run(
    ///     "make; \(server.shellInvocation) wait-for -S built",
    ///     in: pane
    /// )
    /// try await server.wait(for: "built")
    /// ```
    ///
    /// Quoted for a POSIX shell, so a path containing spaces survives being
    /// typed into one.
    public var shellInvocation: String {
        ([tmuxExecutablePath] + endpoint.addressArguments)
            .map(shellQuoted)
            .joined(separator: " ")
    }

    /// The pane's visible contents, one line per row.
    /// The source read is capped at 1 MiB; use incremental capture for a large
    /// scrollback instead of collecting its entire history.
    ///
    /// - Parameters:
    ///   - pane: the pane to read.
    ///   - includingHistory: reads the scrollback too, from its start.
    public func capture(
        _ pane: Pane,
        includingHistory: Bool = false
    ) async throws(TmuxError) -> [String] {
        try await capture(pane, startingAt: includingHistory ? .start : nil)
    }

    /// Reads the newest rows without collecting older rows that will be discarded.
    public func capture(
        _ pane: Pane,
        includingHistory: Bool = false,
        maximumLines: Int
    ) async throws(TmuxError) -> PaneCapture {
        try await captureTail(
            pane,
            includingHistory: includingHistory,
            maximumLines: maximumLines,
            perStreamOutputLimit: Self.captureOutputByteLimit
        )
    }

    /// Reads the newest slice without collecting the rows it will discard.
    package func captureTail(
        _ pane: Pane,
        includingHistory: Bool,
        maximumLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> PaneCapture {
        let bounds = try await captureBounds(for: pane)
        return try await captureTail(
            pane,
            startingAt: includingHistory ? .start : nil,
            endingAt: nil,
            bounds: bounds,
            maximumLines: maximumLines,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }

    /// Reads the newest history through the cursor, excluding screen padding below it.
    package func captureTailThroughCursor(
        _ pane: Pane,
        maximumLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> PaneCapture {
        let bounds = try await captureBounds(for: pane)
        return try await captureTail(
            pane,
            startingAt: .start,
            endingAt: bounds.cursorRow,
            bounds: bounds,
            maximumLines: maximumLines,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }

    package func captureLookbackThroughCursor(
        _ pane: Pane,
        historyLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> PaneCapture {
        guard historyLines >= 0 else {
            throw .invocationFailed(reason: "pane capture lookback cannot be negative")
        }
        let bounds = try await captureBounds(for: pane)
        let start = max(-historyLines, -bounds.historySize)
        let (span, spanOverflowed) = bounds.cursorRow.subtractingReportingOverflow(start)
        let (maximumLines, countOverflowed) = span.addingReportingOverflow(1)
        guard !spanOverflowed, !countOverflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        return try await captureTail(
            pane,
            startingAt: .line(start),
            endingAt: bounds.cursorRow,
            bounds: bounds,
            maximumLines: maximumLines,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }

    package func captureTail(
        _ pane: Pane,
        fromAbsoluteRow firstRow: Int,
        throughAbsoluteRow lastRow: Int?,
        maximumLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> PaneCapture {
        guard firstRow >= 0 else {
            throw .invocationFailed(reason: "pane output start is invalid")
        }
        let bounds = try await captureBounds(for: pane)
        let (currentRow, currentRowOverflowed) = bounds.historySize.addingReportingOverflow(
            bounds.cursorRow
        )
        guard !currentRowOverflowed else {
            throw .invocationFailed(reason: "pane reported an invalid cursor")
        }
        let end = lastRow ?? currentRow
        guard end >= firstRow else {
            throw .invocationFailed(reason: "pane output range is invalid")
        }
        let (relativeStart, startOverflowed) = firstRow.subtractingReportingOverflow(
            bounds.historySize
        )
        let (relativeEnd, endOverflowed) = end.subtractingReportingOverflow(
            bounds.historySize
        )
        guard !startOverflowed, !endOverflowed, relativeEnd >= -bounds.historySize else {
            throw .invocationFailed(reason: "pane output is no longer in scrollback")
        }
        let (sourceLimit, limitOverflowed) = maximumLines.addingReportingOverflow(1)
        guard maximumLines > 0, !limitOverflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        let capture = try await captureTail(
            pane,
            startingAt: .line(relativeStart),
            endingAt: relativeEnd,
            bounds: bounds,
            maximumLines: sourceLimit,
            perStreamOutputLimit: perStreamOutputLimit
        )
        var rows = capture.lines
        while rows.last?.isEmpty == true { rows.removeLast() }
        let kept = rows.suffix(maximumLines)
        let evicted = max(0, -bounds.historySize - relativeStart)
        let afterCapture = rows.count - kept.count
        let (sourceDropped, sourceOverflowed) = capture.droppedLines.addingReportingOverflow(
            evicted
        )
        let (droppedLines, droppedOverflowed) = sourceDropped.addingReportingOverflow(
            afterCapture
        )
        guard !sourceOverflowed, !droppedOverflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        return PaneCapture(lines: Array(kept), droppedLines: droppedLines)
    }

    func captureTail(
        _ pane: Pane,
        startingAt requestedStart: CaptureStart?,
        endingAt requestedEnd: Int?,
        bounds: PaneCaptureBounds,
        maximumLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> PaneCapture {
        guard maximumLines > 0 else {
            throw .invocationFailed(reason: "a bounded capture needs at least one line")
        }
        guard perStreamOutputLimit > 0 else {
            throw .invocationFailed(reason: "a bounded capture needs a positive output limit")
        }
        let oldestAvailable = -bounds.historySize
        let earliest =
            switch requestedStart {
            case .none: 0
            case .start: oldestAvailable
            case let .line(row): max(row, oldestAvailable)
            }
        let end = requestedEnd ?? bounds.paneHeight - 1
        guard end >= earliest, end < bounds.paneHeight else {
            throw .invocationFailed(reason: "pane capture end is outside its contents")
        }
        let (boundedStart, startOverflowed) = end.subtractingReportingOverflow(
            maximumLines - 1
        )
        guard !startOverflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        let start = max(earliest, boundedStart)
        let acceptedRows = Int(Int32.min)...Int(Int16.max)
        guard acceptedRows.contains(start),
            requestedEnd.map(acceptedRows.contains) ?? true
        else {
            throw .invocationFailed(reason: "pane capture bounds exceed tmux's row range")
        }

        let reply = try await runIsolated(
            TmuxCommand(
                "capture-pane",
                [
                    "-p", "-t", pane.id.rawValue, "-S", String(start), "-E",
                    requestedEnd.map(String.init) ?? "-",
                ]
            ),
            guarding: pane,
            matching: bounds,
            perStreamOutputLimit: perStreamOutputLimit
        )
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        var text = reply.text
        if text.hasSuffix("\n") { text.removeLast() }
        let rows = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let kept = rows.suffix(maximumLines)
        let omittedAtSource = start - earliest
        let omittedAfterResize = rows.count - kept.count
        let (droppedLines, overflowed) = omittedAtSource.addingReportingOverflow(
            omittedAfterResize
        )
        guard !overflowed else {
            throw .invocationFailed(reason: "pane capture size overflowed")
        }
        return PaneCapture(lines: Array(kept), droppedLines: droppedLines)
    }

    func captureBounds(for pane: Pane) async throws(TmuxError) -> PaneCaptureBounds {
        let separator = String(FormatProjection.separator)
        guard
            let value = try await formatGlobal(
                "#{history_size}\(separator)#{history_bytes}"
                    + "\(separator)#{pane_height}\(separator)#{cursor_y}",
                for: pane
            )
        else {
            throw .staleServerValue
        }
        let fields = value.components(separatedBy: separator)
        guard fields.count == 4,
            let historySize = Int(fields[0]), historySize >= 0,
            let historyBytes = Int(fields[1]), historyBytes >= 0,
            let paneHeight = Int(fields[2]), paneHeight > 0,
            let cursorRow = Int(fields[3]), cursorRow >= 0, cursorRow < paneHeight
        else {
            throw .invocationFailed(reason: "tmux returned invalid pane capture bounds")
        }
        return PaneCaptureBounds(
            historySize: historySize,
            historyBytes: historyBytes,
            paneHeight: paneHeight,
            cursorRow: cursorRow
        )
    }

    /// The pane's contents from `start` rows above the visible region.
    ///
    /// A reader that only takes the visible rows loses anything that scrolled
    /// past between two reads, which for a pane producing output quickly is
    /// most of it. A bounded lookback keeps that from depending on how fast the
    /// reader happened to be, without paying for a whole scrollback each time.
    func capture(
        _ pane: Pane,
        startingAt start: CaptureStart?
    ) async throws(TmuxError) -> [String] {
        var arguments = ["-p", "-t", pane.id.rawValue]
        switch start {
        case .none: break
        case .start: arguments += ["-S", "-"]
        case let .line(row): arguments += ["-S", "\(row)"]
        }
        let reply = try await runGuarded(
            TmuxCommand("capture-pane", arguments),
            by: [.pane(pane)],
            checkingTargets: false
        )
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        var text = reply.text
        // tmux terminates the last row; that newline is not an extra row.
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    // MARK: Reading a pane

    /// Where a capture begins, relative to the visible region.
    enum CaptureStart: Sendable, Hashable {
        /// The start of the pane's retained history.
        case start
        /// A row, counted as tmux counts them: `0` is the top of the visible
        /// region and negative goes back into the scrollback.
        case line(Int)
    }
}
