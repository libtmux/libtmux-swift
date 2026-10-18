<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/mcp.svg" type="image/svg+xml">
    <img src="../../assets/mcp.png" width="128" height="128" alt="libtmux for Swift MCP">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# `libtmux-mcp`

A [Model Context Protocol][MCP] server for tmux. It speaks JSON-RPC 2.0 over
stdio, one message per line, so anything that launches an MCP server can drive
tmux through it.

</div>

The tools it serves are [`LibTmuxMCP`](../LibTmuxMCP); this is the executable
that answers for them. Tool names below link to their pages on libtmux.org.

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

The configured default exposes 41 of the 45 tools. An authenticated default
daemon adds the four `teardown` tools; [`TmuxTools(server:)`][api-tmuxtools]
remains the 18-tool inspect-only embedding default.

Use `LIBTMUX_TOOLSETS=inspect LIBTMUX_TOOLS=create_window` to expose the read
surface plus one named execute tool, [`create_window`]. Empty tokens and unknown
tool or toolset names fail startup before tmux opens. The retired
`LIBTMUX_SAFETY` and `LIBTMUX_MCP_TOOLS` names also fail with migration
guidance. Replace an old exact allowlist with `LIBTMUX_TOOLSETS=` and the same
names in `LIBTMUX_TOOLS`; without the empty toolset, named tools add to the
default surface.

Tool filtering is interface shaping, not authorization. Execute tools act with
the tmux user's authority, and a selected socket limits tmux object lookup
rather than operating-system access. The static
[`tmux://capabilities`][ref-capabilities] resource reports the startup-frozen
socket provenance, common boundary fields, and effective capability rows.

## Register it with a client

Claude Code takes the server and its environment on one command line. This
limits it to the `inspect` toolset:

```console
$ claude mcp add tmux \
    -e LIBTMUX_TOOLSETS=inspect \
    -- /path/to/.build/debug/libtmux-mcp
```

To serve the socket that `tmux-workspace load -L project` built, name it:

```console
$ claude mcp add tmux \
    -e LIBTMUX_SOCKET=project \
    -e LIBTMUX_TOOLSETS=inspect \
    -- /path/to/.build/debug/libtmux-mcp
```

An empty `LIBTMUX_TOOLSETS` plus `LIBTMUX_TOOLS` serves exactly the tools
named, here [`list_sessions`] and [`capture_pane`]:

```console
$ claude mcp add tmux \
    -e LIBTMUX_TOOLSETS= \
    -e LIBTMUX_TOOLS=list_sessions,capture_pane \
    -- /path/to/.build/debug/libtmux-mcp
```

`LIBTMUX_EXCLUDE_TOOLS` removes names from whatever the toolsets selected, here
[`send_keys`] and [`send_keys_batch`] from the default:

```console
$ claude mcp add tmux \
    -e LIBTMUX_EXCLUDE_TOOLS=send_keys,send_keys_batch \
    -- /path/to/.build/debug/libtmux-mcp
```

The test suite parses every `LIBTMUX_` setting in these commands and in the JSON
configurations through the same code the executable runs at startup, so a
renamed variable or an unknown tool name fails there. The
[client guide][ref-guide] walks through a private tmux server end to end.

## Toolsets

`LIBTMUX_TOOLSETS` selects groups of tools. Each name links to its page on
libtmux.org, and the [tool index][ref-tools] lists them all.

| Toolset | What it does | Tools |
| --- | --- | --- |
| `inspect` | Reads bounded state | [`call_read_tools_batch`] [`capture_pane`] [`capture_since`] [`find_pane_by_position`] [`get_pane_info`] [`get_server_info`] [`get_session_info`] [`get_tmux_variables`] [`get_window_info`] [`list_panes`] [`list_sessions`] [`list_windows`] [`search_panes`] [`show_environment`] [`show_hooks`] [`show_option`] [`snapshot_pane`] [`wait_for_text`] |
| `manage` | Changes tmux objects | [`move_window`] [`rename_session`] [`rename_window`] [`resize_pane`] [`resize_window`] [`select_layout`] [`select_pane`] [`select_window`] [`set_history_limit`] [`set_mouse_enabled`] [`set_pane_title`] [`signal_channel`] [`swap_pane`] [`wait_for_channel`] |
| `execute` | Starts or drives pane processes | [`create_session`] [`create_window`] [`paste_text`] [`respawn_pane`] [`run_shell_command`] [`send_keys`] [`send_keys_batch`] [`set_synchronize_panes`] [`split_window`] |
| `teardown` | Deletes tmux state | [`clear_pane_scrollback`] [`kill_pane`] [`kill_session`] [`kill_window`] |

The default selects `inspect`, `manage`, and `execute`; `teardown` joins only
for a default daemon this process launched. Grant `execute` only to clients
trusted to act as the tmux user; [toolset selection][ref-topics] covers the
rest.

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

## Reference

- [MCP overview][ref-mcp]: running the executable or embedding the tools
- [Connect a client][ref-guide] and [select toolsets][ref-topics]
- [Tool pages][ref-tools], one per tool, and the
  [`tmux://capabilities`][ref-capabilities] resource
- [API pages][ref-reference] for the embedding types, and
  [Swift Package Index][spi-mcp]

[MCP]: https://modelcontextprotocol.io
[ref-mcp]: https://libtmux.org/en/swift/latest/mcp/
[ref-guide]: https://libtmux.org/en/swift/latest/mcp/guides/
[ref-topics]: https://libtmux.org/en/swift/latest/mcp/topics/
[ref-tools]: https://libtmux.org/en/swift/latest/mcp/tools/
[ref-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
[ref-reference]: https://libtmux.org/en/swift/latest/mcp/reference/
[api-tmuxtools]: https://libtmux.org/en/swift/latest/mcp/reference/tmuxtools/
[spi-mcp]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmuxmcp
[`call_read_tools_batch`]: https://libtmux.org/en/swift/latest/mcp/tools/call_read_tools_batch/
[`capture_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_pane/
[`capture_since`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_since/
[`find_pane_by_position`]: https://libtmux.org/en/swift/latest/mcp/tools/find_pane_by_position/
[`get_pane_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_pane_info/
[`get_server_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_server_info/
[`get_session_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_session_info/
[`get_tmux_variables`]: https://libtmux.org/en/swift/latest/mcp/tools/get_tmux_variables/
[`get_window_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_window_info/
[`list_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/list_panes/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
[`list_windows`]: https://libtmux.org/en/swift/latest/mcp/tools/list_windows/
[`search_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/search_panes/
[`show_environment`]: https://libtmux.org/en/swift/latest/mcp/tools/show_environment/
[`show_hooks`]: https://libtmux.org/en/swift/latest/mcp/tools/show_hooks/
[`show_option`]: https://libtmux.org/en/swift/latest/mcp/tools/show_option/
[`snapshot_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/snapshot_pane/
[`wait_for_text`]: https://libtmux.org/en/swift/latest/mcp/tools/wait_for_text/
[`move_window`]: https://libtmux.org/en/swift/latest/mcp/tools/move_window/
[`rename_session`]: https://libtmux.org/en/swift/latest/mcp/tools/rename_session/
[`rename_window`]: https://libtmux.org/en/swift/latest/mcp/tools/rename_window/
[`resize_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/resize_pane/
[`resize_window`]: https://libtmux.org/en/swift/latest/mcp/tools/resize_window/
[`select_layout`]: https://libtmux.org/en/swift/latest/mcp/tools/select_layout/
[`select_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/select_pane/
[`select_window`]: https://libtmux.org/en/swift/latest/mcp/tools/select_window/
[`set_history_limit`]: https://libtmux.org/en/swift/latest/mcp/tools/set_history_limit/
[`set_mouse_enabled`]: https://libtmux.org/en/swift/latest/mcp/tools/set_mouse_enabled/
[`set_pane_title`]: https://libtmux.org/en/swift/latest/mcp/tools/set_pane_title/
[`signal_channel`]: https://libtmux.org/en/swift/latest/mcp/tools/signal_channel/
[`swap_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/swap_pane/
[`wait_for_channel`]: https://libtmux.org/en/swift/latest/mcp/tools/wait_for_channel/
[`create_session`]: https://libtmux.org/en/swift/latest/mcp/tools/create_session/
[`create_window`]: https://libtmux.org/en/swift/latest/mcp/tools/create_window/
[`paste_text`]: https://libtmux.org/en/swift/latest/mcp/tools/paste_text/
[`respawn_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/respawn_pane/
[`run_shell_command`]: https://libtmux.org/en/swift/latest/mcp/tools/run_shell_command/
[`send_keys`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys/
[`send_keys_batch`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys_batch/
[`set_synchronize_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/set_synchronize_panes/
[`split_window`]: https://libtmux.org/en/swift/latest/mcp/tools/split_window/
[`clear_pane_scrollback`]: https://libtmux.org/en/swift/latest/mcp/tools/clear_pane_scrollback/
[`kill_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/kill_pane/
[`kill_session`]: https://libtmux.org/en/swift/latest/mcp/tools/kill_session/
[`kill_window`]: https://libtmux.org/en/swift/latest/mcp/tools/kill_window/
