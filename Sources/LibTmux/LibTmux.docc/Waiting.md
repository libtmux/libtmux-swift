# Waiting

Anything driving a terminal spends most of its time waiting. This page is
about which wait to reach for, and what each one costs.

## Overview

tmux offers no hook that fires when a pane prints something — the `notify_*`
set in its `notify.c` covers session, window and client lifetime only. So a
wait built from commands alone has to re-read the pane on a timer, and every
tick costs a tmux process whether or not anything happened.

A control connection is told instead. `%output` arrives as the pane writes,
and `%subscription-changed` arrives when a format's value changes. Both are
free while nothing is happening, which is most of the time.

## Pick the cheapest one that answers the question

**You wrote the command: signal it.** Compose a channel into the command and
block on it. tmux blocks server-side and returns on the signal itself, so
nothing is inferred from what the screen looks like:

```swift
try await server.run("make && tmux wait-for -S built", in: pane)
try await server.wait(for: "built")
```

Use `;` rather than `&&` when the wait must survive a failing command — the
signal has to fire either way or the wait deadlocks on the failure it exists
to report.

**The question is about state: subscribe to a format.** "Has the command
finished", "has the pane died", "has that window rung its bell" are all
formats, and tmux will report a change without being asked. No scrollback is
read at all, which makes this the cheapest wait there is:

```swift
try await server.connected(attachingTo: "work") { server, control in
    try await control.watch(
        FormatSubscription(
            name: "cmd",
            scope: .pane(pane.id),
            format: "#{pane_current_command}"
        )
    )
    for await change in control.changes(named: "cmd") {
        return change.value
    }
    return nil
}
```

tmux evaluates a subscribed format about once a second and sends the current
value once when the subscription is made — which is why the loop above leaves
on its first report: a watcher learns where it is starting from without asking
for it, and every report after that is a change.

**You did not write the command: wait on its output.**
``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:timeout:tailLimit:)`` is for a
daemon printing `ready`, a dev server someone else started, a build you
attached to:

```swift
let waited = try await server.waitForOutput(
    in: pane,
    matching: ["Listening on"],
    stoppingAt: ["EADDRINUSE", "error"]
)
```

Pass `stops` whenever a failure marker exists. A build that fails after five
seconds should end the wait then, rather than holding it open for the rest of
the timeout to report the same failure later.

## Watching, rather than waiting

Waiting blocks until something happens. *Watching* is the other shape: come
back now and then and ask what has happened since. Capturing the pane each
time answers that with the whole screen, nearly all of which the caller has
already read — which for an agent is context spent on nothing.

``Server/capture(_:since:limit:)`` answers the difference:

```swift
var mark = try await server.capture(pane, since: nil).cursor
while building {
    let update = try await server.capture(pane, since: mark)
    for line in update.lines { print(line) }
    mark = update.cursor
}
```

The first call with `nil` establishes where the pane is and returns nothing,
so a watcher starts at "from now on" rather than with a screenful of backlog.
A pane that has been quiet answers an empty list.

The cursor is positional *and* remembers what the last row said, because a row
can be rewritten in place — a spinner, a progress bar, a prompt redrawing. A
position alone cannot tell a row already reported from the same row saying
something new. It also carries the pane's process, so a respawn is reported as
``IncrementalCapture/restarted`` instead of one program's output being read as
another's.

## Why waitForOutput captures instead of reading the stream

`%output` carries raw terminal bytes rather than text. A line typed into a
shell arrives as one notification per character — the echo, not the output —
and a program that redraws with cursor motion rewrites rows that were already
sent. Matching against that stream directly finds the user's keystrokes and
misses words split across two notifications.

So the stream is used as a doorbell. A burst of `%output` for the pane wakes
one capture, and the matching runs against the rendered grid — the same text a
person reads. That keeps a capture's accuracy and pays for it only when
something actually happened.

## Reading the result

A wait that ends without a match has three quite different causes, and the
result distinguishes them rather than leaving it to be guessed:

| Field | What it means |
| --- | --- |
| `sawNewOutput: false` | The pane stayed quiet. The command never ran; no pattern fixes that. |
| `sawNewOutput: true`, `outcome: .timedOut` | Output arrived and did not match. `tail` holds what it actually said. |
| `matchedAtEntry: true` | It was on screen when the wait started — matched at once, or waited past under `requiringFreshOutput`. |
| `outcome: .stopped` | A `stops` marker hit first. `matchedIndex` says which. |
| `outcome: .paneClosed` | The pane went away, so nothing more can arrive. |

`matchedAtEntry` is the one worth knowing about. The condition is checked
before it is blocked on, the way any other wait on a predicate works: a pattern
already on screen returns at once rather than holding the caller for the rest
of the timeout to report something that was true on arrival. That matters most
where the two steps are separable — sending a command and waiting for its
output can lose the race on a loaded machine, and the answer should not depend
on which won.

Pass `requiringFreshOutput` for the other reading. Re-running a command whose
output looks identical to last time needs a *new* occurrence, and there the
line on screen is exactly what must be waited past. A channel is the fix when
the two steps must not be separable at all.

## What each one costs

Measured by `swift run --package-path Benchmarks libtmux-bench`, waiting for a
line that arrives two seconds after the wait starts — a daemon coming up, which
is the case this is for:

<!-- waiting-matrix:start -->

<!-- generated by `swift run --package-path Benchmarks libtmux-bench --markdown`; do not edit -->

| Waiting two seconds for a line you did not print | Polling | waitForOutput |
| --- | --- | --- |
| tmux processes spent | 37 | 4 |
| pane captures taken | 36 captures | 1 capture |

<!-- waiting-matrix:end -->

Polling has to re-read the pane to find out whether anything happened, so the
cost is set by how long the wait lasts rather than by what it is waiting for.
`waitForOutput` is told, and captures once — when there is something to read.

The processes it does spend are the connection and the reads either side of it,
which is a fixed cost however long the wait runs. Wait ten seconds instead of
two and polling's column grows fivefold while this one does not move.

## Topics

### Waiting on output

- ``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:timeout:tailLimit:)``
- ``OutputWait``

### Watching a pane

- ``Server/capture(_:since:limit:)``
- ``CaptureCursor``
- ``IncrementalCapture``

### Watching a format

- ``FormatSubscription``
- ``SubscriptionChange``
- ``ControlSession/watch(_:)``
- ``ControlSession/stopWatching(_:)``
- ``ControlSession/changes(named:)``

### Channels

- ``Server/wait(for:)``
- ``Server/signal(_:)``
