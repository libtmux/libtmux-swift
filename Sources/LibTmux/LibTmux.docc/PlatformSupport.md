# Platform support

What has been exercised, and what has not.

## Overview

The package builds and runs its real-server suite on Linux and macOS. It
supports tmux releases 3.3a through 3.7b. A daemon older than 3.3a is
refused before the command that reached it has any effect.

The test suite runs against real tmux, one private server and socket per case.
Every supported release is exercised on Linux, individually and concurrently.
The macOS lane exercises both ends of the supported range, 3.3a and 3.7b, with
Xcode's toolchain and Homebrew's keg-only libraries. Releases below the floor
are built too, to show they are refused.

## Which release decides

The release that decides is the daemon's, not the client's. Before a server
sends anything it asks the daemon at its endpoint which release it is, refuses
one older than 3.3a with ``TmuxError/unsupportedTmuxVersion(reported:required:operation:)``,
and holds every command it sends to that release, so a daemon replaced in
between refuses the command instead of running it. Where nothing listens yet,
the executable that would start the daemon is held to the same floor. The
question is asked in a way that fires none of a configuration's hooks.

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

Tmux 3.2a and 3.6b servers crash when a control client attaches and detaches
quickly, which is why the release is checked before attaching and not after. A
literal batch is read for these commands when it is sent as arguments; a shell
command, an `if-shell` body or a configured alias is the caller's own program
and is not read.

``Server/version()`` reports which tmux executable a server runs, and answers
for any release because it is a diagnostic rather than a version check.
``TmuxVersion`` orders releases the way tmux issues them — including the point release's
letter, because `3.7` and `3.7a` differ in behaviour and comparing on the
numbers alone would call them equal:

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
suite ignores SIGPIPE; without that, roughly one full run in ten ended by a
signal rather than by a failing case.
