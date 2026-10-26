<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="https://raw.githubusercontent.com/libtmux/libtmux-swift/HEAD/assets/logo.svg" type="image/svg+xml">
    <img src="https://raw.githubusercontent.com/libtmux/libtmux-swift/HEAD/assets/logo.png" width="128" height="128" alt="libtmux for Swift">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# libtmux for Swift

[![ci](https://github.com/libtmux/libtmux-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/libtmux/libtmux-swift/actions/workflows/ci.yml)
[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/swift/)
[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flibtmux%2Flibtmux-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/libtmux/libtmux-swift)

Drive tmux from Swift. A port of [libtmux][] for Python, in the same family of
ports and holding to what that library established about tmux.

</div>

Ask a [`Server`][api-server] what it holds and get [`Session`][api-session],
[`Window`][api-window], [`Pane`][api-pane], and [`Client`][api-client] values
back. Every call reports [`TmuxError`][api-tmuxerror] explicitly.

It suits tools that drive tmux: a session manager, a test harness, a dashboard,
an agent that needs somewhere to run things.

Everything that comes back is a value. A `Session` you hold is what the server
reported when you asked, and it stays that way when tmux changes. Ask again for
a newer view.

> [!WARNING]
> Releases are numbered `0.1.N`, and each release increments `N`. The API is
> not settled: any release may change or remove exported identifiers, and the
> changelog marks each break. Pin an exact version to avoid one.

**Contents** — [Quick start](#quick-start) · [Install](#install) ·
[Asking](#find-sessions-windows-and-panes) ·
[Changing](#change-what-tmux-holds) ·
[Waiting](#type-into-a-pane-and-wait) ·
[Modes](#choosing-how-to-reach-tmux) ·
[Workspaces](#workspaces-from-a-file-or-from-swift) ·
[MCP](#tmux-as-mcp-tools) · [Testing](#testing-your-own-code) ·
[Products](#products) · [Leaves out](#what-it-leaves-out) ·
[Status](#support-and-status) · [Docs](#documentation) · [Tests](#tests)

## Quick start

With tmux already running on its default socket, list its sessions. This is the
whole program:

```swift
import LibTmux

let server = try Server(socketName: "default")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

A [`Server`][api-server] addresses a tmux socket by name, and
[`Server.sessions()`][api-server-sessions] asks it for every session. It runs on
Linux, including WSL, and on macOS (best effort, no CI),
with tmux 3.3a through 3.8, and master.

`QuickStartTests` spawns this program against a fixture server that holds one
session named `quickstart`, and checks that the output names it. It prints one
line per session: the name, then the window count.

## Install

Depend on a release from `0.1.0` on:

```swift
.package(url: "https://github.com/libtmux/libtmux-swift.git", from: "0.1.0")
```

`from: "0.1.0"` accepts every `0.1.N` and, in SwiftPM, any later minor release
below `1.0.0` as well, breaking releases included. Name a single release with
`exact:` and read the changelog before you move it.

```swift
.product(name: "LibTmux", package: "libtmux-swift")
```

> [!NOTE]
> This page documents `master`, which may be ahead of the latest release; the
> README at a release tag matches that release. To compile the examples on this
> page, depend on `master`:

```swift
.package(url: "https://github.com/libtmux/libtmux-swift.git", branch: "master")
```

### `YAMLWorkspaces`: read YAML

Reading a workspace from YAML needs a parser, and asking for the trait is what
pulls one in. Without it nothing here resolves Yams; with it,
[`Workspace.decode(yaml:)`][api-workspace-decode-yaml] exists:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    from: "0.1.0",
    traits: ["YAMLWorkspaces"]
)
```

## Find sessions, windows, and panes

### [`Server.sessions()`][api-server-sessions]: what tmux has now

One call asks tmux for every session. [`Server.windows()`][api-server-windows]
and [`Server.panes()`][api-server-panes] are its siblings, and each returns a
plain array of values:

```swift
let sessions = try await server.sessions()
let windows = try await server.windows()
let panes = try await server.panes()
```

`QueryingTests` runs this on a fixture server and asserts one session, one
window, and one pane.

### [`Pane`][api-pane]: what is running in it

A pane knows its [`Pane.currentCommand`][api-pane-currentcommand] and
[`Pane.currentPath`][api-pane-currentpath]:

```swift
for pane in try await server.panes() {
    print(pane.id, pane.currentCommand, pane.currentPath)
}
```

`QueryingTests` asserts the command is not empty and the path is absolute. It
prints one line per pane: the id, the command, and the path.

### [`Server.hasSession(_:)`][api-server-hassession]: a yes-or-no question

Questions tmux answers with an exit code come back as a `Bool`:

```swift
guard try await server.hasSession("work") else { return }
```

`QueryingTests` runs both branches against a fixture server.

### [`Server.run(_:)`][api-server-run]: anything the library does not model

A tmux command that runs and reports a nonzero status gives a reply:
`has-session` answers a question that way. `run(_:)` returns the status and the
text without throwing, and [`TmuxCommand`][api-tmuxcommand] builds the command:

```swift
let reply = try await server.run(
    TmuxCommand("display-message", ["-p", "#{client_termname}"])
)
print(reply.isSuccess ? reply.text : reply.errorText)
```

`QueryingTests` runs it and asserts tmux did not answer `unknown command`. It
prints the client's terminal name, or tmux's error text when the command failed.

### [`Server.session(named:)`][api-server-session-named]: one object, refreshed

Holding a value and wanting a newer view of it does not need a whole listing.
[`Server.refresh(_:)`][api-server-refresh] re-reads a value you hold:

```swift
let work = try await server.session(named: "work")
let fresh = try await server.refresh(pane)
```

`LookupTests` asserts the session is found by name and the pane by id.

A missing object is `nil`, because objects go away all the time. A re-read
also refuses a value from a different daemon: tmux restarts its ids at zero, so
a same-numbered pane on a replacement server is a different pane.

### [`Server.snapshot()`][api-server-snapshot]: sessions, windows, panes, and clients at once

A [`Snapshot`][api-snapshot] collects all four into one value and resolves the
relationships inside it, so you do not match ids yourself:

```swift
let snapshot = try await server.snapshot()
for window in snapshot.windows(of: session) {
    print(window.name, snapshot.panes(of: window).count)
}
```

`SnapshotTests` asserts every window of a session resolves back to it and has
panes. It prints each window's name and its pane count.

The listings are separate tmux commands. `snapshot()` checks the daemon
incarnation before and after them and reports a replacement. Another client can
still change the same daemon between listings, so the four lists can disagree.

### [`FilterExpr`][api-filterexpr]: a filter that travels

Filter with the standard library when the predicate is local to your code.
`FilterExpr` is for a filter that has to leave it: stored in a config, sent to
another process, handed to a tool.

It is built from key paths, so the compiler rejects a text operator on a
number, and it holds no closures, so it encodes:

```swift
let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
let matching = try await server.panes().filter(expression)
```

`FilteringTests` asserts the expression selects the same panes the predicate
would. [`Server.panes(where:)`][api-server-panes-where] sends the same
expression to tmux, so the rows that would have been discarded never cross the
process boundary:

```swift
let matching = try await server.panes(where: expression)
```

`LookupTests` asserts it selects the pane the predicate would. The two give
the same answer:

- **The first** formats, pipes, and decodes every row before discarding most of
  them.
- **The second** sends the filter to tmux, so only matching rows come back.
- **A regular expression** cannot run in tmux. The predicate sent to tmux is
  widened, and this package's bounded regex engine decides the rest here.

The full vocabulary of operators, aliases, and field types is in
[`Filtering.md`][filtering] and on the [queries page][ref-concept-queries]. The
[MCP tools](#tmux-as-mcp-tools) offer the same filtering to a client that does
not speak Swift.

## Change what tmux holds

### [`Server.newSession(named:windowName:)`][api-server-newsession-named-startdirectory-windowname-width-height]: create and arrange

[`Server.newSession`][api-server-newsession-named-startdirectory-windowname-width-height]
makes a session.
[`Server.newWindow(in:named:startDirectory:)`][api-server-newwindow-in-named-startdirectory],
{{Server.splitWindow}), and [`Server.setOption`][api-server-setoption-to-scope]
shape it, and [`Server.run(_:in:)`][api-server-run-in] sends a command to a
pane:

```swift
let session = try await server.newSession(named: "work", windowName: "editor")
_ = try await server.setOption("@purpose", to: "development", scope: .session(session))
let logs = try await server.newWindow(in: session, named: "logs").window
let pane = try await server.splitWindow(logs, direction: .right)
try await server.run("tail -f /tmp/build.log", in: pane)
```

`ChangingTests` asserts tmux ends up with a `work` session holding `editor` and
`logs` windows, and two panes in `logs`.

### [`Server.capture(_:)`][api-server-capture-includinghistory]: read a pane back

Read a pane back the way a person would:

```swift
let lines = try await server.capture(pane)
```

`ChangingTests` prints a marker into a pane and asserts the capture holds it.

### [`TmuxCommandList`][api-tmuxcommandlist]: several changes, one process

When several changes belong together, a command list spends one tmux
invocation on all of them instead of one each:

```swift
var plan = TmuxCommandList()
for name in ["edit", "test", "logs"] {
    plan = plan.then("new-window", ["-d", "-n", name])
}
_ = try await server.run(plan)
```

`ChangingTests` asserts every window the list names exists afterwards.

## Type into a pane and wait

tmux has no hook that fires when a pane prints something, so a wait built from
commands alone re-reads the pane on a timer and spends a process per tick.

A control connection is told instead. These three waits are cheaper than the
loop everyone writes first; reach for them in this order.

### [`Server.wait(for:)`][api-server-wait-for]: you wrote the command

Compose a channel into the command: tmux blocks server-side and returns on the
signal itself, so nothing is inferred from what the screen looks like.
[`Server.shellInvocation`][api-server-shellinvocation] names the tmux that
serves the pane:

```swift
try await server.run(
    "make; \(server.shellInvocation) wait-for -S built",
    in: pane
)
try await server.wait(for: "built")
```

`WaitingTests` runs it and asserts the wait returns when the command signals.

### [`FormatSubscription`][api-formatsubscription]: the question is about state

Subscribe to a format and tmux reports each time its value changes, with no
capture and no prompt regex. [`ControlSession.watch`][api-controlsession-watch]
subscribes and
[`ControlSession.changes(named:)`][api-controlsession-changes-named] yields the
changes:

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

`WaitingTests` asserts the watch returns the value it names. The format
`#{pane_current_command}` answers "is my command done?" exactly. This needs a
connection, which needs tmux 3.7; an older daemon refuses it before anything
attaches.

### [`Server.waitForOutput`][api-server-waitforoutput-in-matching-stoppingat-requiringfreshoutput-startingat-timeout-taillimit]: you did not write the command

For a daemon printing `ready` or a dev server someone else started, wait on the
pane's output. `%output` wakes the wait, and the matching runs against the
rendered grid. [`RegexPattern`][api-regexpattern] values say what to match and
what to stop at:

```swift
let ready = try RegexPattern("Listening on")
let failed = try RegexPattern("EADDRINUSE|error", options: [.caseInsensitive])
let waited = try await server.waitForOutput(
    in: pane,
    matching: [ready],
    stoppingAt: [failed]
)
```

`WaitingTests` asserts the wait ends `.matched` on the line it was given. A
small liveness check detects a pane removed while it is quiet. What to know:

- **Stops.** Pass `stoppingAt` whenever a failure marker exists. A build that
  fails after five seconds ends the wait at five seconds.
- **Already on screen.** The condition is checked before it is blocked on, so
  text already on screen returns at once with `matchedAtEntry: true`. Pass
  `requiringFreshOutput` when only a new occurrence counts.

When a wait ends without a match, [`OutputWait`][api-outputwait] says which
thing happened:

- **`timedOut`, `sawNewOutput: false`.** The pane stayed quiet, and no pattern
  will fix it.
- **`timedOut`, with output.** `tail` holds what arrived, so you can fix the
  pattern against it.
- **`expiredWhileReading`.** The timeout ended before the pane could be read at
  all, so nothing was established either way.
- **`alternateScreen`.** A pager, editor, or other full-screen program held the
  pane. tmux fills it from a grid it keeps out of history, so matching is
  suppressed there.

The DocC catalogue's `Waiting` article explains why the output stream only
signals that the pane wrote something, and the match runs against the rendered
grid. The [waiting and retrying][ref-topic-waiting] page covers it on
libtmux.org.

## Choosing how to reach tmux

### [`TmuxMode`][api-tmuxmode]: one switch, the same answers

`TmuxMode` changes how work reaches tmux and never what you get back. It has two
settings, [`TmuxMode.direct`][api-tmuxmode-direct] and
[`TmuxMode.connected(to:)`][api-tmuxmode-connected-to]:

| Mode | How work travels | Where it wins |
| --- | --- | --- |
| `.direct` | A tmux process per call | One call, or calls far apart. The default |
| `.connected(to:)` | One live connection for the whole scope | More than one call, and being told what changed |

`.connected(to:)` needs tmux 3.7 and `.direct` serves every supported release.

The default needs no word at all:

```swift
let sessions = try await server.sessions()
```

Each other mode adds one. [`Server.using(_:_:)`][api-server-using] runs a scope
in the mode you name, and the calls inside are the same calls with the same
types:

```swift
let names = try await server.using(.connected(to: "main")) { server in
    try await server.sessions().map(\.name)
}
```

The mode is a value, so a program that decides at runtime can write the
decision:

```swift
let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
let sessions = try await server.using(mode) { server in
    try await server.sessions()
}
```

`ModeTests` asserts that a connected scope, and one chosen at runtime, return
what the direct one would.

### [`Server.using(_:_:)`][api-server-using]: which server is in which mode

Three rules decide it, in order of precedence:

1. **The value you were handed.** [`using(_:)`][api-server-using] and
   [`connected(attachingTo:_:)`][api-server-connected-attachingto] give you a
   server in that mode. Nesting takes the innermost, so
   [`using(.direct)`][api-server-using] inside a connected scope keeps one call
   off the connection.
2. **Anything else is `.direct`**, including a server captured from outside the
   closure.
3. **Two calls take their own process regardless**:
   [`Server.wait(for:)`][api-server-wait-for], which would otherwise deadlock
   the scope, and [`Server.buffer(named:)`][api-server-buffer-named], whose
   bytes a connection cannot report unambiguously. What comes back does not
   depend on the mode.

Nothing is global, and nothing is inherited by a task.
[`server.mode`][api-server-mode] reports which mode a value carries, so the rule
can be checked at runtime.

### What it costs

`swift run --package-path Benchmarks libtmux-bench` measures each mode:

- It runs each scenario under each mode, behind a shim standing in for the tmux
  binary.
- It counts a process every time one starts and a round trip every time a
  command line is handed over.
- The benchmark writes the table below. `Scripts/update_mode_matrix.py --check`
  fails if it has drifted, and CI runs that check.

<!-- mode-matrix:start -->

<!-- generated by `swift run --package-path Benchmarks libtmux-bench --markdown`; do not edit -->

| Work | Direct | Connected |
| --- | --- | --- |
| list-sessions, once | 2 processes, 2 round trips | 2 processes, 4 round trips |
| list-sessions, twenty times | 21 processes, 21 round trips | 2 processes, 23 round trips |
| sessions, windows, panes, clients, twice-checked | 7 processes, 7 round trips | 4 processes, 9 round trips |
| sessions, windows, panes, clients — one after another | 5 processes, 5 round trips | 2 processes, 7 round trips |
| the same four, concurrently — a pipelined batch | 5 processes, 5 round trips | 2 processes, 7 round trips |
| new-window five times, each its own command | 8 processes, 8 round trips | 2 processes, 10 round trips |
| the same five as one command list | 4 processes, 4 round trips | 2 processes, 6 round trips |
| new-window then split, read back | 6 processes, 6 round trips | 2 processes, 8 round trips |

| Noticing a pane printed a line | Polling | Streaming |
| --- | --- | --- |
| tmux processes spent | 2 | 1 |
| round trips spent | 2 | 3 |

<!-- mode-matrix:end -->

How to read the table:

- **Directly, a round trip is a process**, so that column always agrees with
  itself. Every row also carries the process that reads the daemon's release
  once.
- **Connecting collapses the rest to the connection's own process** and charges
  extra round trips for the attach and its release check. A single call is
  therefore where the default wins, and from the second call on the connection
  is ahead.
- **A command list shows up in the round trips.** Under a connection it and the
  separate commands cost the same processes, and only the round trips tell them
  apart.

The benchmark also prints wall-clock medians, which move with the machine. Run
it yourself for those.

### [`Server.connected(attachingTo:_:)`][api-server-connected-attachingto]: hear changes as they happen

A connection can do one thing a process cannot, which is report what changed
without being asked. It needs tmux 3.7; an older daemon refuses it before
anything attaches:

```swift
let firstLine: String? = try await server.connected(attachingTo: "work") { server, events in
    for try await notification in events.notifications
    where notification.name == "output" {
        return notification.arguments
    }
    return nil
}
```

`StreamingTests` asserts the connection reports pane output as it happens.

### [`withTmuxError`][api-withtmuxerror]: typed errors across a scope

Every call throws [`TmuxError`][api-tmuxerror] and says so, so a program can use
typed throws from top to bottom. The scoped forms take a closure, and Swift 6.2
cannot carry a closure's thrown type out of one. Wrap the scope to narrow it
back:

```swift
func names(_ server: Server) async throws(TmuxError) -> [String] {
    try await withTmuxError {
        try await server.using(.connected(to: "main")) { server in
            try await server.sessions().map(\.name)
        }
    }
}
```

`LookupTests` asserts the scope returns the session names.

Swift 6.2 cannot do this for you: a typed-throws overload of the scopes is
unreachable, because a closure literal's thrown type is never inferred from its
body.

## Workspaces, from a file or from Swift

[`TmuxWorkspace`][mod-tmuxworkspace] builds a whole session in one go, from a
[tmuxp][] workspace. Written in Swift, a workspace is ordinary values.

### [`Workspace`][api-workspace]: a session described as values

[`WindowPlan`][api-windowplan] and [`PanePlan`][api-paneplan] describe each
window and its panes:

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

`WorkspaceTests` builds this value and asserts tmux ends up with its windows.

### [`WorkspaceBuilder.build(_:on:)`][api-workspacebuilder-build-on]: build it on a server

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

`WorkspaceTests` asserts the `work` session exists with `editor` and `logs`
windows and two panes in `editor`. What to know:

- **A name in use is refused.** Two callers building the same workspace should
  not silently share a session.
- **A failure rolls back.** A later, ordinary failure removes the exact session
  this build created; a rollback failure reports both errors.
- **An interruption removes nothing.** The signal that stopped the build could
  just as well stop the cleanup that would follow it.

### [`Server.validateLayouts(_:)`][api-server-validatelayouts]: check layouts first

The builder validates every layout before creating the session. The same native
guard protects [`Server.selectLayout(_:_:)`][api-server-selectlayout] and MCP
[`select_layout`]. Custom builders can check a complete batch with the desired
pane counts first:

```swift
try await server.validateLayouts([("even-h", 2), ("tiled", 1)])
```

`WorkspaceTests` runs this call. The rules:

- **Abbreviations.** Names accept unique abbreviations for the running
  daemon's version.
- **Saved layouts.** They require a checksum, a nonempty tree, and enough
  cells; tmux still owns geometry and pruning.
- **An empty batch** performs no I/O unless cancelled.
- **A cold endpoint.** A version-sensitive name on an unbound cold endpoint uses
  the configured tmux client; permission, protocol, and retained-connection
  errors propagate.

### [`Workspace.decode(yaml:)`][api-workspace-decode-yaml]: read a tmuxp file

JSON needs no trait, because tmuxp's keys decode straight into these types with
[`Workspace.decode(json:)`][api-workspace-decode-json]. The YAML that tmuxp
files are usually written in needs the `YAMLWorkspaces` trait:

```swift
try Workspace.decode(yaml: text)
```

`WorkspaceTests` asserts a tmuxp file decodes into the workspace it describes.
The fixtures are tmuxp's own examples, decoded both ways and compared, which is
a stronger claim than either parsing alone.

### [`tmux-workspace`][mod-tmux-workspace]: a second reader of the same format

[`Workspace`][api-workspace] is a narrower language than the `tmux-workspace`
executable reads, and the two are separate readers of one file format:

- **Dropped by [`decode(yaml:)`][api-workspace-decode-yaml].**
  `shell_command_before`, `suppress_history`, `options`, `global_options`,
  `window_options`, `options_after`, `before_script`, and
  `workspace_builder_options`; `$VAR` stays unexpanded.
- **Read by the executable.** It reads all of those.
- **Shared.** The executable creates every session through
  [`WorkspaceBuilder`][api-workspacebuilder], so a layout built from Swift is
  the layout the command builds.

## tmux as MCP tools

[`libtmux-mcp`][mod-libtmux-mcp] is a [Model Context Protocol][MCP] server. It
speaks JSON-RPC 2.0 over stdio, one message per line, so anything that launches
an MCP server can drive tmux through it.

### [`libtmux-mcp`][mod-libtmux-mcp]: start the server

Build the executable:

```console
$ swift build --product libtmux-mcp
```

Register it with Claude Code, limited to the `inspect` toolset:

```console
$ claude mcp add tmux \
    -e LIBTMUX_TOOLSETS=inspect \
    -- /path/to/.build/debug/libtmux-mcp
```

Other clients take a JSON configuration. The server takes no flags: which tmux
it talks to and which tools it exposes are fixed from its startup environment.

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

`ReadmeDocumentationTests` passes this `env` and every `claude mcp add` setting
in the repository through [`ServerConfiguration`][api-serverconfiguration], the
parse the executable runs before it opens a socket.

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

What to know about startup:

- **Default launch.** The dedicated `libtmux-mcp` socket and the minimal config.
- **Teardown.** Added only when the daemon retains this process's launch nonce
  from that config. Explicit sockets, configs, and existing daemons never gain
  it.
- **Bad names.** Unknown names and empty list tokens fail before the socket is
  opened.
- **Shutdown.** When stdio ends, the process removes only the default daemon
  whose launch nonce and incarnation still match.
- **Socket names.** `LIBTMUX_SOCKET` is a name, and tmux resolves a name inside
  `TMUX_TMPDIR`. Set that in the same `env` block when your tmux keeps its
  sockets somewhere else.
- **stderr.** Anything for a human goes there, because stdout is the protocol
  and a stray line corrupts it.

The full launch contract is in
[`docs/mcp-contract.md`][r-docs-mcp-contract-md-default-launch-and-teardown].

### [`Toolset`][api-toolset]: the tools a client is offered

A toolset is a named group of tools, and it is what an operator grants or
withholds:

- **`inspect`** reads tmux and what panes show.
- **`manage`** renames, resizes, selects, and moves what exists.
- **`execute`** creates sessions, windows, and panes, and sends input to them.
- **`teardown`** kills sessions, windows, and panes, and clears scrollback.

The registry holds every tool under exactly one toolset. By default:

- **A configured executable** exposes `inspect`, `manage`, and `execute`.
- **An authenticated daemon** started from the bundled minimal configuration
  also receives `teardown`.

| Tool | What it answers or does |
| --- | --- |
| [`list_sessions`] [`list_windows`] [`list_panes`] | Lists the objects on the selected socket |
| [`get_server_info`] [`get_session_info`] [`get_window_info`] [`get_pane_info`] | Returns one level's typed metadata |
| [`capture_pane`] [`capture_since`] [`snapshot_pane`] [`search_panes`] | Reads bounded terminal content |
| [`find_pane_by_position`] [`wait_for_text`] | Finds a pane or waits for bounded output |
| [`get_tmux_variables`] [`show_option`] [`show_environment`] [`show_hooks`] | Reads configuration and environment values |
| [`call_read_tools_batch`] | Runs up to 16 eligible inspect operations under one outer approval |
| [`rename_session`] [`rename_window`] [`select_window`] [`select_pane`] [`select_layout`] | Renames or selects tmux state |
| [`resize_window`] [`resize_pane`] [`move_window`] [`swap_pane`] [`set_pane_title`] | Rearranges windows and panes |
| [`wait_for_channel`] [`signal_channel`] | Coordinates through bounded tmux channels |
| [`set_mouse_enabled`] [`set_history_limit`] | Applies typed server settings |
| [`create_session`] [`create_window`] [`split_window`] [`respawn_pane`] | Starts configured pane processes without command payloads |
| [`run_shell_command`] | Runs a command in a pane, waits, and reports its exit status |
| [`send_keys`] [`send_keys_batch`] [`paste_text`] | Sends bounded input to pane programs |
| [`set_synchronize_panes`] | Makes later pane input fan out across a window |
| [`clear_pane_scrollback`] [`kill_pane`] [`kill_window`] [`kill_session`] | Deletes retained or live tmux state |

Each name links to its page on libtmux.org, and the [tool index][ref-mcp-tools]
lists them all.

The `execute` tools run with the tmux user's authority whatever toolsets are
selected, so grant them only to clients trusted to act as that user.

### [`send_keys`]: the checks before pane input

Pane input reads fresh state and fails closed when it is missing or
inconsistent. What a caller can rely on:

- **Dead and moded panes are refused.** So is a pane whose caller or
  terminal-attendance context is incomplete or malformed.
- **Attended panes are protected.** A zoomed terminal client protects its active
  pane; an unzoomed one protects every pane in its active window. Control
  clients do not count.
- **Synchronized panes are checked together.** `send_keys` checks every
  configured member of the cohort, and [`send_keys_batch`] repeats the
  check for every executed row.
- **`force=true` is narrow.** It bypasses only an exact caller-pane match.
- **IDs describe configuration.** Returned pane IDs are the checked members,
  not proof of delivery.

Two tools get their own checks:

- [`paste_text`] checks its target before staging and again before its one
  paste, in a private buffer it removes on every path.
- [`run_shell_command`] refuses a second run, needs one pane running a
  recognized POSIX shell, and contains the command in a subshell.

The full contract is in
[`docs/mcp-contract.md`][r-docs-mcp-contract-md-pane-input].

### [`capture_pane`]: history, snapshots, and pane modes

A pane in a mode belongs to the human attached to it:

- **Read history** with `capture_pane` and its `start`/`end` range, or find it
  with [`search_panes`].
- **Read pane and content together** with [`snapshot_pane`]. The metadata
  and the capture are two reads, so a pane can change between them.
- **Follow output** across turns with the opaque cursor from
  [`capture_since`].
- **If a pane is in a mode,** read `pane_in_mode` or `pane_mode` through
  [`get_tmux_variables`], report it, and leave entry or cancellation to the
  client that owns the interaction.

More in [`docs/mcp-contract.md`][r-docs-mcp-contract-md-pane-modes].

### [`wait_for_text`]: limits on waits and reads

- **Waits have deadlines.** Every wait is clamped to a ceiling and reports what
  was enforced. `notifications/cancelled` stops one the client has dropped.
- **Reads are budgeted.** Pane reads collect at most 262,144 bytes per stream
  and return at most 128,000 UTF-8 bytes, in whole rows.
- **Searches are bounded.** [`search_panes`] scans at most 200 panes, 20,000
  lines, 1,000,000 bytes, or five seconds, and says which ceiling truncated it.
- **Long waits report life signs.** With a `progressToken`, a long wait sends
  advisory progress while output has capacity.
- **It will not end the conversation.** Direct teardown tools refuse the pane,
  window, or session the server runs in unless the call passes `force`.

[`wait_for_channel`] is the other blocking tool, and
[`call_read_tools_batch`] keeps a batch's whole response at or below
1,000,000 bytes. The details are in
[`docs/mcp-contract.md`][r-docs-mcp-contract-md-output-budgets-and-deadlines].

### [`tmux://capabilities`][ref-capabilities]: what each tool says about itself

- **Schemas.** Every tool declares native input and output schemas, and carries
  its capability row under `_meta["com.git-pull.libtmux-mcp/capability"]`.
- **One registry.** It drives registration, dispatch, descriptions, filtering,
  and the `tmux://capabilities` report. That static report is the only MCP
  resource; there are no prompts or dynamic templates.
- **Two representations.** Every answer travels as both `structuredContent` and
  JSON text.
- **Consent metadata.** The rows describe a tool for consent and enforce
  nothing. Terminal content, environment values, configured commands, and tmux
  metadata may contain secrets or untrusted instructions.

More in [`docs/mcp-contract.md`][r-docs-mcp-contract-md-capability-metadata].

### Migrating from the earlier MCP surface

Earlier alpha releases used ordered safety tiers and different tool names.
None of these names exists on the frozen 45-tool surface:

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

### [`list_panes`]: what it feels like

> **You:** Which of my panes are sitting in an editor?
>
> **Agent:** Three — `%4` and `%7` are running `nvim`, `%12` is running `vim`.
> `%4` is in `~/work/api`, the other two are in `~/work/web`.

The agent called `list_panes`, selected the rows whose current command was an
editor, and answered from the typed metadata. It did not shell out, parse
`tmux list-panes` output, or guess a format string.

### When it earns its keep

For a single `tmux send-keys`, run tmux.

It earns its keep when something has to be *asked* or *waited for*: which pane
is running the failing test, whether the dev server came up, whether the
session you are about to create already exists.

[`LibTmuxMCP`][mod-libtmuxmcp] is the same tools as a library, to embed in a
server of your own.

## Testing your own code

### [`withTmuxServer`][api-withtmuxserver]: a real tmux for tests

[`TmuxFixture`][mod-tmuxfixture] provisions a private tmux server for a test or
benchmark and reaps it when the body returns, throws, or the process is killed.

`withTmuxServer` hands the body a server with one `bootstrap` session on a
socket under `/tmp/libtmux-swift-test/`:

```swift
try await withTmuxServer { @Sendable server in
    _ = try await server.newSession(named: "work")
    _ = try await server.newSession(named: "build")
    let sessions = try await server.sessions()
    for session in sessions.sorted(by: { $0.name < $1.name }) {
        print("\(session.name): \(session.windowCount) window")
    }
}
```

After `import TmuxFixture`, `ApiExamplesTests` runs this program and compares
what it prints, `bootstrap: 1 window`, `build: 1 window`, and `work: 1 window`,
with the expected output in `Examples/api-examples.json`.

- **Every test uses it.** The suite provisions all its servers this way.
- **Sockets by name.** [`withNamedTmuxServer`][api-withnamedtmuxserver] serves
  the half that addresses a socket by name, and needs `TMUX_TMPDIR` below the
  test root; [`namedSocketsAvailable`][api-namedsocketsavailable] says whether
  it is.

## Products

Six things ship from this one package. Take only what you need — the core has
one dependency, and the YAML reader is behind a trait so you do not pay for it
unless you ask.

| Product | Source | What it is for | Depends on |
| --- | --- | --- | --- |
| **[`LibTmux`][p-lib]** | [`Sources/LibTmux/`][p-lib] | The library. Servers, sessions, windows, panes, options, hooks, filtering, snapshots, streaming. The only one most callers need. | [swift-subprocess][] |
| **[`TmuxWorkspace`][p-ws]** | [`Sources/TmuxWorkspace/`][p-ws] | Builds a session from a [tmuxp][] workspace — written in Swift, JSON, or YAML. See [Workspaces](#workspaces-from-a-file-or-from-swift). | `LibTmux`, and [Yams][] with the `YAMLWorkspaces` trait |
| **[`tmux-workspace`](Sources/TmuxWorkspaceCLI/)** | [`Sources/TmuxWorkspaceCLI/`](Sources/TmuxWorkspaceCLI/) | Partial native workspace CLI: list, search, convert, import, load and capture. The command guide lists remaining work. | `LibTmux`, `TmuxWorkspace`, ArgumentParser, optional Yams |
| **[`LibTmuxMCP`][p-mcp]** | [`Sources/LibTmuxMCP/`][p-mcp] | tmux as [MCP][] tools, as a library you can embed. | `LibTmux`, `TmuxWorkspace` |
| **[`libtmux-mcp`][p-server]** | [`Sources/libtmux-mcp/`][p-server] | The MCP server executable that serves those tools over stdio. See [tmux as MCP tools](#tmux-as-mcp-tools). | `LibTmux`, `LibTmuxMCP` |
| **[`TmuxFixture`][p-test]** | [`Tests/TmuxFixture/`][p-test] | Real-server provisioning and reaping for tests and benchmarks. | `LibTmux` |

Each has its own README with an install snippet, a usage example, and what it
does and does not cover.

[`TmuxWorkspace`][mod-tmuxworkspace] and [`LibTmuxMCP`][mod-libtmuxmcp] are both
written against [`Server`][api-server] and neither mentions a mode, so both work
in every mode.

### [`LibTmux`][dir-libtmux]: the library

Servers, sessions, windows, panes, and clients as values, with options, hooks,
filtering, snapshots, and streaming over them. Reference: the
[API pages][ref-libtmux-reference] on libtmux.org and
[Swift Package Index][spi-libtmux].

[`Server.version()`][api-server-version] reports what the server runs, and
[`TmuxVersion`][api-tmuxversion] compares properly:

```swift
if try await server.version() < TmuxVersion(major: 3, minor: 4) {
    print("this release predates the behaviour relied on below")
}
```

`PlatformSupportTests` runs this against a fixture server.

### [`TmuxWorkspace`][dir-tmuxworkspace]: workspaces from Swift

Builds a session from a [tmuxp][] workspace written in Swift, JSON, or YAML.
Reference: the [API pages][ref-ws-reference] and
[Swift Package Index][spi-workspace].

[`WorkspaceBuilder`][api-workspacebuilder] creates the session for a
[`Workspace`][api-workspace] value, such as the one under
[Workspaces](#workspaces-from-a-file-or-from-swift):

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

### [`tmux-workspace`][dir-tmux-workspace]: the command

Loads, lists, searches, converts, imports, and captures workspaces from a
shell. It is partial; the [command manual][ref-cli] lists what remains.

With a [workspace file][ref-ws-config] saved as `project.yaml`,
[`load`][ref-cli-load] builds it on a tmux socket named `project` without
attaching to it:

```console
$ tmux-workspace load \
    -L project \
    -d \
    project.yaml
```

The [README][cli-readme] has an example for each subcommand.

### [`LibTmuxMCP`][dir-libtmuxmcp]: tmux tools to embed

The tools [`libtmux-mcp`][mod-libtmux-mcp] serves, as a library for a server of
your own. Reference: the [API pages][ref-mcp-reference], [Swift Package
Index][spi-mcp], and one page per [tool][ref-mcp-tools].

[`TmuxTools`][api-tmuxtools] exposes the `inspect` toolset, which reads bounded
state, unless a [`ToolAuthority`][api-toolauthority] says otherwise. This one
exposes [`create_window`] and [`list_sessions`] and nothing else:

```swift
let authority = ToolAuthority(
    toolsets: [],
    includedTools: ["create_window", "list_sessions"]
)
let tools = TmuxTools(server: server, authority: authority)
```

`MCPEmbeddingTests` asserts the exact selection exposes only those two tools.

### [`libtmux-mcp`][dir-libtmux-mcp]: the MCP server

A [Model Context Protocol][MCP] server over stdio, started by an MCP client.
Reference: the [overview][ref-mcp], the [client guide][ref-mcp-guide], and
one page per [tool][ref-mcp-tools].

Register a built binary with Claude Code, limited to the `inspect` toolset:

```console
$ claude mcp add tmux \
    -e LIBTMUX_TOOLSETS=inspect \
    -- /path/to/.build/debug/libtmux-mcp
```

Other clients take the JSON configuration under
[tmux as MCP tools](#tmux-as-mcp-tools).

### [`TmuxFixture`][dir-tmuxfixture]: a real tmux for tests

Provisions a private tmux server for a test or benchmark and reaps it when the
body returns, throws, or the process is killed. Guide:
[Testing with libtmux][ref-guide-testing]. The example is under
[Testing your own code](#testing-your-own-code).


## What it leaves out

- **A terminal.** Nothing here renders or emulates one; it sends commands to
  tmux and reads its answers.
- **Live objects.** A [`Session`][api-session] or a [`Pane`][api-pane] is a
  value of what tmux reported when it was read, and does not change when tmux
  does. Ask again, or subscribe, to see a change.
- **Python's query list and exception hierarchy.** Results are plain arrays and
  one typed [`TmuxError`][api-tmuxerror] replaces the hierarchy.
- **Everything Python libtmux does.** This port follows it where following it
  earns its place, and `Scripts/parity_report.py` names each divergence from its
  recorded API.
- **A signal disposition.** The library does not set `SIGPIPE`; see
  [Platform notes](#platform-notes).
- **A stable API.** Names are still moving and any release may change them;
  see [Support and status](#support-and-status).

## Support and status

The library works and its suite runs against every supported tmux release on
every push, but the API has had no outside use and names are still moving.
Expect to update code when you update the package.

- **The public API can change in any release.** Releases are numbered `0.1.N`,
  each increments `N`, and the changelog marks each break.
- **Pin an exact version** to avoid a break; see [Install](#install).
- **Swift 6 language mode,** with complete strict concurrency and no unsafe
  flags.
- **[`LibTmux`][mod-libtmux] is the part to build on.** It is the largest, the
  most exercised, and the closest to settled.
  [`TmuxWorkspace`][mod-tmuxworkspace] and [`LibTmuxMCP`][mod-libtmuxmcp] are
  newer and thinner, and are likelier to move.
- **The tmux behaviour is the tested part.** Compatibility with 3.3a through
  3.8, and master, is checked in CI against each release built from its own
  tag. The Swift surface around it is what has not settled.

Useful now for a tool you control and can update. Not yet something to put
under a dependency you do not.

| | |
| --- | --- |
| Swift | 6.2 or later |
| Platforms | Linux, including WSL, and macOS (best effort, no CI) — see [Platform notes](#platform-notes) |
| tmux | 3.3a through 3.8, and master; older daemons are refused before any command runs. Connected mode needs 3.7, and a few features name their own release; the [platform page][r-platformsupport-md] lists them with what each refuses below it, and [`capabilities.json`][r-capabilities-json] records the same gates in machine-readable form |
| Dependencies | [swift-subprocess][] for the core; [Yams][] behind a trait, for reading YAML |

### Optional features

A feature that needs more than 3.3a refuses before it does anything, with
`TmuxError.unsupportedTmuxVersion`. None of them raises the floor for the rest
of the library.

| Feature | Needs | Below that |
| --- | --- | --- |
| Connected mode: `Server.connected(attachingTo:_:)`, `Server.using(_:_:)` with a connected mode, `Server.withControlMode(attachingTo:_:)` | 3.7 | refused before any client attaches |
| `Server.waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)` | any | reads the pane on a timer; output that changes no row, such as blank-only output, is not seen |
| `Server.deleteBuffer(named:)` and the MCP `paste_text` staging buffer | 3.4 | refused |
| `break-pane` without a window name, and a name holding `:` or `.` | 3.7a | refused on exactly 3.7 |
| `split-window -p` | 3.5 | refused on exactly 3.4 |
| `select-layout` with a layout tmux cannot parse | 3.4 | refused, because 3.3a crashes on one |
| `refresh-client -l`, the clipboard query | 3.6a | refused |

The [platform page][r-platformsupport-md] gives the detail, including which
command forms are read before they are sent and which are not.

### Platform notes

- **Linux, including WSL.** CI runs Ubuntu against each supported tmux
  release, in parallel.
- **macOS.** Supported on a best-effort basis; CI coverage for it is highly
  limited, as CI runs Linux only.
- **Darwin handling.** None of it varies by tmux release: the `TMPDIR` a socket
  path cannot afford, keg-only libevent and ncurses, and `F_SETNOSIGPIPE`.
- **On Darwin, build with Xcode 26's toolchain.** [swift-subprocess][] needs
  Swift 6.3 and fails to build under a 6.2 toolchain;
  [`CONTRIBUTING.md`][r-github-contributing-md] has the detail.
- **Ignore `SIGPIPE`** in a program that opens connections, because a write to
  a tmux that went away first will otherwise end the process:

```swift
signal(SIGPIPE, SIG_IGN)
```

The library does not set this itself. The disposition is process-wide, and a
library changing it would change how its host behaves at the end of every
pipeline it is in.

This package's own suite makes the call, which is how the need for it is known.

## Documentation

The [DocC][] catalogue is the reference, and covers modes, snapshots,
filtering, streaming, waiting, and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

CI builds it and fails the job on any warning. The same reference is hosted on
libtmux.org:

- [API pages][ref-libtmux-reference], with [guides][ref-guides],
  [concepts][ref-concepts], and [topics][ref-topics] beside them
- [Swift Package Index][spi-libtmux], which documents [`LibTmux`][mod-libtmux],
  [`TmuxWorkspace`][mod-tmuxworkspace], and [`LibTmuxMCP`][mod-libtmuxmcp]
- [`docs/`][r-docs]: the CLI and MCP contracts that are too long for a README

Every Swift example in this file is also code the build compiles, and most of
it is code the suite *runs*:

- **Compiling** catches a call that was renamed.
- **Running** catches one that quietly began answering something else.
- **The live examples** are in [`Examples/`][examples] and run against real
  tmux, on sockets under this suite's own namespace.

```console
$ python3 Scripts/check_examples.py
62 documented examples mapped to consumer sources
55 have live-test call sites
```

That check fails if a fence here has no example behind it. The Examples test
run compiles those sources and exercises the live call sites; CI runs both
gates. [`Examples/README.md`][r-examples] says how a fence is matched, and what
the check cannot see.

## Tests

The suite runs against real tmux — no mocks of the server — one private socket
per case, with servers reaped even when a run is killed outright.

```console
$ swift test --traits YAMLWorkspaces
```

The trait is off by default, and the tests that read YAML run only with it, so
the gate names it.
Point the suite at a particular release to test against that one:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.3a/bin/tmux swift test
```

CI runs the suite on Linux against each of tmux 3.3a, 3.4, 3.5, 3.6, 3.7, 3.7a,
3.7b, 3.8 and master, each built from its own release tarball or, for master,
from a pinned commit.

It also builds 3.0a, 3.1c, 3.2a and the unpatched 3.3 and checks that each is
refused; 3.0a and 3.1c also behind a 3.3a client.

## Repository layout

| Path | What is in it |
| --- | --- |
| [`Sources/`][sources] | The four runtime products |
| [`Tests/`][tests] | The suite, and the [`TmuxFixture`][mod-tmuxfixture] product every suite provisions servers through |
| [`Examples/`][examples] | Every documented example, its own package so they compile as a consumer does — and most run against a live tmux |
| [`Benchmarks/`][benchmarks] | The mode benchmark, its own package so the shipped manifest names only what ships |
| [`Parity/`][parity] | What Python libtmux exposes, recorded, and what this port does about each of it |
| [`Tools/McpSwap/`](Tools/McpSwap/) | The private native MCP config swap utility; its nested package is not shipped |
| `Scripts/` | The Python tooling CI runs |
| `dev/Spikes/` | Disposable experiment packages. Not part of a release |

## Related projects

- [libtmux][] — the Python library this is a port of
- [tmuxp][] — tmux session manager, and the workspace format
  [`TmuxWorkspace`][mod-tmuxworkspace] reads
- [libtmux-mcp][py-mcp] — the Python MCP server for tmux
- [The Tao of tmux][tao] — the book

## Attribution

Please use the following BibTeX template to cite libtmux-swift in scientific
discourse:

```bibtex
@misc{libtmux-swift,
   author = {Tony Narlock},
   year = {2026},
   note = {https://libtmux.org/en/swift/},
   title = {libtmux-swift: Swift wrapper for tmux}
}
```

## License

MIT. See [LICENSE][r-license].

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
[spi-libtmux]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmux
[spi-workspace]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/tmuxworkspace
[spi-mcp]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmuxmcp
[cli-readme]: Sources/TmuxWorkspaceCLI/README.md
[api-client]: https://libtmux.org/en/swift/latest/reference/client/
[api-controlsession-changes-named]: <https://libtmux.org/en/swift/latest/reference/controlsession-changes(named-)/>
[api-controlsession-watch]: <https://libtmux.org/en/swift/latest/reference/controlsession-watch(_-)/>
[api-filterexpr]: https://libtmux.org/en/swift/latest/reference/filterexpr/
[api-formatsubscription]: https://libtmux.org/en/swift/latest/reference/formatsubscription/
[api-namedsocketsavailable]: https://libtmux.org/en/swift/latest/reference/namedsocketsavailable/
[api-outputwait]: https://libtmux.org/en/swift/latest/reference/outputwait/
[api-pane-currentcommand]: https://libtmux.org/en/swift/latest/reference/pane-currentcommand/
[api-pane-currentpath]: https://libtmux.org/en/swift/latest/reference/pane-currentpath/
[api-pane]: https://libtmux.org/en/swift/latest/reference/pane/
[api-paneplan]: https://libtmux.org/en/swift/latest/workspace/reference/paneplan/
[api-regexpattern]: https://libtmux.org/en/swift/latest/reference/regexpattern/
[api-server-buffer-named]: <https://libtmux.org/en/swift/latest/reference/server-buffer(named-)/>
[api-server-capture-includinghistory]: <https://libtmux.org/en/swift/latest/reference/server-capture(_-includinghistory-)/>
[api-server-connected-attachingto]: <https://libtmux.org/en/swift/latest/reference/server-connected(attachingto-_-)/>
[api-server-hassession]: <https://libtmux.org/en/swift/latest/reference/server-hassession(_-)/>
[api-server-mode]: https://libtmux.org/en/swift/latest/reference/server-mode/
[api-server-newsession-named-startdirectory-windowname-width-height]: <https://libtmux.org/en/swift/latest/reference/server-newsession(named-startdirectory-windowname-width-height-)/>
[api-server-newwindow-in-named-startdirectory]: <https://libtmux.org/en/swift/latest/reference/server-newwindow(in-named-startdirectory-)/>
[api-server-panes-where]: <https://libtmux.org/en/swift/latest/reference/server-panes(where-)/>
[api-server-panes]: <https://libtmux.org/en/swift/latest/reference/server-panes()/>
[api-server-refresh]: <https://libtmux.org/en/swift/latest/reference/server-refresh(_-)/>
[api-server-run-in]: <https://libtmux.org/en/swift/latest/reference/server-run(_-in-)/>
[api-server-run]: <https://libtmux.org/en/swift/latest/reference/server-run(_-)/>
[api-server-selectlayout]: <https://libtmux.org/en/swift/latest/reference/server-selectlayout(_-_-)/>
[api-server-session-named]: <https://libtmux.org/en/swift/latest/reference/server-session(named-)/>
[api-server-sessions]: <https://libtmux.org/en/swift/latest/reference/server-sessions()/>
[api-server-setoption-to-scope]: <https://libtmux.org/en/swift/latest/reference/server-setoption(_-to-scope-)/>
[api-server-shellinvocation]: https://libtmux.org/en/swift/latest/reference/server-shellinvocation/
[api-server-snapshot]: <https://libtmux.org/en/swift/latest/reference/server-snapshot()/>
[api-server-using]: <https://libtmux.org/en/swift/latest/reference/server-using(_-_-)/>
[api-server-validatelayouts]: <https://libtmux.org/en/swift/latest/reference/server-validatelayouts(_-)/>
[api-server-version]: <https://libtmux.org/en/swift/latest/reference/server-version()/>
[api-server-wait-for]: <https://libtmux.org/en/swift/latest/reference/server-wait(for-)/>
[api-server-waitforoutput-in-matching-stoppingat-requiringfreshoutput-startingat-timeout-taillimit]: <https://libtmux.org/en/swift/latest/reference/server-waitforoutput(in-matching-stoppingat-requiringfreshoutput-startingat-timeout-taillimit-)/>
[api-server-windows]: <https://libtmux.org/en/swift/latest/reference/server-windows()/>
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[api-serverconfiguration]: https://libtmux.org/en/swift/latest/mcp/reference/serverconfiguration/
[api-session]: https://libtmux.org/en/swift/latest/reference/session/
[api-snapshot]: https://libtmux.org/en/swift/latest/reference/snapshot/
[api-tmuxcommand]: https://libtmux.org/en/swift/latest/reference/tmuxcommand/
[api-tmuxcommandlist]: https://libtmux.org/en/swift/latest/reference/tmuxcommandlist/
[api-tmuxerror]: https://libtmux.org/en/swift/latest/reference/tmuxerror/
[api-tmuxmode-connected-to]: <https://libtmux.org/en/swift/latest/reference/tmuxmode-connected(to-)/>
[api-tmuxmode-direct]: https://libtmux.org/en/swift/latest/reference/tmuxmode-direct/
[api-tmuxmode]: https://libtmux.org/en/swift/latest/reference/tmuxmode/
[api-tmuxtools]: https://libtmux.org/en/swift/latest/mcp/reference/tmuxtools/
[api-tmuxversion]: https://libtmux.org/en/swift/latest/reference/tmuxversion/
[api-toolauthority]: https://libtmux.org/en/swift/latest/mcp/reference/toolauthority/
[api-toolset]: https://libtmux.org/en/swift/latest/mcp/reference/toolset/
[api-window]: https://libtmux.org/en/swift/latest/reference/window/
[api-windowplan]: https://libtmux.org/en/swift/latest/workspace/reference/windowplan/
[api-withnamedtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withnamedtmuxserver(_-)/>
[api-withtmuxerror]: <https://libtmux.org/en/swift/latest/reference/withtmuxerror(_-)/>
[api-withtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withtmuxserver(socketfilename-_-)/>
[api-workspace-decode-json]: <https://libtmux.org/en/swift/latest/workspace/reference/workspace-decode(json-)/>
[api-workspace-decode-yaml]: <https://libtmux.org/en/swift/latest/workspace/reference/workspace-decode(yaml-)/>
[api-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/workspace/
[api-workspacebuilder-build-on]: <https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder-build(_-on-)/>
[api-workspacebuilder]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder/
[dir-libtmux-mcp]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/libtmux-mcp
[dir-libtmux]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/LibTmux
[dir-libtmuxmcp]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/LibTmuxMCP
[dir-tmux-workspace]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspaceCLI
[dir-tmuxfixture]: https://github.com/libtmux/libtmux-swift/tree/master/Tests/TmuxFixture
[dir-tmuxworkspace]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspace
[mod-libtmux-mcp]: https://libtmux.org/en/swift/latest/mcp/
[mod-libtmux]: https://libtmux.org/en/swift/latest/reference/
[mod-libtmuxmcp]: https://libtmux.org/en/swift/latest/mcp/reference/
[mod-tmux-workspace]: https://libtmux.org/en/swift/latest/workspace/cli/
[mod-tmuxfixture]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
[mod-tmuxworkspace]: https://libtmux.org/en/swift/latest/workspace/reference/
[r-docs-mcp-contract-md-capability-metadata]: docs/mcp-contract.md#capability-metadata
[r-docs-mcp-contract-md-default-launch-and-teardown]: docs/mcp-contract.md#default-launch-and-teardown
[r-docs-mcp-contract-md-output-budgets-and-deadlines]: docs/mcp-contract.md#output-budgets-and-deadlines
[r-docs-mcp-contract-md-pane-input]: docs/mcp-contract.md#pane-input
[r-docs-mcp-contract-md-pane-modes]: docs/mcp-contract.md#pane-modes
[r-docs]: docs/
[r-examples]: Examples/
[r-github-contributing-md]: .github/CONTRIBUTING.md
[r-platformsupport-md]: Sources/LibTmux/LibTmux.docc/PlatformSupport.md
[r-capabilities-json]: capabilities.json
[r-license]: LICENSE
[ref-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
[ref-cli-load]: https://libtmux.org/en/swift/latest/workspace/cli/load/
[ref-cli]: https://libtmux.org/en/swift/latest/workspace/cli/
[ref-concept-queries]: https://libtmux.org/en/swift/latest/concepts/queries/
[ref-concepts]: https://libtmux.org/en/swift/latest/concepts/
[ref-guide-testing]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
[ref-guides]: https://libtmux.org/en/swift/latest/guides/
[ref-libtmux-reference]: https://libtmux.org/en/swift/latest/reference/
[ref-mcp-guide]: https://libtmux.org/en/swift/latest/mcp/guides/
[ref-mcp-reference]: https://libtmux.org/en/swift/latest/mcp/reference/
[ref-mcp-tools]: https://libtmux.org/en/swift/latest/mcp/tools/
[ref-mcp]: https://libtmux.org/en/swift/latest/mcp/
[ref-topic-waiting]: https://libtmux.org/en/swift/latest/topics/waiting-and-retry/
[ref-topics]: https://libtmux.org/en/swift/latest/topics/
[ref-ws-config]: https://libtmux.org/en/swift/latest/workspace/configuration/
[ref-ws-reference]: https://libtmux.org/en/swift/latest/workspace/reference/
[`call_read_tools_batch`]: https://libtmux.org/en/swift/latest/mcp/tools/call_read_tools_batch/
[`capture_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_pane/
[`capture_since`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_since/
[`clear_pane_scrollback`]: https://libtmux.org/en/swift/latest/mcp/tools/clear_pane_scrollback/
[`create_session`]: https://libtmux.org/en/swift/latest/mcp/tools/create_session/
[`create_window`]: https://libtmux.org/en/swift/latest/mcp/tools/create_window/
[`find_pane_by_position`]: https://libtmux.org/en/swift/latest/mcp/tools/find_pane_by_position/
[`get_pane_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_pane_info/
[`get_server_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_server_info/
[`get_session_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_session_info/
[`get_tmux_variables`]: https://libtmux.org/en/swift/latest/mcp/tools/get_tmux_variables/
[`get_window_info`]: https://libtmux.org/en/swift/latest/mcp/tools/get_window_info/
[`kill_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/kill_pane/
[`kill_session`]: https://libtmux.org/en/swift/latest/mcp/tools/kill_session/
[`kill_window`]: https://libtmux.org/en/swift/latest/mcp/tools/kill_window/
[`list_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/list_panes/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
[`list_windows`]: https://libtmux.org/en/swift/latest/mcp/tools/list_windows/
[`move_window`]: https://libtmux.org/en/swift/latest/mcp/tools/move_window/
[`paste_text`]: https://libtmux.org/en/swift/latest/mcp/tools/paste_text/
[`rename_session`]: https://libtmux.org/en/swift/latest/mcp/tools/rename_session/
[`rename_window`]: https://libtmux.org/en/swift/latest/mcp/tools/rename_window/
[`resize_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/resize_pane/
[`resize_window`]: https://libtmux.org/en/swift/latest/mcp/tools/resize_window/
[`respawn_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/respawn_pane/
[`run_shell_command`]: https://libtmux.org/en/swift/latest/mcp/tools/run_shell_command/
[`search_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/search_panes/
[`select_layout`]: https://libtmux.org/en/swift/latest/mcp/tools/select_layout/
[`select_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/select_pane/
[`select_window`]: https://libtmux.org/en/swift/latest/mcp/tools/select_window/
[`send_keys_batch`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys_batch/
[`send_keys`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys/
[`set_history_limit`]: https://libtmux.org/en/swift/latest/mcp/tools/set_history_limit/
[`set_mouse_enabled`]: https://libtmux.org/en/swift/latest/mcp/tools/set_mouse_enabled/
[`set_pane_title`]: https://libtmux.org/en/swift/latest/mcp/tools/set_pane_title/
[`set_synchronize_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/set_synchronize_panes/
[`show_environment`]: https://libtmux.org/en/swift/latest/mcp/tools/show_environment/
[`show_hooks`]: https://libtmux.org/en/swift/latest/mcp/tools/show_hooks/
[`show_option`]: https://libtmux.org/en/swift/latest/mcp/tools/show_option/
[`signal_channel`]: https://libtmux.org/en/swift/latest/mcp/tools/signal_channel/
[`snapshot_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/snapshot_pane/
[`split_window`]: https://libtmux.org/en/swift/latest/mcp/tools/split_window/
[`swap_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/swap_pane/
[`wait_for_channel`]: https://libtmux.org/en/swift/latest/mcp/tools/wait_for_channel/
[`wait_for_text`]: https://libtmux.org/en/swift/latest/mcp/tools/wait_for_text/
