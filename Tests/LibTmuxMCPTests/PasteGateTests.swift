import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("paste_text and named buffers", .timeLimit(.minutes(5)))
struct PasteGateTests {
    private func tools(_ server: Server) -> TmuxTools {
        TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: [.inspect, .manage, .execute, .teardown]),
            caller: nil
        )
    }

    private func paste(_ pane: Pane, with tools: TmuxTools) async throws -> ToolOutcome {
        try await tools.call(
            ToolCall(
                name: "paste_text",
                arguments: .object([
                    "paneId": .string(pane.id.rawValue), "text": .string("pasted-gate-marker"),
                ])))
    }

    @Test(
        "paste_text refuses before it stages a buffer where one cannot be deleted exactly",
        .enabled(if: laneIsSupportedForFeatures && !laneSupportsNamedBufferEditing, "needs 3.3a")
    )
    func refusedBelowThreeFour() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.setBuffer("bystander", named: "bystander")
            await #expect(throws: (any Error).self) {
                _ = try await paste(pane, with: tools(server))
            }
            // Nothing was staged, and the buffer already there is untouched.
            let buffers = try await server.buffers()
            #expect(buffers.map(\.name) == ["bystander"])
            let captured = try await server.capture(pane)
            #expect(!captured.contains { $0.contains("pasted-gate-marker") })
        }
    }

    @Test(
        "wait_for_text polls with capture-pane below 3.7 and attaches no control client",
        .enabled(if: laneIsSupportedForFeatures && !laneSupportsControl, "needs 3.3a to 3.6")
    )
    func waitForTextPollsBelowThreeSeven() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("sleep 1; echo mcp-poll-$((20+22))", in: pane)
            let result = try await tools(server).call(
                ToolCall(
                    name: "wait_for_text",
                    arguments: .object([
                        "paneId": .string(pane.id.rawValue),
                        "patterns": .array([.string("mcp-poll-42")]),
                        "timeoutMs": .integer(15_000),
                    ])))
            #expect(result.structured["outcome"]?.stringValue == "matched")
            let clients = try await server.clients()
            #expect(clients.allSatisfy { !$0.isControlMode })
        }
    }

    private func waitForText(
        _ pane: Pane, pattern: String, with tools: TmuxTools
    ) -> Task<ToolOutcome, any Error> {
        Task {
            try await tools.call(
                ToolCall(
                    name: "wait_for_text",
                    arguments: .object([
                        "paneId": .string(pane.id.rawValue),
                        "patterns": .array([.string(pattern)]),
                        "timeoutMs": .integer(15_000),
                    ])))
        }
    }

    @Test(
        "wait_for_text finds a match split across a wrapped row",
        .enabled(if: laneIsSupportedForFeatures, "needs a supported tmux")
    )
    func waitForTextJoinsWrappedRows() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let wait = waitForText(pane, pattern: "0WRAPNEEDLE", with: tools(server))
            try await Task.sleep(for: .milliseconds(500))
            // 78 digits and then the word, so the 80-column pane wraps inside it.
            try await server.run(
                "printf '%s%s\\n' \"$(printf '%078d' 0)\" WRAP\"\"NEEDLE", in: pane)
            let result = try await wait.value
            #expect(result.structured["outcome"]?.stringValue == "matched")
        }
    }

    @Test(
        "wait_for_text reports a killed server as a closed pane, with the output so far",
        .enabled(if: laneIsSupportedForFeatures, "needs a supported tmux")
    )
    func waitForTextReportsAKilledServer() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let wait = waitForText(pane, pattern: "never-appears-anywhere", with: tools(server))
            try await Task.sleep(for: .milliseconds(500))
            try await server.run("echo mcp-before-kill; sleep 60", in: pane)
            let seen = try await waitUntil(within: .seconds(15)) {
                try await server.capture(pane).contains { $0.contains("mcp-before-kill") }
            }
            try #require(seen)
            try await Task.sleep(for: .seconds(2))
            _ = try await server.run(TmuxCommand("kill-server"))
            let result = try await wait.value
            #expect(result.structured["outcome"]?.stringValue == "paneClosed")
            let tail = result.structured["tail"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(tail.contains { $0.contains("mcp-before-kill") })
        }
    }

    @Test(
        "paste_text stages, pastes and deletes its private buffer from 3.4",
        .enabled(if: laneSupportsNamedBufferEditing, "needs 3.4 or newer")
    )
    func allowedFromThreeFour() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            _ = try await paste(pane, with: tools(server))
            let buffers = try await server.buffers()
            #expect(buffers.isEmpty)
        }
    }
}

private let laneIsSupportedForFeatures = laneAtLeast(3, 3, "a")
