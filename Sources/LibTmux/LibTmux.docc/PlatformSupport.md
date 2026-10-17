# Platform support

What has been exercised, and what has not.

## Overview

The package builds and runs its real-server suite on Linux and macOS. It
supports tmux releases 3.3a through 3.8, and master. A daemon older than
3.3a is refused before the command that reached it has any effect.

The test suite runs against real tmux, one private server and socket per case.
Every supported release is exercised on Linux, individually and concurrently.
The macOS lane exercises 3.3a and 3.7b with
Xcode's toolchain and Homebrew's keg-only libraries. Releases below the floor
are built too, to show they are refused.

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
suite ignores SIGPIPE; without that, roughly one full run in ten ended by a
signal rather than by a failing case.
