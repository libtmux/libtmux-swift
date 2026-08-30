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
| `LIBTMUX_SOCKET_PATH` | none | An exact socket path, which takes precedence over `LIBTMUX_SOCKET` |
| `LIBTMUX_TMUX_BIN` | `tmux` | The tmux to run — a bare name is resolved on `PATH`, or give a path |
| `LIBTMUX_SAFETY` | `readonly` | The highest tool tier; set `mutating` or `destructive` to opt in to writes |
| `LIBTMUX_MCP_TOOLS` | all within the tier | A comma-separated exact tool allowlist, intersected with `LIBTMUX_SAFETY` |
| `LIBTMUX_MCP_WAIT_MAX_SECONDS` | `120` | The wait ceiling in seconds, clamped from 1 through 300 |
| `TMUX_TMPDIR` | tmux's own default | Where a socket name is looked up |

The tiers classify tool intent; they do not sandbox the host. `mutating`
exposes `run_shell` and `send_keys`, which can execute commands through a pane.
Grant it only to clients trusted to act as the tmux user.

Use `LIBTMUX_MCP_TOOLS=new_window,list_sessions` to expose only those tools.
An unknown or malformed name serves no tools and reports the problem on stderr.

All seven are optional; with none set it serves readonly tools for the `default`
socket through the first `tmux` on `PATH`, with a 120-second wait ceiling.

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
