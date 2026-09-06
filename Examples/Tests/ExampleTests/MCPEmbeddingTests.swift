import ExampleCode
import Testing
import TmuxFixture

@Suite("MCP embedding", .timeLimit(.minutes(1)))
struct MCPEmbeddingTests {
    @Test("the embedded inspect tools list the fixture pane")
    func embeddedToolsListPanes() async throws {
        try await withTmuxServer { server in
            let paneCount = try await useEmbeddedTools(on: server)
            #expect(paneCount == 1)
        }
    }

    @Test("an exact embedded selection exposes only its named tools")
    func exactEmbeddedSelection() async throws {
        try await withTmuxServer { server in
            let tools = useExactEmbeddedTools(on: server)
            #expect(
                Set(tools.visibleDefinitions.map(\.name)) == ["create_window", "list_sessions"]
            )
        }
    }
}
