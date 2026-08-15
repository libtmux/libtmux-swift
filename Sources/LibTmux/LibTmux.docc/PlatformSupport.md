# Platform support

What has been exercised, and what has not.

## Overview

The package builds for Linux, and for macOS 26 and later, and supports the tmux
releases 3.2a through 3.7b.

The test suite runs against real tmux, one private server and socket per case.
Every supported release is exercised on Linux, individually and concurrently.

On macOS the package is supported but the suite has not yet been run there, so
Darwin-specific behaviour — the `/private/tmp` symlink, Homebrew's keg-only
libraries, the shorter socket address — is handled but unverified.

``Server/version()`` reports which tmux a server runs, and ``TmuxVersion``
orders releases the way tmux issues them — including the point release's
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

With SIGPIPE ignored, the write reports `EPIPE` instead, and the connection
reports ``TmuxError/connectionClosed`` as it does for every other way of losing
tmux. This package's own test suite makes exactly this call, which is how the
behaviour above is known: without it, roughly one full run in ten was ended by
a signal rather than by a failing case.
