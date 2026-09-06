# `libtmux-mcp`

A [Model Context Protocol][MCP] server for tmux. It speaks JSON-RPC 2.0 over
stdio, one message per line, so anything that launches an MCP server can drive
tmux through it.

The tools it serves are [`LibTmuxMCP`](../LibTmuxMCP); this is the executable
that answers for them.

```console
$ swift build --product libtmux-mcp
```

Point a client at the built binary. It takes no flags — which tmux it talks to
is environment, so a client config is where you say so:

```json
{
  "mcpServers": {
    "tmux": {
      "command": "/path/to/.build/debug/libtmux-mcp",
      "env": {
        "LIBTMUX_SOCKET": "default",
        "LIBTMUX_TMUX_BIN": "tmux"
      }
    }
  }
}
```

| Variable | Default | What it selects |
| --- | --- | --- |
| `LIBTMUX_SOCKET` | `libtmux-mcp` | The socket *name*, resolved inside `TMUX_TMPDIR` |
| `LIBTMUX_SOCKET_PATH` | none | An absolute socket path; mutually exclusive with `LIBTMUX_SOCKET` |
| `LIBTMUX_TMUX_CONFIG` | bundled minimal config on the default socket | An absolute tmux configuration path |
| `LIBTMUX_TMUX_BIN` | `tmux` | The tmux to run — a bare name is resolved on `PATH`, or give a path |
| `LIBTMUX_TOOLSETS` | `inspect,manage,execute` | Any comma-separated combination of `inspect`, `manage`, `execute`, and `teardown`; empty selects none |
| `LIBTMUX_TOOLS` | none | Exact tool names added after toolset expansion |
| `LIBTMUX_EXCLUDE_TOOLS` | none | Exact tool names removed last, including aggregate authority |
| `LIBTMUX_MCP_WAIT_MAX_SECONDS` | `120` | The wait ceiling in seconds, clamped from 1 through 300 |
| `TMUX_TMPDIR` | tmux's own default | Where a socket name is looked up |

The default adds `teardown` only when the server retains this process's launch
nonce from the bundled minimal configuration. Existing servers and explicit
socket or configuration selections require an explicit `teardown` choice.
When stdio ends, the process removes only a default daemon whose launch nonce
and incarnation still match; existing and replacement daemons remain.

Use `LIBTMUX_TOOLSETS=inspect LIBTMUX_TOOLS=create_window` to expose the read
surface plus one named execute tool. Empty tokens and unknown tool or toolset
names fail startup before tmux opens. The retired `LIBTMUX_SAFETY` and
`LIBTMUX_MCP_TOOLS` names also fail with migration guidance.
Replace an old exact allowlist with `LIBTMUX_TOOLSETS=` and the same names in
`LIBTMUX_TOOLS`; without the empty toolset, named tools add to the default
surface.

Tool filtering is interface shaping, not authorization. Execute tools act with
the tmux user's authority, and a selected socket limits tmux object lookup
rather than operating-system access. The static `tmux://capabilities` resource
reports the startup-frozen socket provenance, common boundary fields, and
effective capability rows.

## Driving it by hand

Useful when a client is misbehaving and you want to know which side is wrong:

```console
$ printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"shell","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | .build/debug/libtmux-mcp
```

Anything the server wants to tell a human goes to stderr, because stdout is the
protocol and a stray line there corrupts the stream. On startup it names the
socket and the binary it resolved, which is usually enough to explain an empty
listing.

[MCP]: https://modelcontextprotocol.io
