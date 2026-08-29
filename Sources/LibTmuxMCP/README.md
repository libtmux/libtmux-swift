# `LibTmuxMCP`

tmux as [Model Context Protocol][MCP] tools you can embed: `TmuxTools`,
`MCPRequestHandler`, and `MCPService`, without the stdio executable.

To *run* one rather than embed it, use [`libtmux-mcp`](../libtmux-mcp), which is
these tools served over stdio.

```swift
.product(name: "LibTmuxMCP", package: "libtmux-swift")
```

```swift
import LibTmux
import LibTmuxMCP
```

```swift
public func useEmbeddedTools(on server: Server) async throws(ToolError) -> Int {
    let tools = TmuxTools(server: server)
    for definition in tools.visibleDefinitions {
        print(definition.name, definition.summary)
    }
    let result = try await tools.call(ToolCall(name: "list_panes"))
    return result.structured["panes"]?.arrayValue?.count ?? 0
}
```

`TmuxTools(server:)` permits readonly tools. Pass `tier: .mutating` or
`tier: .destructive` explicitly when the embedding should expose writes.
Those tiers classify tool intent; they do not sandbox the host. `.mutating`
includes `run_shell` and `send_keys`, so expose it only to callers trusted to
act as the tmux user.

## The tools

The [root tool catalogue](../../README.md#the-tools) groups every tool by
safety tier and names the limits each one enforces.

`describe_filters` is what makes the rest usable. A client that does not speak
Swift learns the filterable vocabulary from it at runtime, instead of hard
coding field names that a rename would break — the same `FilterExpr` vocabulary
[`LibTmux`](../LibTmux) offers in-process, which is why it can travel to a
client at all.

Hierarchy rows carry opaque references for follow-up reads. They bind the row
to the current tmux daemon and expire when the MCP process restarts; re-list to
replace one that has expired. Exact window occurrences carry both a global
`windowRef` and session-local `linkRef`.

`TmuxTools` is written against `Server` and never mentions a mode, so it works
the same directly or over a connection.

[MCP]: https://modelcontextprotocol.io
