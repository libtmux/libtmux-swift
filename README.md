# libtmux for Swift

[![ci](https://github.com/libtmux/libtmux-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-swift/actions/workflows/ci.yml)
[![macos](https://github.com/libtmux/libtmux-swift/actions/workflows/macos.yml/badge.svg)](https://github.com/libtmux/libtmux-swift/actions/workflows/macos.yml)

Drive tmux from Swift. A port of [libtmux][] for Python, in the same family of
ports and holding to what that library established about tmux.

With tmux already running on its default socket:

```swift
import LibTmux

let server = try Server(socketName: "default")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

You address a server, ask it what exists, and send it commands. Everything that
comes back is a value — a `Session` you hold is what the server looked like when
you asked, not a live handle that changes under you. Ask again for a newer view.

> [!WARNING]
> **Alpha.** Releases carry an `-alpha` prerelease tag. The API is not
> settled, and any release may change or remove exported identifiers without a
> deprecation period. Pin an exact version. Not recommended for production.
> See [Project status](#project-status).

**Contents** — [Is this for you?](#is-this-for-you) ·
[Products](#products) · [Install](#install) · [Asking](#ask-what-is-there) ·
[Changing](#change-what-is-there) · [Filtering](#filters-that-travel) ·
[Modes](#one-switch-changes-how-work-reaches-tmux) ·
[Workspaces](#workspaces-from-a-file-or-from-swift) ·
[MCP](#tmux-as-mcp-tools) · [Status](#project-status) ·
[Docs](#documentation) · [Tests](#tests)

## Is this for you?

**Yes, if** you are writing a tool that drives tmux — a session manager, a test
harness, a dashboard, an agent that needs somewhere to run things — and you want
tmux's own vocabulary rather than a wrapper around shelling out.

**Yes, if** you care that `Session`, `Window`, `Pane`, and `Client` are
`Sendable` and `Codable` values, that core tmux I/O reports `TmuxError`
explicitly, and that the package builds under Swift 6 language mode with
complete strict concurrency and no unsafe flags.

**Not yet, if** you need a stable API. Every release so far is an alpha and
names are still moving — see [Project status](#project-status).

**No, if** you want to render or emulate a terminal. This talks to tmux; it does
not draw one.

## Products

Five things ship from this one package. Take only what you need — the core has
one dependency, and the YAML reader is behind a trait so you do not pay for it
unless you ask.

| Product | Source | What it is for | Depends on |
| --- | --- | --- | --- |
| **[`LibTmux`][p-lib]** | [`Sources/LibTmux/`][p-lib] | The library. Servers, sessions, windows, panes, options, hooks, filtering, snapshots, streaming. The only one most callers need. | [swift-subprocess][] |
| **[`TmuxWorkspace`][p-ws]** | [`Sources/TmuxWorkspace/`][p-ws] | Builds a session from a [tmuxp][] workspace — written in Swift, JSON, or YAML. See [Workspaces](#workspaces-from-a-file-or-from-swift). | `LibTmux`, and [Yams][] with the `YAMLWorkspaces` trait |
| **[`LibTmuxMCP`][p-mcp]** | [`Sources/LibTmuxMCP/`][p-mcp] | tmux as [MCP][] tools, as a library you can embed. | `LibTmux`, `TmuxWorkspace` |
| **[`libtmux-mcp`][p-server]** | [`Sources/libtmux-mcp/`][p-server] | The MCP server executable that serves those tools over stdio. See [tmux as MCP tools](#tmux-as-mcp-tools). | `LibTmux`, `LibTmuxMCP` |
| **[`TmuxFixture`][p-test]** | [`Tests/TmuxFixture/`][p-test] | Real-server provisioning and reaping for tests and benchmarks. | `LibTmux` |

Each has its own README with an install snippet, a usage example, and what it
does and does not cover.

`TmuxWorkspace` and `LibTmuxMCP` are both written against `Server` and
neither mentions a mode, which is how the mode switch below is kept honest.

## Install

Every tag until `0.1.0` is a prerelease, and a prerelease has to be named
exactly. `from: "0.1.0"` matches none of them — SwiftPM keeps prereleases out
of a range whose bound has none — and `from: "0.1.0-alpha.3"` errs the other
way, resolving forward into `0.2.0-alpha.1` and every prerelease after it.
Neither is what you want from alpha software, so name an exact release:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.3"
)
```

```swift
.product(name: "LibTmux", package: "libtmux-swift")
```

> [!NOTE]
> This page documents unreleased `master`. The exact dependency above installs
> the released alpha.3 API; [read that tag's README][alpha3-readme] for matching
> examples. To compile the examples on this page, depend on `master`:

```swift
.package(url: "https://github.com/libtmux/libtmux-swift.git", branch: "master")
```

Reading a workspace from YAML needs a YAML parser, and asking for it is what
pulls one in. Without the `YAMLWorkspaces` trait nothing here resolves Yams;
with it, `Workspace.decode(yaml:)` exists:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.3",
    traits: ["YAMLWorkspaces"]
)
```

## Ask what is there

Three listings, each returning plain arrays of values:

```swift
let sessions = try await server.sessions()
let windows = try await server.windows()
let panes = try await server.panes()
```

A pane knows what is running in it and where:

```swift
for pane in try await server.panes() {
    print(pane.id, pane.currentCommand, pane.currentPath)
}
```

Questions tmux answers with an exit code are answered here with a `Bool`:

```swift
guard try await server.hasSession("work") else { return }
```

And anything this library does not model is one step away, in either mode. A
tmux command that runs and reports a nonzero status is a *reply*, not an error —
`has-session` answers a question that way, so `run(_:)` hands back both rather
than throwing:

```swift
let reply = try await server.run(
    TmuxCommand("display-message", ["-p", "#{client_termname}"])
)
print(reply.isSuccess ? reply.text : reply.errorText)
```

### Snapshots

`snapshot()` collects sessions, windows, panes, and clients into one value. The
relationships resolve inside that value rather than by matching ids yourself:

```swift
let snapshot = try await server.snapshot()
for window in snapshot.windows(of: session) {
    print(window.name, snapshot.panes(of: window).count)
}
```

The listings are separate tmux commands. `snapshot()` checks the daemon
incarnation before and after them and reports a replacement, but another client
can still mutate the same daemon between listings. The result is not a tmux
transaction.

## Change what is there

```swift
let session = try await server.newSession(named: "work", windowName: "editor")
_ = try await server.setOption("@purpose", to: "development", scope: .session(session))
let logs = try await server.newWindow(in: session, named: "logs").window
let pane = try await server.splitWindow(logs, direction: .right)
try await server.run("tail -f /tmp/build.log", in: pane)
```

Read a pane back the way a person would:

```swift
let lines = try await server.capture(pane)
```

When several changes belong together, a command list spends one tmux invocation
on all of them instead of one each:

```swift
var plan = TmuxCommandList()
for name in ["edit", "test", "logs"] {
    plan = plan.then("new-window", ["-d", "-n", name])
}
_ = try await server.run(plan)
```

## Filters that travel

Filter with the standard library when the predicate is local to your code.
`FilterExpr` is for when the filter has to leave it — stored in a config, sent to
another process, handed to a tool. It is built from key paths, so the compiler
rejects a text operator on a number, and it holds no closures, so it encodes:

```swift
let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
let matching = try await server.panes().filter(expression)
```

This is what lets the [MCP tools](#tmux-as-mcp-tools) offer filtering to a
client that does not speak Swift. The full vocabulary — operators, aliases, and
which fields carry which type — is in [`Filtering.md`][filtering].

## One switch changes how work reaches tmux

…and never what you get back. `TmuxMode` is the dial, and it has two settings:

| Mode | How work travels | Where it wins |
| --- | --- | --- |
| `.direct` | A tmux process per call | One call, or calls far apart. The default |
| `.connected(to:)` | One live connection for the whole scope | More than one call, and being told what changed |

The default needs no word at all:

```swift
let sessions = try await server.sessions()
```

Each other mode adds one:

```swift
let names = try await server.using(.connected(to: "main")) { server in
    try await server.sessions().map(\.name)
}
```

The calls inside are the same calls and return the same types. Because the mode
is a value rather than a shape of call, a program that decides at runtime writes
the decision:

```swift
let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
let sessions = try await server.using(mode) { server in
    try await server.sessions()
}
```

### Which server is in which mode, in order of precedence

1. **The value you were handed.** `using(_:)` and `connected(attachingTo:_:)`
   give you a server in that mode, and nesting them takes the innermost —
   `using(.direct)` inside a connected scope keeps one call off the connection.
2. **Anything else is `.direct`**, including a server captured from outside the
   closure.
3. **Two calls take their own process regardless** — `wait(for:)`, which would
   otherwise deadlock the scope, and `buffer(named:)`, whose bytes a connection
   cannot report unambiguously. Both do it so that what comes back does not
   depend on the mode.

Nothing is global and nothing is inherited by a task. `server.mode` reports
which mode a value carries, so the rule can be read rather than trusted.

### What it costs

`swift run --package-path Benchmarks libtmux-bench` runs each scenario under
each mode behind a shim standing in for the tmux binary, counting a process
every time one starts and a round trip every time a command line is handed over.
The table below is written by that benchmark rather than transcribed from it —
`Scripts/update_mode_matrix.py --check` fails if it has drifted, and CI runs
that check.

<!-- mode-matrix:start -->

<!-- generated by `swift run --package-path Benchmarks libtmux-bench --markdown`; do not edit -->

| Work | Direct | Connected |
| --- | --- | --- |
| list-sessions, once | 1 process, 1 round trip | 1 process, 2 round trips |
| list-sessions, twenty times | 20 processes, 20 round trips | 1 process, 21 round trips |
| sessions, windows, panes, clients, twice-checked | 6 processes, 6 round trips | 1 process, 7 round trips |
| sessions, windows, panes, clients — one after another | 4 processes, 4 round trips | 1 process, 5 round trips |
| the same four, concurrently — a pipelined batch | 4 processes, 4 round trips | 1 process, 5 round trips |
| new-window five times, each its own command | 7 processes, 7 round trips | 1 process, 8 round trips |
| the same five as one command list | 3 processes, 3 round trips | 1 process, 4 round trips |
| new-window then split, read back | 5 processes, 5 round trips | 1 process, 6 round trips |

| Noticing a pane printed a line | Polling | Streaming |
| --- | --- | --- |
| tmux processes spent | 2 | 1 |
| round trips spent | 2 | 2 |

<!-- mode-matrix:end -->

Directly, a round trip is a process, so that column always agrees with itself.
Connecting collapses the processes to one and charges a single extra round trip,
the attach — which is why a single call is the row where the default wins, and
why from the second call onward the connection is ahead. Round trips are also
where a command list shows up: under a connection it and the separate commands
cost the same one process, and only the round trips tell them apart.

The benchmark also prints wall-clock medians, which move with the machine — run
it yourself for those.

### Being told rather than asking

A connection can do one thing a process cannot, which is report what changed
without being asked:

```swift
let firstLine: String? = try await server.connected(attachingTo: "work") { server, events in
    for try await notification in events.notifications
    where notification.name == "output" {
        return notification.arguments
    }
    return nil
}
```

## Waiting without polling

tmux has no hook that fires when a pane prints something, so a wait built from
commands alone has to re-read the pane on a timer and spend a process per tick.
A control connection is told instead, and that makes three waits cheaper than
the loop everyone writes first. Reach for them in this order.

**You wrote the command.** Compose a channel into it: tmux blocks server-side
and returns on the signal itself, so nothing is inferred from what the screen
looks like.

```swift
try await server.run(
    "make; \(server.shellInvocation) wait-for -S built",
    in: pane
)
try await server.wait(for: "built")
```

**The question is about state.** Subscribe to a format and tmux reports each
time its value changes — no capture, no scrollback, no prompt regex.
`#{pane_current_command}` answers "is my command done?" exactly:

```swift
try await server.connected(attachingTo: "work") { server, control in
    try await control.watch(
        FormatSubscription(
            name: "cmd",
            scope: .pane(pane.id),
            format: "#{pane_current_command}"
        )
    )
    for try await change in control.changes(named: "cmd") {
        return change.value
    }
    return nil
}
```

**You did not write the command.** For a daemon printing `ready` or a dev
server someone else started, wait on the pane's output. `%output` wakes the
wait as the pane writes, and the matching runs against the rendered grid. A
small liveness check detects a pane removed while it is quiet:

```swift
let ready = try RegexPattern("Listening on")
let failed = try RegexPattern("EADDRINUSE|error", options: [.caseInsensitive])
let waited = try await server.waitForOutput(
    in: pane,
    matching: [ready],
    stoppingAt: [failed]
)
```

Pass `stops` whenever a failure marker exists — a build that fails after five
seconds should end the wait then, not hold it open to report the same failure
later.

The condition is checked before it is blocked on, the way any other wait on a
predicate works: text already on screen returns at once with
`matchedAtEntry: true`, because "wait until it is listening" is answered by
something already listening. Pass `requiringFreshOutput` when only a new
occurrence counts. When a wait does end without a match, the result says which
thing happened: `timedOut` with `sawNewOutput: false` means the pane stayed
quiet and no pattern will fix it, `timedOut` with output means `tail` holds what
actually arrived so the pattern can be fixed from that rather than from memory,
`expiredWhileReading` means the timeout ended before the pane could be read
at all, so nothing was established either way, and `alternateScreen` means a
pager, editor, or other full-screen program held the pane, which tmux fills
from a grid it keeps out of history — matching is suppressed there rather than
run against what the program painted.

The DocC catalogue's `Waiting` article covers why the output stream is a
doorbell rather than the text being matched.

## Workspaces, from a file or from Swift

`TmuxWorkspace` builds a whole session in one go, from a [tmuxp][] workspace.
Written in Swift, it is ordinary values:

```swift
let workspace = Workspace(
    sessionName: "work",
    windows: [
        WindowPlan(
            windowName: "editor",
            layout: "even-horizontal",
            panes: [PanePlan(), PanePlan()]
        ),
        WindowPlan(
            windowName: "logs",
            panes: [PanePlan(shellCommands: ["tail -f /tmp/build.log"])]
        ),
    ]
)
```

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

Building refuses rather than adopting a session that already has the name: two
callers building the same workspace should not silently share one. A later
failure removes the exact session this build created; a rollback failure
reports both errors.

JSON needs no trait, because tmuxp's keys decode straight into these types.
Reading the YAML that tmuxp files are usually written in needs a parser, which
is what the `YAMLWorkspaces` trait pulls in:

```swift
try Workspace.decode(yaml: text)
```

The fixtures the suite tests against are tmuxp's own examples, decoded both ways
and compared — a stronger claim than either parsing alone.

## tmux as MCP tools

`libtmux-mcp` is a [Model Context Protocol][MCP] server. It speaks JSON-RPC 2.0
over stdio, one message per line, so anything that launches an MCP server can
drive tmux through it.

```console
$ swift build --product libtmux-mcp
```

Point a client at the built binary. It takes no flags — which tmux it talks to
and which tools it exposes are fixed from its startup environment:

```json
{
  "mcpServers": {
    "tmux": {
      "command": "/path/to/.build/debug/libtmux-mcp",
      "env": {
        "LIBTMUX_SOCKET": "agent",
        "LIBTMUX_TOOLSETS": "inspect,manage,execute"
      }
    }
  }
}
```

| Variable | Default | What it selects |
| --- | --- | --- |
| `LIBTMUX_SOCKET` | `libtmux-mcp` | Plain tmux socket name |
| `LIBTMUX_SOCKET_PATH` | — | Absolute socket path, mutually exclusive with `LIBTMUX_SOCKET` |
| `LIBTMUX_TMUX_CONFIG` | bundled minimal config | Absolute tmux configuration path |
| `LIBTMUX_TOOLSETS` | depends on server provenance | Comma-separated subset of the four toolsets; empty selects none |
| `LIBTMUX_TOOLS` | empty | Exact names added after toolset expansion |
| `LIBTMUX_EXCLUDE_TOOLS` | empty | Exact names removed last, including nested authority |
| `LIBTMUX_TMUX_BIN` | `tmux` | The tmux to run — a bare name is resolved on `PATH`, or give a path |
| `LIBTMUX_MCP_WAIT_MAX_SECONDS` | `120` | The ceiling every wait is clamped to, itself capped at 300 |

The default launch uses the dedicated `libtmux-mcp` socket and minimal config.
It adds teardown only when the daemon retains this process's launch nonce from
that config. Explicit sockets, explicit configs, and existing daemons never
gain implicit teardown authority. Unknown names and empty list tokens fail
before the socket is opened. When stdio ends, the process removes only the
default daemon whose launch nonce and incarnation still match; existing and
replacement daemons remain.

Toolsets classify direct operations; they do not sandbox the host. `execute`
exposes `run_shell_command` and `send_keys`, which act with the tmux user's
authority. Grant it only to clients trusted to act as that user.

Anything the server wants to tell a human goes to stderr, because stdout is the
protocol and a stray line there corrupts it.

`LIBTMUX_SOCKET` is a name rather than a path, and tmux resolves a name inside
`TMUX_TMPDIR`. Set that in the same `env` block when your tmux keeps its sockets
somewhere other than the default, and the name will mean the same server to this
package that it means to you.

### The tools

The registry contains 45 tools: 18 `inspect`, 14 `manage`, nine `execute`, and
four `teardown`. A configured executable exposes the first three toolsets by
default (41 tools); an authenticated daemon started from the bundled minimal
configuration also receives `teardown` (45 tools).

| Tool | What it answers or does |
| --- | --- |
| `list_sessions` `list_windows` `list_panes` | Lists the objects on the selected socket |
| `get_server_info` `get_session_info` `get_window_info` `get_pane_info` | Returns one level's typed metadata |
| `capture_pane` `capture_since` `snapshot_pane` `search_panes` | Reads bounded terminal content |
| `find_pane_by_position` `wait_for_text` | Finds a pane or waits for bounded output |
| `get_tmux_variables` `show_option` `show_environment` `show_hooks` | Reads configuration and environment values |
| `call_read_tools_batch` | Runs up to 16 eligible inspect operations under one outer approval |
| `rename_session` `rename_window` `select_window` `select_pane` `select_layout` | Renames or selects tmux state |
| `resize_window` `resize_pane` `move_window` `swap_pane` `set_pane_title` | Rearranges windows and panes |
| `wait_for_channel` `signal_channel` | Coordinates through bounded tmux channels |
| `set_mouse_enabled` `set_history_limit` | Applies typed server settings |
| `create_session` `create_window` `split_window` `respawn_pane` | Starts configured pane processes without command payloads |
| `run_shell_command` | Runs a command in a pane, waits, and reports its exit status |
| `send_keys` `send_keys_batch` `paste_text` | Sends bounded input to pane programs |
| `set_synchronize_panes` | Makes later pane input fan out across a window |
| `clear_pane_scrollback` `kill_pane` `kill_window` `kill_session` | Deletes retained or live tmux state |

Pane modes remain human-client state, not MCP automation state. Read bounded
scrollback with `capture_pane` and its `start`/`end` range, use `search_panes` to
discover matching output, or use `snapshot_pane` when one MCP response should
contain both pane metadata and bounded content; the metadata and capture are
separate reads, not an atomic snapshot. Carry the opaque `capture_since` cursor
across turns for new output. If a pane is already in a human-owned mode, read
`pane_in_mode` or `pane_mode` through `get_tmux_variables`, report it, and leave
entry or cancellation to the client that owns the interaction.

Pane input reads fresh typed death, mode-count, effective synchronization,
caller, and terminal-attendance state. Missing, malformed, or inconsistent
caller/client context fails closed. A zoomed terminal client protects its
active pane; an unzoomed terminal client protects every pane in its active
window. Control clients do not count. `send_keys` checks every configured
member of the effective synchronized cohort; `send_keys_batch` repeats that
check for every executed row. Returned pane IDs describe configured
membership, not proof of delivery, and the checks remain observational because
tmux state can change after a snapshot. A process-wide reservation protects
every configured member through dispatch, so pane input refuses overlap with
an active run or other input.

`paste_text` checks its target before staging and immediately before its one
paste dispatch. It keeps non-empty text and its optional Enter target-only in
one private buffer and removes the buffer on every path. Empty text without
Enter still performs its initial safety check, then returns without creating a
buffer or dispatching input. `run_shell_command` checks before setup and again
before dispatch, refuses a second run instead of waiting, requires a single
configured pane running a recognized POSIX shell, and contains the command in
a subshell so it cannot leave shell state behind. Those guarantees assume the
selected shell, tmux daemon, and configuration are trusted; they do not claim
containment against a hostile shell environment. `force=true` bypasses only an
exact caller-pane match; it never bypasses attendance, active-operation, mode,
death, shell, or target-count checks.

Every tool declares native input and output schemas and carries its complete
capability row under `_meta["com.git-pull.libtmux-mcp/capability"]`. The same
immutable registry drives registration, dispatch, descriptions, filtering, and
the `tmux://capabilities` report. That static report is the only MCP resource;
the server exposes no prompts or dynamic templates.

Every answer travels as both `structuredContent` and JSON text, so clients that
read either representation receive the same typed result.

The rows disclose process reach, tmux effects, output classes, one
`inputLiteralization` map, and conservative MCP annotations. Detailed input
sink tables remain internal validation data. The rows are consent metadata,
not a security boundary. Terminal content, environment values, configured
commands, and tmux metadata may contain secrets or untrusted instructions.

### Migrating from the earlier MCP surface

Earlier alpha releases used ordered safety tiers and different tool names.
These names are not aliases on the frozen 45-tool surface:

| Earlier name or URI | Current path |
| --- | --- |
| `enter_copy_mode`, `exit_copy_mode` | No MCP replacement. Read history through `capture_pane`, locate output with `search_panes`, continue with `capture_since`, and leave human-owned pane modes unchanged. Applications that own pane state can use the core library's `enterCopyMode` and `cancelModes` APIs. |
| `LIBTMUX_SAFETY` | Use `LIBTMUX_TOOLSETS`; any present legacy value stops startup. |
| `LIBTMUX_MCP_TOOLS` | Use `LIBTMUX_TOOLSETS=` with `LIBTMUX_TOOLS` to preserve its exact allowlist; any present legacy value stops startup. |
| `tmux://snapshot` | Compose `list_sessions`, `list_windows`, `list_panes`, and `snapshot_pane`. |
| `tmux://sessions` | Use `list_sessions`. |
| `tmux://filters` | Read native input schemas from `tmux://capabilities` and filter bounded listings client-side. |
| `tmux://sessions/{session}/windows` | Use `list_windows` with the session reference. |
| `tmux://panes/{pane}` | Use `get_pane_info` with the pane reference. |
| `tmux://panes/{pane}/content` | Use `capture_pane` for a bounded slice, `snapshot_pane` for metadata and content, or `capture_since` to continue across turns. |
| `describe_server` | Use `get_server_info`; `list_panes` also marks the caller pane. |
| `list_servers` | No discovery route; pin one socket per process and run another process for another socket. |
| `describe_filters` | No separate route; read the published input schemas and filter bounded listings client-side. |
| `snapshot` | Compose `list_sessions`, `list_windows`, `list_panes`, and `snapshot_pane`; the capability report carries frozen connection provenance. |
| `read_format` | Use `get_tmux_variables` for validated names; arbitrary tmux formats have no replacement. |
| `show_options` | Use `show_option` for one named option. |
| `run_shell` | Use `run_shell_command`; it remains synchronous and bounded. |
| `wait_for_output` | Use `wait_for_text`. |
| `watch_format` | No format subscription; use `capture_since`, `wait_for_text`, or a typed metadata read. |
| `new_session`, `new_window`, `split_pane` | Use `create_session`, `create_window`, and `split_window`. |
| `rename`, `select` | Use the session/window and pane/window variants, such as `rename_session` and `select_pane`. |
| `set_option` | Use `set_mouse_enabled`, `set_history_limit`, `set_synchronize_panes`, or `set_pane_title`; there is no generic setter. |
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

### Three things it does that a wrapper does not

**Waits have deadlines.** Every wait is clamped to a ceiling and reports what
was actually enforced. Requests are served concurrently, so a thirty-second
wait does not hold up the `ping` beside it, and `notifications/cancelled` stops
one that the client has stopped caring about. `wait_for_text` and
`wait_for_channel` expose the two blocking operations through bounded calls.

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

**It will not end the conversation.** When the server runs inside the selected
tmux it knows which pane is its own. Direct teardown tools refuse that pane,
window, or session unless the call explicitly passes `force`. The guard does
not claim to constrain equivalent commands sent through an execute tool.

### What it feels like

> **You:** Which of my panes are sitting in an editor?
>
> **Agent:** Three — `%4` and `%7` are running `nvim`, `%12` is running `vim`.
> `%4` is in `~/work/api`, the other two are in `~/work/web`.

The agent called `list_panes`, selected the rows whose current command was an
editor, and answered from the typed metadata. It did not shell out, parse
`tmux list-panes` output, or guess a format string.

### When it earns its keep

For a single `tmux send-keys`, it does not — run tmux. It earns its keep when
something has to be *asked* rather than done, or *waited for* rather than
polled: which pane is running the failing test, whether the dev server came up,
whether the session you are about to create already exists.

`LibTmuxMCP` is the same tools as a library, if you would rather embed them in a
server of your own than run this one.

## Project status

**Alpha.** The library works and its suite runs against eight tmux releases on
every push, but the API has had no outside use and names are still moving.
Expect to update code when you update the package.

What that means concretely:

- **The public API can change in any release**, with no deprecation first.
  Semantic versioning starts saying something at `0.1.0`; until then a version
  number only tells you which alpha you have.
- **Pin an exact version**, for the reasons under [Install](#install).
- **`LibTmux` is the part to build on.** It is the largest, the most exercised,
  and the closest to settled. `TmuxWorkspace` and `LibTmuxMCP` are newer and
  thinner, and are likelier to move.
- **The tmux behaviour is the tested part.** Compatibility with 3.2a through
  3.7b is checked in CI against each release built from its own tag, so what
  the library claims about tmux is evidence rather than intent. The Swift
  surface around it is what has not settled.

Useful now for a tool you control and can update. Not yet something to put
under a dependency you do not.

## Requirements

| | |
| --- | --- |
| Swift | 6.2 or later |
| Platforms | Linux and macOS — see [Platform notes](#platform-notes) |
| tmux | 3.2a through 3.7b |
| Dependencies | [swift-subprocess][] for the core; [Yams][] behind a trait, for reading YAML |

## Documentation

The [DocC][] catalogue is the reference, and covers modes, snapshots, filtering,
streaming, waiting, and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

CI builds it and fails the job on any warning.

Every Swift example in this file is also code the build compiles, and most of
it is code the suite *runs*. Compiling catches a call that was renamed; only
running catches one that quietly began answering something else — so the
examples that can address a live server live in [`Examples/`][examples] and are
executed against real tmux, on sockets under this suite's own namespace.

```console
$ python3 Scripts/check_examples.py
47 documented examples mapped to consumer sources
41 have live-test call sites
```

That check fails if a fence here has no example behind it. The Examples test
run is what compiles those sources and exercises the 41 live call sites; CI
runs both gates.
[`Examples/README.md`](Examples/) says how a fence is matched, and what the
check cannot see.

## Tests

The suite runs against real tmux — no mocks of the server — one private socket
per case, with servers reaped even when a run is killed outright.

```console
$ swift test --traits YAMLWorkspaces
```

The trait is off by default and six tests come with it, so the gate names it.
Point the suite at a particular release to test against that one:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.2a/bin/tmux swift test
```

CI runs the suite on Linux against each of tmux 3.2a, 3.3a, 3.4, 3.5, 3.6, 3.7,
3.7a, and 3.7b, each built from its own release tarball.

## Repository layout

| Path | What is in it |
| --- | --- |
| [`Sources/`][sources] | The four runtime products |
| [`Tests/`][tests] | The suite, and the `TmuxFixture` product every suite provisions servers through |
| [`Examples/`][examples] | Every documented example, its own package so they compile as a consumer does — and most run against a live tmux |
| [`Benchmarks/`][benchmarks] | The mode benchmark, its own package so the shipped manifest names only what ships |
| [`Parity/`][parity] | What Python libtmux exposes, recorded, and what this port does about each of it |
| `Scripts/` | The Python tooling CI runs |
| `dev/Spikes/` | Disposable experiment packages. Not part of a release |

## Platform notes

The suite runs on both. Linux covers every supported tmux release, eight ways
in parallel; macOS runs the ends of that range, because what differs on Darwin
is this package's own handling — the `TMPDIR` a socket path cannot afford,
keg-only libevent and ncurses, `F_SETNOSIGPIPE` — and none of it varies by tmux
release.

**On Darwin, build with Xcode's toolchain rather than one from swift.org.**
[swift-subprocess][] reaches `Span.bytes`, whose accessor back-deploys only from
Swift 6.3, so a 6.2 toolchain fails inside the dependency at any deployment
target below macOS 26 — and SwiftPM compiles a dependency at *that dependency's*
declared minimum, so no number set here reaches it. Xcode 26 ships Swift 6.3,
which is what the macOS lane and upstream's own CI both use.

A program that opens connections should ignore `SIGPIPE`, because a write to a
tmux that went away first will otherwise end the process:

```swift
signal(SIGPIPE, SIG_IGN)
```

The library does not set this itself — the disposition is process-wide, and a
library changing it would change how its host behaves at the end of every
pipeline it is in. This package's own suite makes the call, which is how the
need for it is known.

## Relationship to Python libtmux

This is a port of [libtmux][] for Python, and follows it where following it
earns its place. Where Swift wants something else, it gets something else:
results are plain arrays rather than a query list, a single typed `TmuxError`
replaces an exception hierarchy, and objects are values rather than live
handles. `Scripts/parity_report.py` measures the surface against Python's
recorded API and names each divergence, so a difference reads as a decision
rather than an omission.

## Related projects

- [libtmux][] — the Python library this is a port of
- [tmuxp][] — tmux session manager, and the workspace format `TmuxWorkspace`
  reads
- [libtmux-mcp][py-mcp] — the Python MCP server for tmux
- [The Tao of tmux][tao] — the book

## License

MIT. See [LICENSE](LICENSE).

[libtmux]: https://github.com/tmux-python/libtmux
[tmuxp]: https://tmuxp.git-pull.com/
[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
[Yams]: https://github.com/jpsim/Yams
[MCP]: https://modelcontextprotocol.io
[DocC]: https://www.swift.org/documentation/docc/
[sources]: Sources/
[tests]: Tests/
[examples]: Examples/
[benchmarks]: Benchmarks/
[parity]: Parity/
[p-lib]: Sources/LibTmux/
[p-ws]: Sources/TmuxWorkspace/
[p-mcp]: Sources/LibTmuxMCP/
[p-server]: Sources/libtmux-mcp/
[p-test]: Tests/TmuxFixture/
[py-mcp]: https://libtmux-mcp.git-pull.com
[tao]: https://leanpub.com/the-tao-of-tmux
[filtering]: Sources/LibTmux/LibTmux.docc/Filtering.md
[alpha3-readme]: https://github.com/libtmux/libtmux-swift/blob/0.1.0-alpha.3/README.md
