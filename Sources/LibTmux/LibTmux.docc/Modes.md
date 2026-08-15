# Choosing how work reaches tmux

Every call works the same way whichever mode carries it. You write
`server.sessions()` and get `[Session]` back; the mode decides whether that
crossed a process boundary or a connection that was already open.

## The dials

Three, and they turn independently:

| Dial | What it changes | How you turn it | Where it works |
| --- | --- | --- | --- |
| Mode | Whether work crosses a process or a connection | ``Server/using(_:_:)`` | Everywhere |
| Chaining | Whether a run of commands costs one invocation or many | ``TmuxCommandList`` | Either mode |
| Streaming | Whether you ask or are told | ``ControlSession/notifications`` | Connected only |

Concurrency is not on this list because it is not this library's to offer:
`async let` over a connected server pipelines commands, and over a direct one
spawns processes side by side, without either being a setting.

Only the third dial is restricted, and the compiler is what restricts it —
``ControlSession`` exists only inside the scope that opened a connection, so a
`%output` reader against a server that has none does not compile rather than
failing at runtime. The other two combine freely: a command list over a
connection costs one process for any number of commands.

## The modes

``TmuxMode`` is the dial, and it has two settings:

| Mode | How work travels | Where it wins |
| --- | --- | --- |
| ``TmuxMode/direct`` | A tmux process per call | One call, or calls far apart. The default |
| ``TmuxMode/connected(to:)`` | One live connection for the whole scope | More than one call, and anything that wants to be told what changed |

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

The calls inside are the calls you would write anyway, and hand back what they
would hand back anyway. ``Server/run(_:)-(TmuxCommand)`` is still one step away
when you want to send tmux something this library does not model.

Because the mode is a value, a program that decides at runtime writes the
decision rather than two shapes of code:

```swift
let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
let sessions = try await server.using(mode) { server in
    try await server.sessions()
}
```

``Server/connected(attachingTo:_:)`` is ``Server/using(_:_:)`` with the
connection handed over as well, for the one thing a process cannot do — see
<doc:Streaming>.

## Which server is in which mode, in order of precedence

A mode belongs to the server value, not to the process and not to the task, so
the rule is lexical and it is this whole list:

1. **The value you were handed.** ``Server/using(_:_:)`` and
   ``Server/connected(attachingTo:_:)`` give you a server in that mode, and
   nesting them takes the innermost — `using(.direct)` inside a connected scope
   is the supported way to keep one call off the connection.
2. **Anything else is ``TmuxMode/direct``**, including a server captured from
   outside the closure. Shadowing the name — `{ server in ... }` — is what keeps
   the two from being confused.
3. **Two calls take their own process regardless**, listed below, and they do it
   to keep this list's promise rather than to break it.

Nothing is global, nothing is inherited by a task, and there is no setting to
consult. ``Server/mode`` reports which one a value carries, so the rule can be
read rather than trusted. Two servers on the same socket in different modes are
the same tmux and compare equal.

The two calls behind rule 3 are these, and each takes its own process precisely
so that what comes back does not depend on the mode you picked.

``Server/wait(for:)`` blocks, and tmux runs a control client's commands one at a
time — so carried over the connection it would hold back every command behind
it, ``Server/signal(_:)`` included, and nothing would be left to release it. In
a process of its own it returns the same nothing, at the same moment, in either
mode.

``Server/buffer(named:)`` reads bytes, and a connection reports lines. tmux
writes a buffer out and then terminates the block, so a buffer ending in a
newline arrives looking exactly like a listing whose last row is empty, and
nothing on the wire separates the two. Every supported release does this, so the
bytes are read from a process rather than guessed at.
``Server/loadBuffer(from:named:)`` is the way in from a connected server: a path
fits on a command line where the text may not.

## Batching is what these two compose into

There is no third switch. A batch is what you get by asking for more than one
thing at a time over a connection — Swift's own concurrency, carrying commands
that pipeline instead of queueing:

```swift
let (sessions, panes) = try await server.connected(attachingTo: "main") { server, _ in
    async let sessions = server.sessions()
    async let panes = server.panes()
    return try await (sessions, panes)
}
```

When you have a run of commands whose intermediate answers you do not need,
``TmuxCommandList`` says so directly, and one invocation carries the lot:

```swift
var plan = TmuxCommandList()
for name in ["edit", "test", "logs"] {
    plan = plan.then("new-window", ["-d", "-n", name])
}
_ = try await server.run(plan)
```

Both work in either mode. Combined with a connection, a list costs one process
for any number of commands.

## What each mode costs

Measured by `swift run --package-path Benchmarks libtmux-bench`, which runs each scenario under each mode
behind a shim standing in for the tmux binary. The shim counts two things: a
process every time one starts, and a round trip every time a command line is
handed over — as argv, or as a line written to a control client. Neither count
needs the library's cooperation, which is what keeps them evidence.

The table below is written by that benchmark rather than transcribed from it —
`Scripts/update_mode_matrix.py` refreshes it, and `--check` says whether it has
gone stale. Both counts are recorded because both are exact and repeat every
run. The benchmark also reports timings, which are medians that move with the
machine; run it yourself for those.

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

Read down the two columns and the trade is exact. Directly, a round trip *is* a
process, so the numbers in that column always agree. Connecting collapses the
processes to one and charges a single extra round trip, the attach — every
connected row is its direct row plus one. So a single call is the row where the
default wins, since that one round trip buys nothing back, and from the second
call onward the connection is ahead by every process it did not start.

Round trips are also the only place the chaining dial is visible. Under a
connection, five separate `new-window` commands and one command list carrying
the same five both cost one process — compare those two rows and it is the round
trips that tell them apart.

The same benchmark measures being told against asking, which is the other half
of the choice — see <doc:Streaming>. Those two rows are polling's best case: the
line was already on screen when the first capture ran, which is why polling
spends a process for the command and one more for the capture that found it.
Each tick it does not get away with is another of both. Streaming pays for its
connection once, and the waiting itself costs nothing however long it lasts.

## Anything taking a server takes the mode with it

Code written against `Server` needs no knowledge of modes, and gains one by
being handed a connected server. Both consumers in this repository are built
that way and neither mentions a mode:

```swift
let session = try await server.connected(attachingTo: "main") { server, _ in
    try await WorkspaceBuilder.build(workspace, on: server)
}
```

A workspace built this way is the same workspace: the same windows, the same
panes, split the same way. The same holds for the MCP tools — same request, same
JSON.

Pane *heights* are the exception, and they are tmux's call rather than this
library's: attaching is how tmux decides how tall a session is, so panes built
over a connection can differ by the status line's row. On tmux 3.2a they do;
from 3.3a on they do not.

## The one argument a connection will not take

A process is handed an argument vector, where a newline is just a byte. A
connection is handed a command *line*, where it is the end of the command — so
an argument carrying one would leave the rest to be read as the next command,
and tmux would answer the truncated version successfully.

No quoting avoids it: tmux's single quotes leave the newline where it is, and
its double quotes carry it as `\n` only by also expanding any `#` or `$` in the
value, with no escape for `#`. So a connection refuses such an argument rather
than sending part of it. Nothing else in this library changes shape by mode.

## What a connection cannot hide

A control connection is a client, and tmux has no client attached to nothing — a
control client with no target runs tmux's default command and *creates* a
session. So ``Server/connected(attachingTo:_:)`` attaches to a session you name,
and that is visible in what the server reports about itself: that session reads
as attached, and it appears in ``Server/clients()``. Every other answer is
identical, including ids, ordering, and non-ASCII names.
