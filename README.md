# LibTmux

Drive tmux from Swift.

You address a server, ask it what exists, and send it commands. Everything that
comes back is a value — a `Session` you hold is what the server looked like when
you asked, not a live handle that changes under you. Ask again for a newer view.

```swift
import LibTmux

let server = try Server(socketPath: "/tmp/work.sock")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

Every type that crosses your API is `Sendable` and `Codable`, every call states
what it throws, and the mutable part — the process boundary, the live
connection — sits behind an actor the value shares. The package builds under
Swift 6 language mode with complete strict concurrency and no unsafe flags.

## Requirements

| | |
| --- | --- |
| Swift | 6.2 or later |
| Platforms | macOS 13+, Linux |
| tmux | 3.2a through 3.7b |
| Dependencies | [swift-subprocess][] for the core; [Yams][] behind a trait, for reading YAML |

[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
[Yams]: https://github.com/jpsim/Yams

## Adding it to a project

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

[libtmux]: https://github.com/tmux-python/libtmux

## Products

| Product | What it is for |
| --- | --- |
| `LibTmux` | The library. One dependency, and the only one most callers need. |
| `WorkspaceBuilder` | Builds a session from a [tmuxp][] workspace, written in Swift or JSON — or in YAML, with the `YAMLWorkspaces` trait. |
| `LibTmuxMCP` | tmux as MCP tools, and `libtmux-mcp` is the server that serves them. |

[tmuxp]: https://tmuxp.git-pull.com/

Both consumers are written against `Server` and neither mentions a mode, which
is how the mode switch below is kept honest.

## One switch changes how work reaches tmux, never what you get back

`TmuxMode` is the dial, and it has two settings:

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

The calls inside are the same calls and return the same types. A mode decides
whether work crosses a process boundary or a connection that is already open —
never what the caller receives. `run(_:)` is one step away in either mode, for
anything this library does not model.

Because the mode is a value rather than a shape of call, a program that decides
at runtime writes the decision:

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

`swift run --package-path Benchmarks libtmux-bench` runs each scenario under each mode behind a shim
standing in for the tmux binary, counting a process every time one starts and a
round trip every time a command line is handed over. The table below is written
by that benchmark rather than transcribed from it —
`Scripts/update_mode_matrix.py --check` fails if it has drifted, and CI runs that
check.

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

## Filtering that travels

Filter with the standard library when the predicate is local to your code.
`FilterExpr` is for when the filter has to leave it — stored in a config, sent to
another process, handed to a tool. It is built from key paths, so the compiler
rejects a text operator on a number, and it holds no closures, so it encodes:

```swift
let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
let matching = try await server.panes().filter(expression)
```

## Documentation

The DocC catalogue is the reference, and covers modes, snapshots, filtering,
streaming, and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

CI builds it and fails the job on any warning.

## Tests

The suite runs against real tmux — no mocks of the server — one private socket
per case, with servers reaped even when a run is killed outright.

```console
$ swift test
```

Point it at a particular release to test against that one:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.2a/bin/tmux swift test
```

CI runs the suite on Linux and macOS against each of tmux 3.2a, 3.3a, 3.4, 3.5,
3.6, 3.7, 3.7a, and 3.7b, each built from its own release tarball.

## What has been exercised, and what has not

Linux is where this has run: the suite passes there against every supported tmux
release, sequentially and eight ways in parallel. macOS is supported and the
Darwin-specific handling is written, but the suite has not yet been run there.

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

This is a port in the same repository as [libtmux][] for Python, and follows it
where following it earns its place. Where Swift wants something else, it gets
something else: results are plain arrays rather than a query list, a single
typed `TmuxError` replaces an exception hierarchy, and objects are values rather
than live handles. `Scripts/parity_report.py` measures the surface against
Python's recorded API and names each divergence, so a difference reads as a
decision rather than an omission.

## License

MIT, the same as the rest of the repository.
