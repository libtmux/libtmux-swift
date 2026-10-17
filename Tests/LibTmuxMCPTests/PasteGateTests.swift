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
