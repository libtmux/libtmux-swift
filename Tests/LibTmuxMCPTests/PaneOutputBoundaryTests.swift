import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane output boundaries", .timeLimit(.minutes(1)))
struct PaneOutputBoundaryTests {
    @Test("pane content resources bound capture at the source")
    func paneContentResourcesAreBounded() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let transport = CaptureLimitRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )

            let resource = try await TmuxResources(server: server).read(
                "tmux://panes/\(wireRef(pane))/content"
            )
            let text = try #require(resource["text"]?.stringValue)
            let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            let capture = try #require(await transport.lastCapture)

            #expect(rows.count <= PaneOutputBudget.defaultCaptureLines)
            #expect(capture.outputLimit == PaneOutputBudget.sourceBytes)
            #expect(capture.arguments.contains("-S"))
        }
    }

    @Test("incremental capture ends at the cursor rather than screen padding")
    func incrementalCaptureEndsAtTheCursor() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let ready = "libtmux-test-shallow-ready-\(UUID().uuidString)"
            try await fixture.run(
                "stty -echo; printf '\\033c'; "
                    + "\(fixture.shellInvocation) wait-for -S \(ready)",
                in: pane
            )
            try await fixture.wait(for: ready)
            try await fixture.clearHistory(pane)

            let transport = CaptureLimitRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let current = try #require(try await server.panes().first { $0.id == pane.id })
            let tools = TmuxTools(server: server)
            let cursor = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(wireRef(current))])
                )
            ).decode(CaptureSinceResult.self).cursor

            let done = "libtmux-test-shallow-done-\(UUID().uuidString)"
            let release = "libtmux-test-shallow-release-\(UUID().uuidString)"
            try await fixture.run(
                "printf 'SHALLOW1\\nSHALLOW2\\n'; "
                    + "\(fixture.shellInvocation) wait-for -S \(done); "
                    + "\(fixture.shellInvocation) wait-for \(release)",
                in: pane
            )
            try await fixture.wait(for: done)
            let result = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object([
                        "pane": .string(wireRef(current)),
                        "cursor": .string(cursor),
                        "max_lines": .number(2),
                    ])
                )
            ).decode(CaptureSinceResult.self)

            #expect(result.lines.count == 2)
            #expect(result.lines.first?.hasSuffix("SHALLOW1") == true)
            #expect(result.lines.last == "SHALLOW2")
            let invocation = try #require(await transport.lastCapture)
            let command = invocation.arguments.joined(separator: " ")
            #expect(command.contains(" -E "))
            #expect(!command.contains(" -E - "))
            try await fixture.signal(release)
        }
    }

    @Test("numeric capture ends outside tmux's row range are refused")
    func numericCaptureEndIsValidated() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let bounds = PaneCaptureBounds(
                historySize: 0,
                historyBytes: 0,
                paneHeight: 40_001,
                cursorRow: 0
            )
            await #expect(
                throws: TmuxError.invocationFailed(
                    reason: "pane capture bounds exceed tmux's row range"
                )
            ) {
                try await server.captureTail(
                    pane,
                    startingAt: .line(0),
                    endingAt: 40_000,
                    bounds: bounds,
                    maximumLines: 40_000,
                    perStreamOutputLimit: 262_144
                )
            }
        }
    }

    @Test("pane tools bound history before collecting it")
    func paneToolsBoundHistoryAtTheSource() async throws {
        try await withTmuxServer { fixture in
            let history = try await fixture.setOption(
                "history-limit",
                to: "6000",
                scope: .globalSession
            )
            #expect(history.isSuccess, Comment(rawValue: history.errorText))
            let existing = Set(try await fixture.panes().map(\.id))
            _ = try await fixture.newSession(named: "bounded-capture")
            let pane = try #require(
                try await fixture.panes().first { !existing.contains($0.id) }
            )
            let ready = "libtmux-test-bounded-ready-\(UUID().uuidString)"
            try await fixture.run(
                "stty -echo; \(fixture.shellInvocation) wait-for -S \(ready)",
                in: pane
            )
            try await fixture.wait(for: ready)
            let cleared = "libtmux-test-bounded-cleared-\(UUID().uuidString)"
            try await fixture.run(
                "printf '\\033c'; \(fixture.shellInvocation) wait-for -S \(cleared)",
                in: pane
            )
            try await fixture.wait(for: cleared)
            try await fixture.clearHistory(pane)

            let finished = "libtmux-test-bounded-finished-\(UUID().uuidString)"
            let release = "libtmux-test-bounded-release-\(UUID().uuidString)"
            let filler = String(repeating: "x", count: 57)
            try await fixture.run(
                "i=0; while [ \"$i\" -lt 5000 ]; do "
                    + "if [ \"$i\" -eq 4999 ]; then printf 'ROW%04d\(filler)' \"$i\"; "
                    + "else printf 'ROW%04d\(filler)\\n' \"$i\"; fi; i=$((i + 1)); "
                    + "done; \(fixture.shellInvocation) wait-for -S \(finished); "
                    + "\(fixture.shellInvocation) wait-for \(release)",
                in: pane
            )
            try await fixture.wait(for: finished)

            let transport = CaptureLimitRecordingTransport()
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let current = try #require(
                try await server.panes().first { $0.id == pane.id }
            )
            #expect(
                try await server.formatGlobal("#{history_limit}", for: current)
                    == "6000"
            )
            let bounds = try await server.captureBounds(for: current)
            let result = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object([
                        "pane": .string(wireRef(current)),
                        "history": .bool(true),
                        "max_lines": .number(2),
                    ])
                )
            ).decode(CaptureResult.self)

            #expect(result.lines.count == 2)
            #expect(result.lines.map { String($0.prefix(7)) } == ["ROW4998", "ROW4999"])
            #expect(
                result.droppedLines
                    == bounds.historySize + bounds.paneHeight - result.lines.count
            )
            let capture = try #require(await transport.lastCapture)
            #expect(capture.outputLimit == 262_144)
            #expect(capture.arguments.joined(separator: " ").contains(" -S "))

            let search = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "search_panes",
                    arguments: .object([
                        "pattern": .string("ROW(?:0000|4999)"),
                        "history": .bool(true),
                        "max_lines_per_pane": .number(500),
                    ])
                )
            ).decode(SearchResult.self)
            #expect(search.matches.map(\.text).contains { $0.hasPrefix("ROW4999") })
            #expect(!search.matches.map(\.text).contains { $0.hasPrefix("ROW0000") })
            #expect(search.truncated)

            let failure = TmuxError.invocationFailed(reason: "injected capture failure")
            await transport.failNextCapture(with: failure)
            await #expect(throws: ToolError.tmux(failure)) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "search_panes",
                        arguments: .object(["pattern": .string("anything")])
                    )
                )
            }
            try await fixture.signal(release)

            let reset = "libtmux-test-incremental-reset-\(UUID().uuidString)"
            try await fixture.run(
                "printf '\\033c'; \(fixture.shellInvocation) wait-for -S \(reset)",
                in: pane
            )
            try await fixture.wait(for: reset)
            try await fixture.clearHistory(pane)
            let tools = TmuxTools(server: server)
            let raced = "libtmux-test-capture-raced-\(UUID().uuidString)"
            @Sendable func race() async throws {
                try await fixture.run(
                    "printf 'RACE\\n'; \(fixture.shellInvocation) wait-for -S \(raced)",
                    in: pane
                )
                try await fixture.wait(for: raced)
            }
            await transport.beforeNextCapture(race)
            await #expect(throws: ToolError.tmux(.staleServerValue)) {
                try await tools.call(
                    ToolCall(
                        name: "capture_pane",
                        arguments: .object([
                            "pane": .string(wireRef(current)), "max_lines": .number(2),
                        ])
                    )
                )
            }
            let cursor = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(wireRef(current))])
                )
            ).decode(CaptureSinceResult.self).cursor

            let incrementalDone = "libtmux-test-incremental-done-\(UUID().uuidString)"
            let incrementalRelease = "libtmux-test-incremental-release-\(UUID().uuidString)"
            try await fixture.run(
                "i=0; while [ \"$i\" -lt 4200 ]; do "
                    + "printf 'INC%04d\(filler)\\n' \"$i\"; i=$((i + 1)); "
                    + "done; \(fixture.shellInvocation) wait-for -S \(incrementalDone); "
                    + "\(fixture.shellInvocation) wait-for \(incrementalRelease)",
                in: pane
            )
            try await fixture.wait(for: incrementalDone)
            let incremental = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object([
                        "pane": .string(wireRef(current)),
                        "cursor": .string(cursor),
                        "max_lines": .number(2),
                    ])
                )
            ).decode(CaptureSinceResult.self)
            #expect(incremental.lines.count == 2)
            #expect(
                incremental.lines.map { String($0.prefix(7)) } == ["INC4198", "INC4199"]
            )
            #expect(incremental.droppedLines == 4_198)
            let incrementalCapture = try #require(await transport.lastCapture)
            #expect(incrementalCapture.outputLimit == 262_144)
            #expect(incrementalCapture.arguments.joined(separator: " ").contains(" -S "))
            try await fixture.signal(incrementalRelease)
        }
    }

    @Test("pane response bounds preserve whole UTF-8 rows")
    func paneResponseBoundsPreserveRows() throws {
        let oversizedPrefix = String(repeating: "é", count: 63_999)
        let tail = try PaneOutputBudget.tail([oversizedPrefix, "ok"])

        #expect(tail.lines == ["ok"])
        #expect(tail.droppedLines == 1)
        #expect(tail.lines.joined(separator: "\n").utf8.count <= 128_000)
        #expect(throws: ToolError.self) {
            try PaneOutputBudget.tail([String(repeating: "é", count: 64_001)])
        }
    }
}

actor CaptureLimitRecordingTransport: OutputLimitedProcessTransport {
    struct Invocation: Sendable {
        let arguments: [String]
        let outputLimit: Int
    }

    private let transport = SubprocessTransport()
    private(set) var lastCapture: Invocation?
    private var nextCaptureFailure: TmuxError?
    private var nextCaptureAction: (@Sendable () async throws -> Void)?

    func failNextCapture(with error: TmuxError) {
        nextCaptureFailure = error
    }

    func beforeNextCapture(
        _ action: @escaping @Sendable () async throws -> Void
    ) {
        nextCaptureAction = action
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
        if arguments.contains(where: { $0.contains("capture-pane") }) {
            lastCapture = Invocation(
                arguments: arguments,
                outputLimit: perStreamOutputLimit
            )
            if let nextCaptureAction {
                self.nextCaptureAction = nil
                do {
                    try await nextCaptureAction()
                } catch let error as TmuxError {
                    throw error
                } catch {
                    throw .invocationFailed(reason: String(describing: error))
                }
            }
            if let nextCaptureFailure {
                self.nextCaptureFailure = nil
                throw nextCaptureFailure
            }
        }
        return try await transport.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
}
