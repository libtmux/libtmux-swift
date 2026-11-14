# MCP server behaviour

The detail behind the [`libtmux-mcp`](../Sources/libtmux-mcp/README.md) and
[`LibTmuxMCP`](../Sources/LibTmuxMCP/README.md) READMEs: what each guard checks,
and what a response is bounded by. Each tool's own contract is on its page at
[libtmux.org](https://libtmux.org/en/swift/latest/mcp/tools/).

**Contents** — [Default launch and teardown](#default-launch-and-teardown) ·
[Pane modes](#pane-modes) · [Pane input](#pane-input) ·
[paste_text and run_shell_command](#paste_text-and-run_shell_command) ·
[Capability metadata](#capability-metadata) · [select_layout](#select_layout) ·
[Output budgets and deadlines](#output-budgets-and-deadlines) ·
[The caller's own pane](#the-callers-own-pane) ·
[Migrating from the earlier MCP surface](#migrating-from-the-earlier-mcp-surface)

## Default launch and teardown

With neither `LIBTMUX_SOCKET_PATH` nor `LIBTMUX_SOCKET` set, the server passes
tmux no `-L` and no `-S`, and tmux picks the server: the one in `TMUX` when the
client that started the server runs inside tmux, and its default socket
otherwise. The server starts no daemon of its own and loads no configuration of
its own, so a launch that finds no server reports `serverState` `absent` and
starts none.

`LIBTMUX_SOCKET_PATH` is passed as `-S` and `LIBTMUX_SOCKET` as `-L`. When both
are set the path wins and the name is ignored, without an error. A variable
that is empty or only whitespace counts as unset, each one on its own, so a
blank path leaves a set name in force. The path has to be absolute; the refusal
names the variable and never its value.

`tmux://capabilities` reports what chose the socket as `socket-path`,
`socket-name` or `tmux-choice`, in `socketProvenance`. A `tmux-choice` launch
reports the socket it reached in `resolvedSocketPath` once a server is running
there, and an empty string until then. Its `attachCommand` names that socket
with `-S`, because the shell it is pasted into may hold another `TMUX`, and
names none until a server runs.

No launch adds `teardown`. Unknown names and empty list tokens fail before the
socket is opened. When stdio ends, the process exits and leaves the server as it
found it.

## Pane modes

Pane modes remain human-client state, not MCP automation state. Read bounded
scrollback with `capture_pane` and its `start`/`end` range, use `search_panes`
to discover matching output, or use `snapshot_pane` when one MCP response should
contain both pane metadata and bounded content; the metadata and capture are
separate reads, not an atomic snapshot.

Carry the opaque `capture_since` cursor across turns for new output. If a pane
is already in a human-owned mode, read `pane_in_mode` or `pane_mode` through
`get_tmux_variables`, report it, and leave entry or cancellation to the client
that owns the interaction.

## Pane input

Pane input reads fresh typed death, mode-count, effective synchronization,
caller, and terminal-attendance state. Missing, malformed, or inconsistent
caller/client context fails closed. A zoomed terminal client protects its active
pane; an unzoomed terminal client protects every pane in its active window.

Control clients do not count. `send_keys` checks every configured member of the
effective synchronized cohort; `send_keys_batch` repeats that check for every
executed row.

Returned pane IDs describe configured membership, not proof of delivery, and the
checks remain observational because tmux state can change after a snapshot. A
process-wide reservation protects every configured member through dispatch, so
pane input refuses overlap with an active run or other input.

With [`send_keys`], `force=true` bypasses only an exact caller-pane match; it
never bypasses attendance, active-operation, mode, death, shell, or target-count
checks. The `resolvedPaneIds` it returns are the checked configuration, not an
attestation that tmux delivered bytes to every member.

## paste_text and run_shell_command

[`paste_text`] checks its target before staging and immediately before its one
paste dispatch. It keeps non-empty text and its optional Enter target-only in
one private buffer and removes the buffer on every path. Empty text without
Enter still performs its initial safety check, then returns without creating a
buffer or dispatching input.

[`run_shell_command`] checks before setup and again before dispatch, and refuses
a second run instead of waiting. It requires one configured pane running a
recognized POSIX shell, pins the selected tmux executable and socket route, and
runs the command in a subshell, so `cd`, variables, traps, syntax errors, and
`exit` cannot alter or end the interactive parent.

Those guarantees assume the selected shell, tmux daemon, and configuration are
trusted; they do not claim containment against a hostile shell environment.
`force=true` bypasses only an exact caller-pane match; it never bypasses
attendance, active-operation, mode, death, shell, or target-count checks.

## Capability metadata

Every tool declares native input and output schemas and carries its complete
capability row under `_meta["com.git-pull.libtmux-mcp/capability"]`. The same
immutable registry drives registration, dispatch, descriptions, filtering, and
the [`tmux://capabilities`][ref-mcp-capabilities] report.

That static report is the only MCP resource; the server exposes no prompts or
dynamic templates.

The rows disclose process reach, tmux effects, output classes, one
`inputLiteralization` map, and conservative MCP annotations. Detailed input sink
tables remain internal validation data. The rows are consent metadata, not a
security boundary.

Terminal content, environment values, configured commands, and tmux metadata may
contain secrets or untrusted instructions.

The report marks itself frozen and carries the common execution boundary and
connection-provenance objects.

Hierarchy rows carry opaque references for follow-up reads. They bind the row to
the current tmux daemon and expire when the MCP process restarts; re-list to
replace one that has expired. Exact window occurrences carry both a global
`windowRef` and session-local `linkRef`.

## select_layout

[`select_layout`] accepts named layouts, unique abbreviations for the running
daemon's version, and checksummed saved layouts, plus a JSON layout document on
tmux 3.8 and later. It checks syntax before window lookup, then uses the core
mutation's captured-window guard on the selected transport. tmux owns geometry
and pruning. The result's `layout` field echoes the accepted input.

## Output budgets and deadlines

**Waits have deadlines.** Every wait is clamped to a ceiling and reports what
was actually enforced. Requests are served concurrently, so a thirty-second wait
does not hold up the `ping` beside it, and `notifications/cancelled` stops one
that the client has stopped caring about.

`wait_for_text` and `wait_for_channel` expose the two blocking operations
through bounded calls.

**`wait_for_text` streams from tmux 3.7 and polls below it.** From 3.7 it reads
pane output over a control client. On 3.3a through 3.6 it attaches no control
client and reads the screen on a timer, so output that changes no row, such as
a line of only blanks, is not seen. Both paths end in one of these outcomes,
or in an error. A connection that drops while the pane lives is
re-attached first; if that fails, the wait raises the error instead, such as
`connectionClosed`, and an error is not an outcome.

| `outcome` | Meaning |
| --- | --- |
| `matched` | A pattern appeared in output that arrived during the wait. |
| `stopped` | A `stop` pattern appeared first. |
| `timedOut` | Nothing matched before the deadline, in reads that finished. |
| `expiredWhileReading` | The deadline arrived while a read was in flight; retry with a longer timeout. |
| `paneClosed` | The pane, or the server, went away; `tail` holds the output seen so far. |
| `alternateScreen` | A full-screen program owned the pane, so matching was suppressed; use `capture_pane`. |

**It will not spend context you did not ask it to.** Pane reads collect at most
262,144 bytes per stream and return at most 128,000 UTF-8 bytes in whole rows;
they say when older output was omitted. `run_shell_command` returns only what
that command printed, not its echoed wrapper or the shell prompt.

`capture_since` returns a cursor, so watching something across turns sends the
difference rather than the screen. `call_read_tools_batch` retains complete
nested envelopes where they fit, marks each elided result, reports aggregate
success, failure, stop, and truncation totals, and keeps the complete
newline-delimited response at or below 1,000,000 bytes.

A request ID that cannot fit inside that ceiling receives a bounded `id: null`
invalid-request response before any tool runs.

`search_panes` scans at most 200 panes, 20,000 lines, 1,000,000 bytes, or five
seconds, and reports which ceiling truncated the search.

**Long waits report life signs.** When a client sends a `progressToken`, a long
wait sends advisory progress while output has capacity. Final answers and
protocol errors take priority when the client stops draining output.

## The caller's own pane

**It will not end the conversation.** When the server runs inside the selected
tmux it knows which pane is its own. Direct teardown tools refuse that pane,
window, or session unless the call explicitly passes `force`. The guard does not
claim to constrain equivalent commands sent through an execute tool.

## Migrating from the earlier MCP surface

Earlier alpha releases used ordered safety tiers and different tool names.
None of these names exists in the current tool registry:

| Earlier name or URI | Current path |
| --- | --- |
| `enter_copy_mode`, `exit_copy_mode` | No MCP replacement. Read history through [`capture_pane`], locate output with [`search_panes`], continue with [`capture_since`], and leave human-owned pane modes unchanged. Applications that own pane state can use the core library's `enterCopyMode` and `cancelModes` APIs. |
| `LIBTMUX_SAFETY` | Use `LIBTMUX_TOOLSETS`; any present legacy value stops startup. |
| `LIBTMUX_MCP_TOOLS` | Use `LIBTMUX_TOOLSETS=` with `LIBTMUX_TOOLS` to preserve its exact allowlist; any present legacy value stops startup. |
| `tmux://snapshot` | Compose [`list_sessions`], [`list_windows`], [`list_panes`], and [`snapshot_pane`]. |
| `tmux://sessions` | Use `list_sessions`. |
| `tmux://filters` | Read native input schemas from `tmux://capabilities` and filter bounded listings client-side. |
| `tmux://sessions/{session}/windows` | Use `list_windows` with the session reference. |
| `tmux://panes/{pane}` | Use [`get_pane_info`] with the pane reference. |
| `tmux://panes/{pane}/content` | Use `capture_pane` for a bounded slice, `snapshot_pane` for metadata and content, or `capture_since` to continue across turns. |
| `describe_server` | Use [`get_server_info`]; `list_panes` also marks the caller pane. |
| `list_servers` | No discovery route; pin one socket per process and run another process for another socket. |
| `describe_filters` | No separate route; read the published input schemas and filter bounded listings client-side. |
| `snapshot` | Compose `list_sessions`, `list_windows`, `list_panes`, and `snapshot_pane`; the capability report carries frozen connection provenance. |
| `read_format` | Use [`get_tmux_variables`] for validated names; arbitrary tmux formats have no replacement. |
| `show_options` | Use [`show_option`] for one named option. |
| `run_shell` | Use [`run_shell_command`]; it remains synchronous and bounded. |
| `wait_for_output` | Use [`wait_for_text`]. |
| `watch_format` | No format subscription; use `capture_since`, `wait_for_text`, or a typed metadata read. |
| `new_session`, `new_window`, `split_pane` | Use [`create_session`], [`create_window`], and [`split_window`]. |
| `rename`, `select` | Use the session/window and pane/window variants, such as [`rename_session`] and [`select_pane`]. |
| `set_option` | Use [`set_mouse_enabled`], [`set_history_limit`], [`set_synchronize_panes`], or [`set_pane_title`]; there is no generic setter. |
| `set_environment` | No public process-environment mutation route. |
| `apply_workspace` | Compose create, split, layout, title, selection, and execution tools explicitly. |
| `kill_server` | No server-wide teardown route; kill selected sessions or administer tmux outside MCP. |
| `run_command`, `run_commands` | No raw tmux-command interpreter; call the typed tools instead. |

The removed prompts remain useful as typed-tool workflows:

| Earlier prompt | Current typed workflow |
| --- | --- |
| `run_and_wait` | Call `run_shell_command` and read its framed exit status and bounded output instead of polling the pane. |
| `watch_until_ready` | Call `wait_for_text` with ready and stop patterns; carry a `capture_since` cursor when following output across turns. |
| `build_workspace` | Compose `create_session`, `create_window`, `split_window`, layout, title, selection, and execution calls. |
| `find_my_pane` | Call `get_server_info`, then use the `isCaller` marker from `list_panes` before changing topology. |

[ref-mcp-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
[`capture_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_pane/
[`capture_since`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_since/
[`create_session`]: https://libtmux.org/en/swift/latest/mcp/tools/create_session/
[`create_window`]: https://libtmux.org/en/swift/latest/mcp/tools/create_window/
[`get_pane_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_pane_info/
[`get_server_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_server_info/
[`get_tmux_variables`]: https://libtmux.org/en/swift/latest/mcp/tools/get_tmux_variables/
[`list_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/list_panes/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
[`list_windows`]: https://libtmux.org/en/swift/latest/mcp/tools/list_windows/
[`paste_text`]: https://libtmux.org/en/swift/latest/mcp/tools/paste_text/
[`rename_session`]: https://libtmux.org/en/swift/latest/mcp/tools/rename_session/
[`run_shell_command`]: https://libtmux.org/en/swift/latest/mcp/tools/run_shell_command/
[`search_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/search_panes/
[`select_layout`]: https://libtmux.org/en/swift/latest/mcp/tools/select_layout/
[`select_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/select_pane/
[`send_keys`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys/
[`set_history_limit`]: https://libtmux.org/en/swift/latest/mcp/tools/set_history_limit/
[`set_mouse_enabled`]: https://libtmux.org/en/swift/latest/mcp/tools/set_mouse_enabled/
[`set_pane_title`]: https://libtmux.org/en/swift/latest/mcp/tools/set_pane_title/
[`set_synchronize_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/set_synchronize_panes/
[`show_option`]: https://libtmux.org/en/swift/latest/mcp/tools/show_option/
[`snapshot_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/snapshot_pane/
[`split_window`]: https://libtmux.org/en/swift/latest/mcp/tools/split_window/
[`wait_for_text`]: https://libtmux.org/en/swift/latest/mcp/tools/wait_for_text/
