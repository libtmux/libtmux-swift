import ExampleCode
import Testing
import TmuxFixture

@Suite("MCP embedding", .timeLimit(.minutes(1)))
struct MCPEmbeddingTests {
    @Test("the embedded readonly tools list the fixture pane")
    func embeddedToolsListPanes() async throws {
        try await withTmuxServer { server in
            let paneCount = try await useEmbeddedTools(on: server)
            #expect(paneCount == 1)
        }
    }
}
