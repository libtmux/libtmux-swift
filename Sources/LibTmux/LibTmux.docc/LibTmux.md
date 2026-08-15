# ``LibTmux``

Drive tmux from Swift.

## Overview

You address a server, ask it what exists, and send it commands. Everything you
get back is a value — a `Session` you hold is what the server looked like when
you asked, not a live handle that changes under you. Ask again for a newer view.

```swift
let server = try Server(socketPath: "/tmp/work.sock")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

Names follow tmux where tmux has one. ``Session``, ``Window``, ``Pane``, and
``Client`` are what tmux calls them, so they are what they are called here. A
type whose bare name would be an ordinary Swift word takes the prefix instead —
``TmuxCommand``, ``TmuxReply``, ``TmuxOption``, ``TmuxBuffer`` — because a
`Buffer` or an `Option` in your own file should not have to mean this one.

A tmux command that runs and reports a nonzero status is a *reply*, not an
error. `has-session` answers a question with its exit code, and a rejected
command explains itself on standard error — so
``Server/run(_:)-(TmuxCommand)`` hands both back rather than throwing.
``TmuxError`` covers only the cases where no usable reply exists at all.

## Topics

### Essentials

- <doc:Modes>
- <doc:Snapshots>
- <doc:Filtering>
- <doc:Streaming>
- <doc:PlatformSupport>

### Addressing a server

- ``Server``
- ``Endpoint``
- ``TmuxContext``
- ``TmuxCommand``
- ``TmuxReply``
- ``TmuxCommandList``
- ``TmuxVersion``

### What exists

- ``Session``
- ``Window``
- ``Pane``
- ``Client``
- ``Snapshot``

### Waiting for work to finish

- ``Server/wait(for:)``
- ``Server/signal(_:)``

### Reading a field nothing models

- ``Server/format(_:)``
- ``Server/format(_:for:)-(String,Session)``
- ``Server/format(_:for:)-(String,Window)``
- ``Server/format(_:for:)-(String,Pane)``

### Configuration

- ``EnvironmentScope``
- ``TmuxEnvironmentVariable``
- ``TmuxOption``
- ``TmuxHook``
- ``OptionScope``
- ``HookScope``

### Filter expressions

- ``FilterExpr``
- ``FilterOperator``
- ``FilterSchema``
- ``FilterLookup``
- ``CardinalityError``

### Choosing a mode

- ``TmuxMode``
- ``Server/using(_:_:)``
- ``Server/mode``
- ``Server/connected(attachingTo:_:)``
- ``Server/withControlMode(attachingTo:_:)``

### The control protocol

- ``ControlSession``
- ``ControlReply``
- ``ControlNotification``

### Failures

- ``TmuxError``
- ``FormatDecodingError``
