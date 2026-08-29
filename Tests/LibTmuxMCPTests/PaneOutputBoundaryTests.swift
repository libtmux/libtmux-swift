import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane output boundaries", .timeLimit(.minutes(1)))
struct PaneOutputBoundaryTests {
    @Test("pane tools bound history before collecting it")
    func paneToolsBoundHistoryAtTheSource() async throws {
        try await withTmuxServer { fixture in
            _ = try await fixture.setOption("history-limit", to: "6000")
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
            #expect(result.droppedLines == 4998)
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
            await #expect(throws: failure) {
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
            @Sendable func race() async throws(TmuxError) {
                try await fixture.run(
                    "printf 'RACE\\n'; \(fixture.shellInvocation) wait-for -S \(raced)",
                    in: pane
                )
                try await fixture.wait(for: raced)
            }
            await transport.beforeNextCapture(race)
            await #expect(throws: TmuxError.staleServerValue) {
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
    private var nextCaptureAction: (@Sendable () async throws(TmuxError) -> Void)?

    func failNextCapture(with error: TmuxError) {
        nextCaptureFailure = error
    }

    func beforeNextCapture(
        _ action: @escaping @Sendable () async throws(TmuxError) -> Void
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
                try await nextCaptureAction()
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
