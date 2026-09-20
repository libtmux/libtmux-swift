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

/// One piece of what a pane is sent.
///
/// tmux decides between typing and pressing per `send-keys` call, not per
/// argument: `-l` applies to every argument the call carries. So a sequence
/// that mixes the two cannot be one `send-keys`, and asking a caller for a
/// single `literally` flag makes "type this text, then press Enter" —
/// the commonest thing anyone sends a pane — inexpressible. Saying which each
/// piece is lets ``Server/send(_:to:)`` group them into as few calls as tmux
/// needs while keeping them one atomic dispatch.
public enum PaneInput: Sendable, Hashable, Codable {
    /// Characters, sent as themselves. A piece of text that happens to spell
    /// a key name — `Tab`, `Space`, `Up` — stays text.
    case text(String)
    /// A key by the name tmux knows it under: `Enter`, `C-c`, `Escape`.
    /// Unknown names are tmux's to reject.
    case key(String)
}

struct PaneCaptureBounds: Sendable, Hashable {
    let historySize: Int
    let historyBytes: Int
    let paneHeight: Int
    let cursorRow: Int
}

extension Server {
    /// The per-stream ceiling a pane read uses unless a caller lowers it.
    public static let captureOutputByteLimit = defaultTmuxReplyByteLimit

    // MARK: Talking to a pane

    /// Sends a mixture of text and keys to a pane, in order.
    ///
    /// Consecutive pieces of the same kind travel as one `send-keys`, and the
    /// whole sequence is one guarded dispatch: either every piece reaches the
    /// pane that was asked for, on the daemon that was asked for, or none
    /// does. Sending the text and the keys as separate calls would leave a
    /// pane holding half a command line when the second call found it gone.
    ///
    /// ```swift
    /// try await server.send([.text("make -j4"), .key("Enter")], to: pane)
    /// ```
    public func send(
        _ input: [PaneInput],
        to pane: Pane
    ) async throws(TmuxError) {
        let commands = Self.sendKeysCommands(for: input, to: pane)
        guard !commands.isEmpty else { return }
        let reply = try await runGuarded(commands, by: [.pane(pane)])
        guard reply.isSuccess else {
            throw reply.failure(for: commands[0])
        }
    }

    /// Groups a run of same-kind pieces into one `send-keys` each.
    static func sendKeysCommands(
        for input: [PaneInput],
        to pane: Pane
    ) -> [TmuxCommand] {
        var commands: [TmuxCommand] = []
        var pending: [String] = []
        var pendingIsText = false

        func flush() {
            guard !pending.isEmpty else { return }
            var arguments = ["-t", pane.id.rawValue]
            if pendingIsText { arguments.append("-l") }
            commands.append(TmuxCommand("send-keys", arguments + ["--"] + pending))
            pending = []
        }

        for piece in input {
            let (value, isText): (String, Bool) =
                switch piece {
                case let .text(text): (text, true)
                case let .key(name): (name, false)
                }
            if !pending.isEmpty, isText != pendingIsText { flush() }
            pendingIsText = isText
            pending.append(escapingTrailingCommandSeparator(value))
        }
        flush()
        return commands
    }

    /// Escapes a value's trailing `;` so tmux's own command-list splitter
    /// reads it as data instead of as the end of this command -- `--` does
    /// not protect against it, because the split happens before `send-keys`
    /// ever sees its arguments. `TmuxCommandList` documents the same rule for
    /// a command built by hand; a piece of pane input carries whatever text
    /// or key name a caller passed, so it has to be applied here instead of
    /// left to them.
    private static func escapingTrailingCommandSeparator(_ value: String) -> String {
        guard value.hasSuffix(TmuxCommandList.separator) else { return value }
        return String(value.dropLast()) + "\\" + TmuxCommandList.separator
    }

    /// Types a shell command line into a pane and presses Enter.
    ///
    /// The line is sent as text, so a command whose name collides with a tmux
    /// key name — `Tab`, or a script called `Up` — is typed rather than
    /// pressed. Enter is a key, and travels in the same guarded dispatch.
    public func run(
        _ commandLine: String,
        in pane: Pane
    ) async throws(TmuxError) {
        try await send([.text(commandLine), .key("Enter")], to: pane)
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
    ///
    /// - Parameters:
    ///   - pane: the pane to read.
    ///   - includingHistory: reads the scrollback too, from its start.
    ///   - maximumLines: how many trailing rows to keep.
    ///   - includingAttributes: keeps the escape sequences that colour and
    ///     style the text, as `capture-pane -e` does. Off, tmux hands back the
    ///     characters alone, which is what a comparison or a regular
    ///     expression wants; on, what a terminal would draw.
    ///   - maximumBytes: the per-stream ceiling for tmux's answer. The default
    ///     is the same 1 MiB every other read uses. Lower it when a pane's
    ///     scrollback is larger than the caller is willing to hold; the read
    ///     fails with ``TmuxError/outputLimitExceeded(perStreamBytes:)``
    ///     rather than returning a truncated screen.
    public func capture(
        _ pane: Pane,
        includingHistory: Bool = false,
        maximumLines: Int,
        includingAttributes: Bool = false,
        maximumBytes: Int = Server.captureOutputByteLimit
    ) async throws(TmuxError) -> PaneCapture {
        let bounds = try await captureBounds(for: pane)
        return try await captureTail(
            pane,
            startingAt: includingHistory ? .start : nil,
            endingAt: nil,
            bounds: bounds,
            maximumLines: maximumLines,
            perStreamOutputLimit: maximumBytes,
            includingAttributes: includingAttributes
        )
    }

    /// Reads a bounded tmux capture range using tmux's relative row numbering.
    public func captureRange(
        _ pane: Pane,
        startingAt start: Int? = nil,
        endingAt end: Int? = nil,
        joiningWrappedLines: Bool = false,
        maximumLines: Int,
        includingAttributes: Bool = false,
        maximumBytes: Int = Server.captureOutputByteLimit
    ) async throws(TmuxError) -> PaneCapture {
        let bounds = try await captureBounds(for: pane)
        return try await captureTail(
            pane,
            startingAt: start.map(CaptureStart.line),
            endingAt: end,
            bounds: bounds,
            maximumLines: maximumLines,
            perStreamOutputLimit: maximumBytes,
            includingAttributes: includingAttributes,
            joiningWrappedLines: joiningWrappedLines
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

    func captureLookbackThroughCursor(
        _ pane: Pane,
        historyLines: Int,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> PaneCapture {
        guard historyLines >= 0 else {
            throw .rejectedLocally(reason: "pane capture lookback cannot be negative")
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
        perStreamOutputLimit: Int,
        includingAttributes: Bool = false,
        joiningWrappedLines: Bool = false
    ) async throws(TmuxError) -> PaneCapture {
        guard maximumLines > 0 else {
            throw .rejectedLocally(reason: "a bounded capture needs at least one line")
        }
        guard perStreamOutputLimit > 0 else {
            throw .rejectedLocally(reason: "a bounded capture needs a positive output limit")
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
            throw .rejectedLocally(reason: "pane capture end is outside its contents")
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
            throw .rejectedLocally(reason: "pane capture bounds exceed tmux's row range")
        }

        var arguments = [
            "-p", "-t", pane.id.rawValue, "-S", String(start), "-E",
            requestedEnd.map(String.init) ?? "-",
        ]
        if joiningWrappedLines { arguments.append("-J") }
        if includingAttributes { arguments.append("-e") }
        let reply = try await runIsolated(
            TmuxCommand("capture-pane", arguments),
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
            by: [.pane(pane)]
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
