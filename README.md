# libtmux for Swift

Drive tmux from Swift. A port of [libtmux][] for Python, in the same family of
ports and holding to what that library established about tmux.

```swift
import LibTmux

let server = try Server(socketPath: "/tmp/work.sock")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

You address a server, ask it what exists, and send it commands. Everything that
comes back is a value — a `Session` you hold is what the server looked like when
you asked, not a live handle that changes under you. Ask again for a newer view.

> [!WARNING]
> **Alpha.** The API can change in any release, with no deprecation first.
> Pin an exact version. See [Project status](#project-status).

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
`Sendable` and `Codable` values, that every call states what it throws, and that
the package builds under Swift 6 language mode with complete strict concurrency
and no unsafe flags.

**Not yet, if** you need a stable API. Nothing is tagged and names are still
moving — see [Project status](#project-status).

**No, if** you want to render or emulate a terminal. This talks to tmux; it does
not draw one.

## Products

Four things ship from this one package. Take only what you need — the core has
one dependency, and the YAML reader is behind a trait so you do not pay for it
unless you ask.

| Product | Source | What it is for | Depends on |
| --- | --- | --- | --- |
| **[`LibTmux`][p-lib]** | [`Sources/LibTmux/`][p-lib] | The library. Servers, sessions, windows, panes, options, hooks, filtering, snapshots, streaming. The only one most callers need. | [swift-subprocess][] |
| **[`TmuxWorkspace`][p-ws]** | [`Sources/TmuxWorkspace/`][p-ws] | Builds a session from a [tmuxp][] workspace — written in Swift, JSON, or YAML. See [Workspaces](#workspaces-from-a-file-or-from-swift). | `LibTmux`, and [Yams][] with the `YAMLWorkspaces` trait |
| **[`LibTmuxMCP`][p-mcp]** | [`Sources/LibTmuxMCP/`][p-mcp] | tmux as [MCP][] tools, as a library you can embed. | `LibTmux` |
| **[`libtmux-mcp`][p-server]** | [`Sources/libtmux-mcp/`][p-server] | The MCP server executable that serves those tools over stdio. See [tmux as MCP tools](#tmux-as-mcp-tools). | `LibTmux`, `LibTmuxMCP` |

Each has its own README with an install snippet, a usage example, and what it
does and does not cover.

`TmuxWorkspace` and `LibTmuxMCP` are both written against `Server` and
neither mentions a mode, which is how the mode switch below is kept honest.

## Install

Nothing is tagged yet, so depend on the branch:

```swift
.package(url: "https://github.com/libtmux/libtmux-swift.git", branch: "master")
```

```swift
.product(name: "LibTmux", package: "libtmux-swift")
```

Every tag until `0.1.0` will be a prerelease, and a prerelease has to be named
exactly. `from: "0.1.0"` matches none of them — SwiftPM keeps prereleases out
of a range whose bound has none — and `from: "0.1.0-alpha.1"` errs the other
way, resolving forward into `0.2.0-alpha.1` and every prerelease after it.
Neither is what you want from alpha software, so name the one you tested:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.1"
)
```

Reading a workspace from YAML needs a YAML parser, and asking for it is what
pulls one in. Without the `YAMLWorkspaces` trait nothing here resolves Yams;
with it, `Workspace.decode(yaml:)` exists:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.1",
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

### One consistent picture

Three listings are three moments. `snapshot()` takes one, and the relationships
are resolved inside it rather than by matching ids yourself:

```swift
let snapshot = try await server.snapshot()
for window in snapshot.windows(of: session) {
    print(window.name, snapshot.panes(of: window).count)
}
```

## Change what is there

```swift
let session = try await server.newSession(named: "work", windowName: "editor")
let logs = try await server.newWindow(in: session, named: "logs")
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
| new-window five times, each its own command | 12 processes, 12 round trips | 1 process, 13 round trips |
| the same five as one command list | 3 processes, 3 round trips | 1 process, 4 round trips |
| new-window then split, read back | 6 processes, 6 round trips | 1 process, 7 round trips |

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
try await server.connected(attachingTo: "work") { server, events in
    for await notification in events.notifications
    where notification.name == "output" {
        print(notification.arguments)
    }
}
```

## Workspaces, from a file or from Swift

`TmuxWorkspace` builds a whole session in one go, from a [tmuxp][] workspace.
Written in Swift, it is ordinary values:

```swift
Workspace(
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
callers building the same workspace should not silently share one.

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
| `LIBTMUX_SOCKET` | `default` | The socket *name*, in tmux's own socket directory |
| `LIBTMUX_TMUX_BIN` | `tmux` | The tmux to run — a bare name is resolved on `PATH`, or give a path |

Both are optional; with neither set it serves the `default` socket through the
first `tmux` on `PATH`. Anything the server wants to tell a human goes to
stderr, because stdout is the protocol and a stray line there corrupts it.

`LIBTMUX_SOCKET` is a name rather than a path, and tmux resolves a name inside
`TMUX_TMPDIR`. Set that in the same `env` block when your tmux keeps its sockets
somewhere other than the default, and the name will mean the same server to this
package that it means to you.

| Tool | What it does |
| --- | --- |
| `list_sessions` | Every session, optionally selected by what its panes run |
| `list_windows` | Every window on the server |
| `list_panes` | Every pane, optionally filtered |
| `describe_filters` | The filterable fields, their types, and their aliases |
| `read_format` | Evaluates a tmux format, reaching fields the listings do not carry |
| `run_command` | Runs one tmux command and returns what tmux said |

`describe_filters` is what makes the rest usable: a client that does not speak
Swift learns the filterable vocabulary from it, instead of hard coding field
names that a rename would break.

### What it feels like

> **You:** Which of my panes are sitting in an editor?
>
> **Agent:** Three — `%4` and `%7` are running `nvim`, `%12` is running `vim`.
> `%4` is in `~/work/api`, the other two are in `~/work/web`.

The agent asked `describe_filters` what a pane can be filtered on, then
`list_panes` with `currentCommand in [nvim, vim]`. It did not shell out, parse
`tmux list-panes` output, or guess a format string.

### When it earns its keep

For a single `tmux send-keys`, it does not — run tmux. It earns its keep when
something has to be *asked* rather than done: which pane is running the failing
test, what a long process last printed, whether the session you are about to
create already exists. The filter vocabulary travels to the client, so those
questions are answered in one call instead of a listing plus a regex.

`LibTmuxMCP` is the same tools as a library, if you would rather embed them in a
server of your own than run this one.

## Project status

**Alpha.** The library works and its suite runs against eight tmux releases on
every push, but nothing is tagged, the API has had no outside use, and names
are still moving. Expect to update code when you update the package.

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
| Platforms | Linux. macOS is written but does not currently build — see [Platform notes](#platform-notes) |
| tmux | 3.2a through 3.7b |
| Dependencies | [swift-subprocess][] for the core; [Yams][] behind a trait, for reading YAML |

## Documentation

The [DocC][] catalogue is the reference, and covers modes, snapshots, filtering,
streaming, and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

CI builds it and fails the job on any warning.

Every Swift example in this file is also code the build compiles, and most of
it is code the suite *runs*. Compiling catches a call that was renamed; only
running catches one that quietly began answering something else — so the
examples that can address a live server are kept in `ReadmeExampleTests.swift`
and executed against real tmux, on sockets under this suite's own namespace.

```console
$ python3 Scripts/check_examples.py
32 documented examples, each compiled; 18 of them run against a real tmux
```

That check fails if a fence here appears in neither place, so what you read
above is what the compiler accepted and, mostly, what tmux actually did.

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
| [`Sources/`][sources] | The four products |
| [`Tests/`][tests] | The suite, and the fixture every suite provisions servers through |
| [`Snippets/`][snippets] | Every documented example, compiled by `swift build` |
| [`Benchmarks/`][benchmarks] | The mode benchmark, its own package so the shipped manifest names only what ships |
| [`Parity/`][parity] | What Python libtmux exposes, recorded, and what this port does about each of it |
| `Scripts/` | The Python tooling CI runs |
| `dev/Spikes/` | Disposable experiment packages. Not part of a release |

## Platform notes

Linux is where this runs: the suite passes there against every supported tmux
release, sequentially and eight ways in parallel.

**macOS does not build at present, and it is not this package's doing.**
[swift-subprocess][] 1.0.0 — its only release — has a `run` overload taking a
`borrowing Span` and calling `.bytes` on it, both macOS 26 API carrying no
availability guard. Nothing here calls that overload, but a module compiles as
a whole, and SwiftPM compiles a dependency at *that dependency's* declared
minimum rather than the root package's, so no deployment target set here can
reach it. It is fixed by a release upstream and by nothing else.

The Darwin-specific handling is written and reviewed — the `TMPDIR` a socket
path cannot afford, keg-only libevent and ncurses, `F_SETNOSIGPIPE` — and the
macOS lane is commented out in the workflow rather than deleted, ready to
uncomment the day upstream moves.

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
[snippets]: Snippets/
[benchmarks]: Benchmarks/
[parity]: Parity/
[p-lib]: Sources/LibTmux/
[p-ws]: Sources/TmuxWorkspace/
[p-mcp]: Sources/LibTmuxMCP/
[p-server]: Sources/libtmux-mcp/
[py-mcp]: https://libtmux-mcp.git-pull.com
[tao]: https://leanpub.com/the-tao-of-tmux
[filtering]: Sources/LibTmux/LibTmux.docc/Filtering.md
