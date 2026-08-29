import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("reading only what is new", .timeLimit(.minutes(1)))
struct CaptureSinceTests {
    private func bootstrapPane(_ server: Server) async throws -> Pane {
        try #require(try await server.panes().first)
    }

    /// Reads until `lines` are non-empty or the attempts run out, because a
    /// pane answers when its shell gets round to it.
    private func settle(
        _ server: Server,
        _ pane: Pane,
        from cursor: CaptureCursor
    ) async throws -> IncrementalCapture {
        var latest = IncrementalCapture(lines: [], cursor: cursor)
        for _ in 0..<40 {
            latest = try await server.capture(pane, since: latest.cursor)
            if !latest.lines.isEmpty { return latest }
            try await Task.sleep(for: .milliseconds(100))
        }
        return latest
    }

    @Test("bounded history capture reports omitted rows")
    func boundedHistoryCaptureReportsOmittedRows() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let height = try #require(
                try await server.format("#{pane_height}", addressing: pane.id.rawValue)
                    .flatMap(Int.init)
            )
            let count = height + 8
            let ready = "bounded-public-ready-\(UUID().uuidString)"
            let hold = "bounded-public-hold-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; printf '\\033c'; i=0; while [ \"$i\" -lt \(count) ]; do "
                    + "printf 'row-%03d\\n' \"$i\"; i=$((i + 1)); done; "
                    + "\(server.shellInvocation) wait-for -S \(ready); "
                    + "\(server.shellInvocation) wait-for \(hold)",
                in: pane
            )
            try await server.wait(for: ready)

            let capture = try await server.capture(
                pane,
                includingHistory: true,
                maximumLines: 3
            )

            #expect(capture.lines.count == 3)
            #expect(capture.lines.contains(String(format: "row-%03d", count - 1)))
            #expect(capture.droppedLines > 0)
            try await server.signal(hold)
        }
    }

    @Test("incremental capture bounds pane output at the transport")
    func incrementalCaptureIsSourceBounded() async throws {
        try await withTmuxServer { fixture in
            let transport = CaptureRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try await bootstrapPane(server)

            _ = try await server.capture(pane, since: nil)

            let limits = await transport.captureLimits
            #expect(!limits.isEmpty)
            #expect(limits.allSatisfy { $0 == 1_048_576 })
        }
    }

    @Test("output racing an incremental capture is retried")
    func outputRaceIsRetried() async throws {
        try await withTmuxServer { fixture in
            let transport = CaptureRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let pane = try await bootstrapPane(server)
            let ready = "incremental-race"
            await transport.beforeNextCapture { () async throws(TmuxError) in
                try await fixture.run(
                    "printf 'raced\\n'; \(fixture.shellInvocation) wait-for -S \(ready)",
                    in: pane
                )
                try await fixture.wait(for: ready)
            }

            let started = try await server.capture(pane, since: nil)

            #expect(started.lines.isEmpty)
            #expect(await transport.captureLimits.count == 2)
        }
    }

    @Test("a forward scan retries output racing its bounded chunk")
    func forwardScanRetriesOutputRace() async throws {
        try await withTmuxServer { fixture in
            let pane = try await bootstrapPane(fixture)
            try await fixture.run(
                "stty -echo; \(fixture.shellInvocation) wait-for -S forward-scan-ready",
                in: pane
            )
            try await fixture.wait(for: "forward-scan-ready")
            let started = try await fixture.capture(pane, since: nil)
            let transport = CaptureRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            await transport.beforeNextCapture { () async throws(TmuxError) in
                try await fixture.run(
                    "printf '\\nforward-raced\\n'; "
                        + "\(fixture.shellInvocation) wait-for -S forward-scan-raced",
                    in: pane
                )
                try await fixture.wait(for: "forward-scan-raced")
            }
            var visited: [String] = []

            let result = try await server.scanForward(
                pane,
                since: started.cursor,
                sourceLinesPerChunk: 16,
                maximumChunks: 8,
                perStreamOutputLimit: 1_048_576
            ) { rows in
                visited.append(contentsOf: rows)
                return false
            }

            #expect(!result.linesMissed)
            #expect(visited.contains("forward-raced"))
            #expect(await transport.captureLimits.count == 2)
        }
    }

    @Test("a forward scan reports blank rows once across chunks")
    func forwardScanDoesNotRepeatBlankChunkBoundary() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let tmux = server.shellInvocation
            let script =
                "printf '\\033c'; \(tmux) wait-for -S forward-blanks-ready; "
                + "\(tmux) wait-for forward-blanks-start; "
                + "printf 'head\\n\\n\\n\\n\\n\\ntail\\n'; "
                + "\(tmux) wait-for -S forward-blanks-done; "
                + "\(tmux) wait-for forward-blanks-release"
            try await server.respawn(pane, running: [script])
            try await server.wait(for: "forward-blanks-ready")
            try await server.clearHistory(pane)
            let started = try await server.capture(pane, since: nil)

            try await server.signal("forward-blanks-start")
            try await server.wait(for: "forward-blanks-done")
            var visited: [String] = []
            let result = try await server.scanForward(
                pane,
                since: started.cursor,
                sourceLinesPerChunk: 4,
                maximumChunks: 8,
                perStreamOutputLimit: 1_048_576
            ) { rows in
                visited.append(contentsOf: rows)
                return false
            }
            try await server.signal("forward-blanks-release")

            #expect(!result.hasMore)
            #expect(visited == ["head", "", "", "", "", "", "tail"])
        }
    }

    @Test("incremental capture survives history collection")
    func historyCollectionKeepsTheDelta() async throws {
        try await withTmuxServer { server in
            let historyLimit = 20
            _ = try await server.setOption(
                "history-limit",
                to: String(historyLimit),
                scope: .globalSession
            )
            let session = try await server.newSession(named: "history-collection")
            let pane = try #require(
                try await server.snapshot().panes(of: session).first
            )
            let height = try #require(
                try await server.format("#{pane_height}", addressing: pane.id.rawValue)
                    .flatMap(Int.init)
            )
            let belowCollection = historyLimit - max(1, historyLimit / 10)
            let linesToReachBelowCollection = height - 1 + belowCollection
            let linesToFillHistory = historyLimit
            let linesToEvictTheMark = height + historyLimit + 5
            let script =
                "printf '\\033c'; \(server.shellInvocation) wait-for -S history-ready; "
                + "\(server.shellInvocation) wait-for history-start; "
                + "i=0; while [ \"$i\" -lt \(linesToReachBelowCollection) ]; do "
                + "printf '\\n'; i=$((i + 1)); done; "
                + "\(server.shellInvocation) wait-for -S history-below-collection; "
                + "\(server.shellInvocation) wait-for history-fill; "
                + "i=0; while [ \"$i\" -lt \(linesToFillHistory) ]; do "
                + "printf 'SEED%03d\\n' \"$i\"; i=$((i + 1)); done; "
                + "printf 'OLD'; "
                + "\(server.shellInvocation) wait-for -S history-filled; "
                + "\(server.shellInvocation) wait-for history-rewrite; "
                + "printf '\\rNEW'; "
                + "\(server.shellInvocation) wait-for -S history-rewrite-done; "
                + "\(server.shellInvocation) wait-for history-next; "
                + "printf '\\nLOST\\n'; "
                + "\(server.shellInvocation) wait-for -S history-next-done; "
                + "\(server.shellInvocation) wait-for history-overflow; "
                + "i=0; while [ \"$i\" -lt \(linesToEvictTheMark) ]; do "
                + "printf 'FRESH%03d\\n' \"$i\"; i=$((i + 1)); done; "
                + "\(server.shellInvocation) wait-for -S history-overflow-done; "
                + "\(server.shellInvocation) wait-for history-ambiguous; "
                + "i=0; while [ \"$i\" -lt \(linesToEvictTheMark) ]; do "
                + "printf 'SAME\\n'; i=$((i + 1)); done; "
                + "\(server.shellInvocation) wait-for -S history-ambiguous-ready; "
                + "\(server.shellInvocation) wait-for history-ambiguous-next; "
                + "printf 'SAME\\n'; "
                + "\(server.shellInvocation) wait-for -S history-ambiguous-done; "
                + "\(server.shellInvocation) wait-for history-release"
            try await server.respawn(pane, running: [script])
            try await server.wait(for: "history-ready")
            try await server.clearHistory(pane)
            try await server.signal("history-start")
            try await server.wait(for: "history-below-collection")
            let below = "\(belowCollection):\(height - 1)"
            #expect(
                try await server.format(
                    "#{history_size}:#{cursor_y}",
                    addressing: pane.id.rawValue
                ) == below
            )
            let belowMark = try await server.capture(pane, since: nil)
            let belowQuiet = try await server.capture(pane, since: belowMark.cursor)
            #expect(belowQuiet.lines.isEmpty)
            #expect(!belowQuiet.linesMissed)

            try await server.clearHistory(pane)
            try await server.signal("history-fill")
            try await server.wait(for: "history-filled")
            let saturated = "\(historyLimit):\(height - 1)"
            let before = try await server.format(
                "#{history_size}:#{cursor_y}",
                addressing: pane.id.rawValue
            )
            #expect(before == saturated)
            let started = try await server.capture(pane, since: nil)
            #expect(started.cursor.anchor == historyLimit + height - 1)
            #expect(started.cursor.tail == "OLD")

            try await server.signal("history-rewrite")
            try await server.wait(for: "history-rewrite-done")
            let rewritten = try await server.capture(pane, since: started.cursor)
            #expect(rewritten.lines == ["NEW"])
            #expect(!rewritten.linesMissed)

            try await server.signal("history-next")
            try await server.wait(for: "history-next-done")
            let after = try await server.format(
                "#{history_size}:#{cursor_y}",
                addressing: pane.id.rawValue
            )
            #expect(after == saturated)
            let update = try await server.capture(pane, since: rewritten.cursor)

            #expect(update.lines == ["LOST"])
            #expect(!update.linesMissed)

            try await server.signal("history-overflow")
            try await server.wait(for: "history-overflow-done")
            let gap = try await server.capture(pane, since: update.cursor)
            #expect(gap.lines.isEmpty)
            #expect(gap.linesMissed)

            try await server.signal("history-ambiguous")
            try await server.wait(for: "history-ambiguous-ready")
            let repeated = try await server.capture(pane, since: nil)
            try await server.signal("history-ambiguous-next")
            try await server.wait(for: "history-ambiguous-done")
            let ambiguous = try await server.capture(pane, since: repeated.cursor)
            #expect(ambiguous.lines.isEmpty)
            #expect(ambiguous.linesMissed)
            try await server.signal("history-release")
        }
    }

    @Test("the first read marks the place rather than dumping the backlog")
    func firstReadStartsWatching() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.run("printf 'before-watching\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            let started = try await server.capture(pane, since: nil)
            // A watcher asked to start now should not be handed a screenful of
            // what happened before it asked.
            #expect(started.lines.isEmpty)
            #expect(!started.restarted)
        }
    }

    @Test("identical lines at successive rows are both reported")
    func repeatedLinesRemainDistinct() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let script =
                "printf '\\033c'; \(server.shellInvocation) wait-for -S repeat-ready; "
                + "\(server.shellInvocation) wait-for repeat-first; printf 'SAME\\n'; "
                + "\(server.shellInvocation) wait-for -S repeat-first-done; "
                + "\(server.shellInvocation) wait-for repeat-second; printf 'SAME\\n'; "
                + "\(server.shellInvocation) wait-for -S repeat-second-done; "
                + "\(server.shellInvocation) wait-for repeat-release"
            try await server.respawn(pane, running: [script])
            try await server.wait(for: "repeat-ready")
            try await server.clearHistory(pane)
            let started = try await server.capture(pane, since: nil)

            try await server.signal("repeat-first")
            try await server.wait(for: "repeat-first-done")
            let first = try await server.capture(pane, since: started.cursor)
            #expect(first.lines == ["SAME"])

            try await server.signal("repeat-second")
            try await server.wait(for: "repeat-second-done")
            let second = try await server.capture(pane, since: first.cursor)
            #expect(second.lines == ["SAME"])
            try await server.signal("repeat-release")
        }
    }

    @Test("a second read answers only what arrived between them")
    func secondReadIsTheDifference() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            try await server.run("printf 'first-new-line\\n'", in: pane)

            let next = try await settle(server, pane, from: started.cursor)
            #expect(next.lines.contains { $0.contains("first-new-line") })
            // What the pane showed before the cursor is not repeated.
            #expect(!next.lines.contains { $0.contains("$ ") && $0.isEmpty })
        }
    }

    @Test("a quiet pane answers nothing at all")
    func quietPaneAnswersNothing() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            let ready = "quiet-pane-ready-\(UUID().uuidString)"
            let release = "quiet-pane-release-\(UUID().uuidString)"
            try await server.run(
                "printf 'settled\\n'; "
                    + "\(server.shellInvocation) wait-for -S \(ready); "
                    + "\(server.shellInvocation) wait-for \(release); "
                    + "printf 'released-too-early\\n'",
                in: pane
            )
            try await server.wait(for: ready)
            let caught = try await settle(server, pane, from: started.cursor)

            let quiet = try await server.capture(pane, since: caught.cursor)
            // The whole point: watching something that is not happening costs
            // one command and no content.
            #expect(quiet.lines.isEmpty)

            let stillQuiet = try await server.capture(pane, since: quiet.cursor)
            #expect(stillQuiet.lines.isEmpty)
            try await server.signal(release)
        }
    }

    @Test("a row rewritten in place is reported again")
    func rewrittenRowIsReportedAgain() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            // A carriage return without a newline rewrites the row, which is
            // what a spinner or a progress bar does. Position alone cannot see
            // that; the row's contents can.
            try await server.run("printf 'step one\\rstep two\\n'", in: pane)

            let caught = try await settle(server, pane, from: started.cursor)
            #expect(caught.lines.contains { $0.contains("step two") })
        }
    }

    @Test("a cursor from another pane starts over rather than lying")
    func cursorFromAnotherPaneRestarts() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let other = try await server.split(pane)
            let started = try await server.capture(pane, since: nil)

            let crossed = try await server.capture(other, since: started.cursor)
            // Anchors are per pane; using one against another would report
            // rows that were never there.
            #expect(crossed.lines.isEmpty)
            #expect(crossed.cursor.pane == other.id.rawValue)
        }
    }

    @Test("a cursor from an earlier daemon starts over")
    func cursorFromAnEarlierDaemonStartsOver() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            let staleIncarnation = ServerIncarnation(
                endpoint: pane.incarnation.endpoint,
                socketPath: pane.incarnation.socketPath,
                processID: pane.incarnation.processID,
                startedAt: pane.incarnation.startedAt + 1
            )

            let staleCursor = CaptureCursor(
                pane: started.cursor.pane,
                incarnation: staleIncarnation,
                anchor: started.cursor.anchor,
                tail: started.cursor.tail,
                processID: started.cursor.processID,
                historySize: started.cursor.historySize,
                historyLimit: started.cursor.historyLimit,
                paneWidth: started.cursor.paneWidth,
                paneHeight: started.cursor.paneHeight,
                alternateScreen: started.cursor.alternateScreen,
                checkpoint: started.cursor.checkpoint,
                checkpointAnchor: started.cursor.checkpointAnchor
            )

            let crossed = try await server.capture(pane, since: staleCursor)
            #expect(crossed.restarted)
            #expect(crossed.lines.isEmpty)
            #expect(crossed.cursor.incarnation == pane.incarnation)
        }
    }

    @Test("a respawned pane says so rather than mixing two programs")
    func respawnIsReported() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            try await server.respawn(pane)
            try await Task.sleep(for: .milliseconds(400))

            let after = try await server.capture(pane, since: started.cursor)
            // The cursor described a process that no longer exists, and the
            // rows it counted belong to it.
            #expect(after.restarted)
            #expect(after.lines.isEmpty)
        }
    }
}

struct RecordedCaptureRequest: Sendable {
    let arguments: [String]
    let perStreamOutputLimit: Int

    var rowSpan: Int? {
        let fields = arguments.joined(separator: " ").split(separator: " ")
        guard fields.contains(where: { $0.contains("capture-pane") }),
            let startFlag = fields.lastIndex(of: "-S"),
            let endFlag = fields.lastIndex(of: "-E"),
            fields.indices.contains(startFlag + 1),
            fields.indices.contains(endFlag + 1),
            let start = Int(fields[startFlag + 1]),
            let end = Int(fields[endFlag + 1]),
            end >= start
        else { return nil }
        return end - start + 1
    }
}

actor CaptureRecordingTransport: OutputLimitedProcessTransport {
    private let underlying = SubprocessTransport()
    private(set) var captureRequests: [RecordedCaptureRequest] = []
    private var captureActions: [Int: @Sendable () async throws(TmuxError) -> Void] = [:]
    private var nextCaptureAction: (@Sendable () async throws(TmuxError) -> Void)?
    private var afterCaptureAction: (@Sendable () async throws(TmuxError) -> Void)?

    var captureLimits: [Int] {
        captureRequests.map(\.perStreamOutputLimit)
    }

    func beforeNextCapture(
        _ action: @escaping @Sendable () async throws(TmuxError) -> Void
    ) {
        nextCaptureAction = action
    }

    func beforeCapture(
        _ ordinal: Int,
        _ action: @escaping @Sendable () async throws(TmuxError) -> Void
    ) {
        precondition(ordinal > 0)
        captureActions[ordinal] = action
    }

    func afterEveryCapture(
        _ action: @escaping @Sendable () async throws(TmuxError) -> Void
    ) {
        afterCaptureAction = action
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: .max
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let isCapture = arguments.contains(where: { $0.contains("capture-pane") })
        if isCapture {
            captureRequests.append(
                RecordedCaptureRequest(
                    arguments: arguments,
                    perStreamOutputLimit: perStreamOutputLimit
                )
            )
            if let action = captureActions[captureRequests.count] {
                try await action()
            }
            if let nextCaptureAction {
                self.nextCaptureAction = nil
                try await nextCaptureAction()
            }
        }
        let reply = try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
        if isCapture, let afterCaptureAction { try await afterCaptureAction() }
        return reply
    }
}
