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
| `LIBTMUX_SOCKET` | `default` | The socket *name*, resolved inside `TMUX_TMPDIR` |
| `LIBTMUX_TMUX_BIN` | `tmux` | The tmux to run — a bare name is resolved on `PATH`, or give a path |
| `TMUX_TMPDIR` | tmux's own default | Where a socket name is looked up |

All three are optional; with none set it serves the `default` socket through the
first `tmux` on `PATH`.

## Driving it by hand

Useful when a client is misbehaving and you want to know which side is wrong:

```console
$ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | .build/debug/libtmux-mcp
```

Anything the server wants to tell a human goes to stderr, because stdout is the
protocol and a stray line there corrupts the stream. On startup it names the
socket and the binary it resolved, which is usually enough to explain an empty
listing.

[MCP]: https://modelcontextprotocol.io
