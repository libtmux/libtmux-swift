import ExampleCode
import Foundation
import LibTmux
import Testing
import TmuxFixture

private let artifactID = "swift-mcp-embedding"

private func assertEmbeddedToolsListPanes(on server: Server) async throws {
    let paneCount = try await useEmbeddedTools(on: server)
    #expect(paneCount == 1)
}

@Suite("MCP embedding", .timeLimit(.minutes(1)))
struct MCPEmbeddingTests {
    @Test("the embedded inspect tools list the one pane on a real server")
    func embeddedToolsListPanes() async throws {
        let route = try arenaRoute(
            environment: ProcessInfo.processInfo.environment,
            artifact: artifactID
        )
        if case let .arena(socketPath, _) = route {
            let server = try #require(try arenaServer(for: route))
            try await assertEmbeddedToolsListPanes(on: server)
            let evidence = try await arenaEvidence(
                for: server,
                requestedSocket: socketPath,
                artifact: artifactID
            )
            print("LIBTMUX_ARENA_EVIDENCE=\(String(decoding: evidence, as: UTF8.self))")
            return
        }

        try await withTmuxServer { server in
            try await assertEmbeddedToolsListPanes(on: server)
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
