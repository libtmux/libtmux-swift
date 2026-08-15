# `LibTmuxMCP`

tmux as [Model Context Protocol][MCP] tools, as a library. The tool definitions
and their handlers, with no server and no transport — embed them in a server of
your own.

To *run* one rather than embed it, use [`libtmux-mcp`](../libtmux-mcp), which is
these tools served over stdio.

```swift
.product(name: "LibTmuxMCP", package: "libtmux-swift")
```

```swift
import LibTmuxMCP

let tools = TmuxTools(server: server)
for definition in TmuxTools.definitions {
    print(definition.name, definition.summary)
}
let result = try await tools.call(ToolCall(name: "list_panes"))
```

## The tools

| Tool | What it does |
| --- | --- |
| `list_sessions` | Every session, optionally selected by what its panes run |
| `list_windows` | Every window on the server |
| `list_panes` | Every pane, optionally filtered |
| `describe_filters` | The filterable fields, their types, and their aliases |
| `read_format` | Evaluates a tmux format, reaching fields the listings do not carry |
| `run_command` | Runs one tmux command and returns what tmux said |

`describe_filters` is what makes the rest usable. A client that does not speak
Swift learns the filterable vocabulary from it at runtime, instead of hard
coding field names that a rename would break — the same `FilterExpr` vocabulary
[`LibTmux`](../LibTmux) offers in-process, which is why it can travel to a
client at all.

`TmuxTools` is written against `Server` and never mentions a mode, so it works
the same directly or over a connection.

[MCP]: https://modelcontextprotocol.io
