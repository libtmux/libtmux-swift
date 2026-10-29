# Platform support

What has been exercised, and what has not.

## Overview

The package supports tmux releases 3.3a through 3.8, and master, on Linux
(including WSL) and, on a best-effort basis, macOS. CI runs Linux only. A
daemon older than 3.3a is refused before the command that reached it has any
effect.

tmux release candidates are not supported: a feature can require one only until
its release ships, and ``TmuxVersion`` ranks a candidate such as `X.Y-rcN` below
`X.Y`. See [Release candidates](https://libtmux.org/en/tmux/guides/tmux-support/#release-candidates).

The test suite runs against real tmux, one private server and socket per case.
Every supported release is exercised on Linux, individually and concurrently.
No job builds or tests on macOS, so a macOS-only regression is not caught
before merge; run the suite on a Mac when a change touches Darwin handling.
Releases below the floor are built too, to show they are refused.

## Which release decides

The release that decides is the daemon's, not the client's. Before a server
sends anything it asks the daemon at its endpoint which release it is, refuses
one older than 3.3a with
``TmuxError/unsupportedTmuxVersion(reported:required:operation:)``, and holds
every command it sends to that release, so a daemon replaced in between refuses
the command instead of running it. Where nothing listens yet, the executable
that would start the daemon is held to the same floor. The question is asked in
a way that fires none of a configuration's hooks.

A refusal means nothing was sent. The remedy is to upgrade tmux and restart the
server, or to pin the previous libtmux release. A daemon older than 3.2 has no
`run-shell -C`, so the question itself fails there; that failure is read as the
same refusal (reported as "older than 3.2"). A report that names no release,
such as `master`, `openbsd-7.6` or `3.3a-dev`, is refused as unrecognized, not
as a release below the floor.

## Features that need a newer release

A feature that needs more than 3.3a says so by itself and refuses before it
does anything; none of them raises the floor for the rest of the library. The
refusal is ``TmuxError/unsupportedTmuxVersion(reported:required:operation:)``,
decided from the daemon's release.

| Feature | Needs | Below that | State |
| --- | --- | --- | --- |
| ``Server/connected(attachingTo:_:)``, ``Server/using(_:_:)`` with ``TmuxMode/connected(to:)``, ``Server/withControlMode(attachingTo:_:)`` and everything on a ``ControlSession`` | 3.7 | refused before any client attaches | Qualified on 3.7 and newer in the suites run; refused below |
| ``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)`` | any | reads the pane on a timer instead of streaming | Operative with synchronization: output that changes no row, such as blank-only output, is not seen |
| ``Server/deleteBuffer(named:)`` and the MCP `paste_text` staging buffer | 3.4 | refused; `paste_text` refuses before it stages a buffer | Qualified from 3.4; refused below |
| `break-pane` without a window name, and a name holding `:` or `.` | 3.7a | refused on exactly 3.7; ``Server/breakPane(_:from:named:)`` supplies a name there | Qualified on 3.7 and 3.7a |
| `split-window -p` | 3.5 | refused on exactly 3.4; the typed splits send `-l N%` | Qualified |
| `select-layout` with a layout tmux cannot parse | 3.4 | refused before it is sent, because 3.3a crashes on one | Qualified on 3.3a |
| `refresh-client -l`, the clipboard query | 3.6a | refused before it is sent, because a 3.3a server exits at once with an attached client whose terminal has the `Ms` clipboard capability, such as `xterm-256color` or `tmux-256color`, and a 3.4 through 3.6 server exits when that client leaves before its terminal answers | Qualified on 3.3a through 3.6 |
| A JSON layout in ``Server/selectLayout(_:_:)`` and ``Server/validateLayouts(_:)``, the MCP `select_layout` tool and a raw `select-layout` | 3.8 | refused before it is sent | Qualified on 3.8; refused below |
| `switch-mode` | 3.8 | tmux rejects it as an unknown command below 3.8; the library does not resolve it | Qualified on 3.8; tmux rejects it below |

Tmux 3.2a and 3.6b servers crash when a control client attaches and detaches
quickly, which is why the release is checked before attaching and not after.

### Which commands are read

A command sent as arguments is read before it is sent, on every path that
takes one: ``Server/run(_:)-(TmuxCommand)``, a ``TmuxCommandList`` run on a server, a server
handed out by ``Server/connected(attachingTo:_:)`` or ``Server/using(_:_:)``,
the typed methods that wrap a command in a guard, and
``ControlSession/send(_:)``.

The name is resolved the way tmux resolves it, so `break-pane`, its alias
`breakp`, and any unique prefix such as `break-p` or `br` are the same command.
The default `command-alias` spellings of `split-window`, `split-pane` and
`splitp`, are read too. A name that tmux rejects as unknown or ambiguous, such
as `b`, is left for tmux to reject. A `;`-separated list is read command by
command, and flags are read the way tmux reads them: bundled, with the value
joined or in the next argument, up to the first operand.

Nested tmux command strings are outside this guard. Any command that takes tmux
commands as text is in this group. For example, the body of `if-shell`,
`run-shell -C` and `confirm-before`, the template of `command-prompt`,
`display-menu` and the `choose-*` commands, a file named to `source-file`, a
brace block, the command of a hook (``Server/setHook(_:to:at:in:)``) or a key
binding, and a `command-alias` the caller sets. They reach the daemon unread, so
do not nest a command that the table above refuses. A shell command is the
caller's own program, and is not read either.

What reaches tmux this way, and what it does there, by command:

| Command | Releases | What happens |
| --- | --- | --- |
| `break-pane` without `-n` | exactly 3.7 | the server exits; 3.7a does not |
| `select-layout` with a layout tmux cannot parse | 3.3 and 3.3a | the server exits; 3.4 answers "invalid layout" |
| `refresh-client -l` | 3.3a, and 3.4 through 3.6 | 3.3a exits at once with an attached client whose terminal has the `Ms` clipboard capability, such as `xterm-256color` or `tmux-256color`; 3.4 through 3.6 exit when that client leaves before its terminal answers |
| `delete-buffer -b NAME` and `set-buffer -b NAME -n` | below 3.4 | a name that does not exist acts on the newest buffer instead, silently |
| `split-window -p` | exactly 3.4 | tmux answers with an error and nothing changes |
| `:` or `.` in a session or window name | exactly 3.7 | tmux answers with an error and nothing changes |

On exactly tmux 3.7, name every `break-pane`, nested or not, or upgrade to
3.7a. A nested `if-shell -F 1 'break-pane -d'` passes the guard unchanged, and
`FeatureGateTests` pins that.

``Server/version()`` reports which tmux executable a server runs, and answers
for any release because it is a diagnostic rather than a version check.
``TmuxVersion`` orders releases the way tmux issues them, including the point
release's letter, because `3.7` and `3.7a` differ in behaviour and comparing on
the numbers alone would call them equal:

```swift
if try await server.version() < TmuxVersion(major: 3, minor: 4) {
    print("this release predates the behaviour relied on below")
}
```

Where releases differ in ways you can see, they are named where the behaviour
is described rather than collected here; <doc:Modes> carries the one that
affects pane sizes.

## A broken pipe is your program's call, not this library's

``Server/connected(attachingTo:_:)`` writes to a tmux it started. If that tmux
goes away first — the session it attached to was killed, or the server shut
down — the write reaches a pipe with no reader, and the kernel raises SIGPIPE.
Its default action is to end the process, so a program that has not said
otherwise can be terminated by tmux going away underneath it.

A pipe offers no portable way to ask for this per descriptor: `MSG_NOSIGNAL` is
for sockets and `F_SETNOSIGPIPE` is Darwin's alone. What is left is the
process-wide disposition, and a library setting that would change how a host
behaves at the end of every pipeline it is in — so this library does not set it.

A program that opens connections should choose:

```swift
signal(SIGPIPE, SIG_IGN)
```

With SIGPIPE ignored, the write reports `EPIPE` instead. An in-flight command
reports ``TmuxError/connectionClosed``; a later call that never entered the
write queue reports ``TmuxError/requestNotSubmitted``. This package's own test
suite ignores SIGPIPE; without that, a run can end by a signal rather than by a
failing case.
