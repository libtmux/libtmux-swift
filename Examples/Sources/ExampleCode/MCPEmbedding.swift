import LibTmux
import LibTmuxMCP

public func useEmbeddedTools(on server: Server) async throws(ToolError) -> Int {
    let tools = TmuxTools(server: server)
    for definition in tools.visibleDefinitions {
        print(definition.name, definition.summary)
    }
    let result = try await tools.call(ToolCall(name: "list_panes"))
    return result.structured["panes"]?.arrayValue?.count ?? 0
}

public func useExactEmbeddedTools(on server: Server) -> TmuxTools {
    let authority = ToolAuthority(
        toolsets: [],
        includedTools: ["create_window", "list_sessions"]
    )
    let tools = TmuxTools(server: server, authority: authority)
    return tools
}
