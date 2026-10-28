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
[The caller's own pane](#the-callers-own-pane)

## Default launch and teardown

The default launch uses the dedicated `libtmux-mcp` socket and minimal config.
It adds teardown only when the daemon retains this process's launch nonce from
that config. Explicit sockets, explicit configs, and existing daemons never gain
implicit teardown authority.

Unknown names and empty list tokens fail before the socket is opened. When stdio
ends, the process removes only the default daemon whose launch nonce and
incarnation still match; existing and replacement daemons remain.

The default adds `teardown` only when the server retains this process's launch
nonce from the bundled minimal configuration. Existing servers and explicit
socket or configuration selections require an explicit `teardown` choice.

When stdio ends, the process removes only a default daemon whose launch nonce
and incarnation still match; existing and replacement daemons remain.

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

Pane-input tools read fresh typed pane state and refuse dead panes, nonzero mode
stacks, incomplete or malformed caller context, and terminal-attended panes. A
zoomed terminal client protects its active pane; an unzoomed terminal client
protects every pane in its active window. Control clients do not count.

`force=true` bypasses only an exact caller-pane match; it never bypasses
attendance, active-operation, mode, death, shell, or target-count checks.
[`send_keys`] derives effective synchronized membership from each pane's
configured value and reserves every configured member through dispatch.

Its `resolvedPaneIds` are the checked configuration, not an attestation that
tmux delivered bytes to every member. Batch rows are checked individually, and
every check remains observational rather than atomic.

## paste_text and run_shell_command

`paste_text` checks its target before staging and immediately before its one
paste dispatch. It keeps non-empty text and its optional Enter target-only in
one private buffer and removes the buffer on every path. Empty text without
Enter still performs its initial safety check, then returns without creating a
buffer or dispatching input.

`run_shell_command` checks before setup and again before dispatch, refuses a
second run instead of waiting, requires a single configured pane running a
recognized POSIX shell, and contains the command in a subshell so it cannot
leave shell state behind.

Those guarantees assume the selected shell, tmux daemon, and configuration are
trusted; they do not claim containment against a hostile shell environment.
`force=true` bypasses only an exact caller-pane match; it never bypasses
attendance, active-operation, mode, death, shell, or target-count checks.

[`paste_text`] checks the target before staging and again immediately before its
one paste dispatch. It puts non-empty text and its optional newline in one
private, target-only buffer, then removes the buffer on success or failure.
Empty text without Enter still performs the initial guard, then returns without
a buffer or input dispatch.

[`run_shell_command`] likewise checks exactly before setup and before dispatch,
and a second run refuses instead of waiting.

It requires one configured target running a recognized POSIX shell, pins the
selected tmux executable and socket route, and isolates the command in a
subshell so `cd`, variables, traps, syntax errors, and `exit` do not alter or
terminate the interactive parent.

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

`CapabilityResources` publishes that same frozen surface at
[`tmux://capabilities`][ref-capabilities]. Tool registration metadata and the
resource use the same complete capability rows. The report also marks itself
frozen and carries the common execution boundary and connection-provenance
objects.

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

[`paste_text`]: https://libtmux.org/en/swift/latest/mcp/tools/paste_text/
[`run_shell_command`]: https://libtmux.org/en/swift/latest/mcp/tools/run_shell_command/
[`select_layout`]: https://libtmux.org/en/swift/latest/mcp/tools/select_layout/
[`send_keys`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys/
[ref-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
[ref-mcp-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
