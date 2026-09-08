import Foundation
import LibTmux

struct SearchWorkBudget {
    enum Limit: String, Sendable, Hashable {
        case panes
        case lines
        case bytes
        case time
    }

    static let maximumLines = 20_000
    static let maximumBytes = 1_000_000
    static let maximumDuration: Duration = .seconds(5)

    let maximumPanes: Int
    let maximumLines: Int
    let maximumBytes: Int
    let deadline: ContinuousClock.Instant
    private var panes = 0
    private var lines = 0
    private var bytes = 0

    init(
        maximumPanes: Int = PaneOutputBudget.maximumSearchPanes,
        maximumLines: Int = Self.maximumLines,
        maximumBytes: Int = Self.maximumBytes,
        startedAt: ContinuousClock.Instant = .now,
        maximumDuration: Duration = Self.maximumDuration
    ) {
        precondition(maximumPanes >= 0 && maximumLines >= 0 && maximumBytes >= 0)
        self.maximumPanes = maximumPanes
        self.maximumLines = maximumLines
        self.maximumBytes = maximumBytes
        self.deadline = startedAt.advanced(by: maximumDuration)
    }

    mutating func beginPane(at now: ContinuousClock.Instant = .now) -> Limit? {
        guard now < deadline else { return .time }
        guard panes < maximumPanes else { return .panes }
        panes += 1
        return nil
    }

    mutating func consume(
        _ line: String,
        at now: ContinuousClock.Instant = .now
    ) -> Limit? {
        guard now < deadline else { return .time }
        guard lines < maximumLines else { return .lines }
        let lineBytes = line.utf8.count
        guard lineBytes <= maximumBytes - bytes else { return .bytes }
        lines += 1
        bytes += lineBytes
        return nil
    }

    func remaining(at now: ContinuousClock.Instant = .now) -> Duration? {
        guard now < deadline else { return nil }
        return now.duration(to: deadline)
    }
}

extension TmuxTools {
    func searchPanes(
        _ arguments: Arguments,
        _ progress: ProgressReporter = .silent
    ) async throws -> ToolOutcome {
        let requestedPattern = try arguments.string("pattern")
        let expression =
            if try arguments.bool("regex", or: false) {
                try ToolPattern.compile(requestedPattern, argument: "pattern")
            } else {
                try ToolPattern.compileLiteral(requestedPattern, argument: "pattern")
            }
        let matchBudget = RegexMatchBudget()
        let lineLimit = try arguments.integer(
            "scrollbackLines",
            or: PaneOutputBudget.defaultSearchLines
        )
        let perPaneLimit = try arguments.integer("maxMatchesPerPane", or: 50)

        var panes = try await server.panes()
        if let requestedSession = try arguments.optionalString("session") {
            let session = try await capabilitySession(requestedSession)
            let snapshot = try await server.snapshot()
            let windowIDs = Set(
                snapshot.windowLinks.filter { $0.sessionID == session.id }.map(\.windowID))
            panes = panes.filter { windowIDs.contains($0.windowID) }
        }

        let panesAvailable = panes.count
        let panesPlanned = min(panes.count, PaneOutputBudget.maximumSearchPanes)
        var matches: [PaneMatch] = []
        var searched = 0
        var matchedBytes = 0
        var truncatedBy: Set<String> = []
        var workBudget = SearchWorkBudget()
        paneLoop: for pane in panes {
            if let limit = workBudget.beginPane() {
                truncatedBy.insert(limit.rawValue)
                break
            }
            searched += 1
            await progress.report(
                Double(searched),
                of: Double(panesPlanned),
                "searched \(searched) of \(panesPlanned) panes"
            )
            guard let remaining = workBudget.remaining() else {
                truncatedBy.insert(SearchWorkBudget.Limit.time.rawValue)
                break
            }
            guard
                let capture = try await captureForSearch(
                    pane,
                    maximumLines: lineLimit,
                    timeout: remaining
                )
            else {
                truncatedBy.insert(SearchWorkBudget.Limit.time.rawValue)
                break
            }
            guard workBudget.remaining() != nil else {
                truncatedBy.insert(SearchWorkBudget.Limit.time.rawValue)
                break
            }
            let bounded = try PaneOutputBudget.tail(
                capture.lines,
                afterDropping: capture.droppedLines
            )
            if bounded.droppedLines > 0 { truncatedBy.insert("pane-output") }
            var paneMatches = 0
            for (offset, line) in bounded.lines.enumerated() {
                if let limit = workBudget.consume(line) {
                    truncatedBy.insert(limit.rawValue)
                    break paneLoop
                }
                guard
                    try ToolPattern.matches(
                        expression,
                        in: line,
                        argument: "pattern",
                        budget: matchBudget
                    )
                else {
                    continue
                }
                guard paneMatches < perPaneLimit else {
                    truncatedBy.insert("matches")
                    break
                }
                let bytes = line.utf8.count
                guard bytes <= PaneOutputBudget.returnedBytes else {
                    throw ToolError.refusedForSafety(
                        "one matching pane row exceeds the 128000-byte raw text limit"
                    )
                }
                guard matchedBytes <= PaneOutputBudget.returnedBytes - bytes else {
                    truncatedBy.insert("result-bytes")
                    break paneLoop
                }
                matchedBytes += bytes
                paneMatches += 1
                matches.append(
                    PaneMatch(
                        paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                        pane: pane.id.rawValue,
                        line: bounded.droppedLines + offset + 1,
                        text: line
                    )
                )
            }
        }
        if searched == panesPlanned, panesAvailable > panesPlanned {
            truncatedBy.insert(SearchWorkBudget.Limit.panes.rawValue)
        }
        return .init(
            SearchResult(
                matches: matches,
                panesSearched: searched,
                panesAvailable: panesAvailable,
                truncated: !truncatedBy.isEmpty,
                truncatedBy: truncatedBy.sorted()
            )
        )
    }

    private func captureForSearch(
        _ pane: Pane,
        maximumLines: Int,
        timeout: Duration
    ) async throws -> PaneCapture? {
        let server = server
        return try await withThrowingTaskGroup(of: PaneCapture?.self) { group in
            group.addTask {
                try await server.captureTail(
                    pane,
                    includingHistory: true,
                    maximumLines: maximumLines,
                    perStreamOutputLimit: PaneOutputBudget.sourceBytes
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    func captureSince(_ arguments: Arguments) async throws -> ToolOutcome {
        let pane = try await capabilityPane(try arguments.string("paneId"))
        let limit = try arguments.integer("maxLines", or: 200)
        var cursor: CaptureCursor?
        if let text = try arguments.optionalString("cursor") {
            cursor = try? JSONDecoder().decode(CaptureCursor.self, from: Data(text.utf8))
            guard cursor != nil else {
                throw ToolError.wrongArgumentType(
                    "cursor",
                    expected: "a cursor a previous capture_since returned"
                )
            }
        }
        var read = try await server.captureBounded(
            pane,
            since: cursor,
            maximumLines: limit,
            perStreamOutputLimit: PaneOutputBudget.sourceBytes
        )
        let waitMs = try arguments.integer("waitMs", or: 0)
        if read.lines.isEmpty, waitMs > 0 {
            try await Task.sleep(for: .milliseconds(waitMs))
            read = try await server.captureBounded(
                pane,
                since: cursor,
                maximumLines: limit,
                perStreamOutputLimit: PaneOutputBudget.sourceBytes
            )
        }
        let bounded = try PaneOutputBudget.tail(
            read.lines,
            afterDropping: read.droppedLines
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = String(
            decoding: (try? encoder.encode(read.cursor)) ?? Data(),
            as: UTF8.self
        )
        return .init(
            CaptureSinceResult(
                paneRef: WireReferenceCodec.processLocal.reference(to: pane),
                pane: pane.id.rawValue,
                lines: bounded.lines,
                cursor: encoded,
                linesMissed: read.linesMissed,
                restarted: read.restarted,
                droppedLines: bounded.droppedLines
            )
        )
    }
}
