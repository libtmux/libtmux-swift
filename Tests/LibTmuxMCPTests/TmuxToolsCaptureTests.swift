import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

extension TmuxToolsTests {
    @Test("capture reports what it dropped rather than looking like a short pane")
    func captureReportsWhatItDropped() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object([
                        "pane": .string(wireRef(pane)), "max_lines": .number(2),
                    ])
                )
            )
            let captured = try outcome.decode(CaptureResult.self)
            #expect(captured.lines.count <= 2)
            #expect(captured.droppedLines >= 0)
        }
    }

    @Test("watching a pane sends the difference, not the screen")
    func captureSinceSendsOnlyWhatIsNew() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)

            let started = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(wireRef(pane))])
                )
            ).decode(CaptureSinceResult.self)
            // Starting to watch is not the same as asking for the backlog.
            #expect(started.lines.isEmpty)
            #expect(!started.cursor.isEmpty)

            try await server.run("printf 'incremental-marker\\n'", in: pane)
            var caught = started
            for _ in 0..<30 {
                caught = try await tools.call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "pane": .string(wireRef(pane)), "cursor": .string(caught.cursor),
                        ])
                    )
                ).decode(CaptureSinceResult.self)
                if !caught.lines.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(caught.lines.contains { $0.contains("incremental-marker") })

            let quiet = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object([
                        "pane": .string(wireRef(pane)), "cursor": .string(caught.cursor),
                    ])
                )
            ).decode(CaptureSinceResult.self)
            // The whole point: a second look at a pane that has not moved
            // costs one call and no content.
            #expect(quiet.lines.isEmpty)
        }
    }

    @Test("a cursor that is not one is refused rather than guessed at")
    func malformedCursorIsRefused() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "pane": .string(wireRef(pane)), "cursor": .string("not-a-cursor"),
                        ])
                    )
                )
            }
        }
    }

    @Test("a structurally impossible cursor is refused")
    func impossibleCursorIsRefused() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let started = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(wireRef(pane))])
                )
            ).decode(CaptureSinceResult.self)
            var payload = try #require(
                JSONSerialization.jsonObject(with: Data(started.cursor.utf8))
                    as? [String: Any]
            )
            payload["anchor"] = -1
            let impossible = try #require(
                String(
                    data: JSONSerialization.data(withJSONObject: payload),
                    encoding: .utf8
                )
            )

            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "pane": .string(wireRef(pane)),
                            "cursor": .string(impossible),
                        ])
                    )
                )
            }
        }
    }

    @Test("a raw pane id is refused by targeted reads")
    func rawPaneIDIsRefused() async throws {
        _ = try await withTmuxServer { server in
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "capture_pane",
                        arguments: .object(["pane": .string("%999")])
                    )
                )
            }
        }
    }

    @Test("search finds text in what a pane printed, with the pane that printed it")
    func searchFindsPrintedText() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'needle-in-a-pane\\n'", in: pane)
            let tools = TmuxTools(server: server)

            var found: SearchResult?
            for _ in 0..<20 {
                let outcome = try await tools.call(
                    ToolCall(
                        name: "search_panes",
                        arguments: .object([
                            "pattern": .string("NEEDLE-IN-A-PANE"),
                            "case_insensitive": .bool(true),
                        ])
                    )
                )
                found = try outcome.decode(SearchResult.self)
                if !(found?.matches.isEmpty ?? true) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(found?.matches.first?.pane == pane.id.rawValue)
        }
    }

    @Test("search refuses patterns outside the bounded dialect")
    func searchRefusesUnsupportedPatterns() async throws {
        let server = try Server(socketPath: "/tmp/libtmux-swift-test/search-pattern")

        await #expect(throws: ToolError.self) {
            try await TmuxTools(server: server).call(
                ToolCall(
                    name: "search_panes",
                    arguments: .object(["pattern": .string("(?=unbounded)")])
                )
            )
        }
    }

    @Test("tool matching refuses aggregate work exhaustion")
    func toolMatchingRefusesAggregateWorkExhaustion() throws {
        let pattern = try RegexPattern("z$")
        let budget = try RegexMatchBudget(maximum: 20)
        #expect(
            try !ToolPattern.matches(
                pattern,
                in: "aaaa",
                argument: "pattern",
                budget: budget
            )
        )

        #expect(
            throws: ToolError.refusedForSafety(
                "bounded matching for pattern could not finish: "
                    + "workLimitExceeded(maximum: 20)"
            )
        ) {
            try ToolPattern.matches(
                pattern,
                in: "aaaa",
                argument: "pattern",
                budget: budget
            )
        }
    }

}
