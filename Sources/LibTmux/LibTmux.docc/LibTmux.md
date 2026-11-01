# ``LibTmux``

Drive tmux from Swift.

> Important: Releases are numbered `0.1.N`, and each release increments `N`.
> The API is not settled: any release may change or remove exported
> identifiers, and the changelog marks each break. Pin an exact version to
> avoid one. What this package claims about tmux is tested against
> releases 3.3a through 3.8, and master: 3.3a and 3.8 on every push, and the
> rest when a release is tagged. What has not settled is the Swift surface
> around that.

## Overview

You address a server, ask it what exists, and send it commands. Everything you
get back is a value — a `Session` you hold is what the server looked like when
you asked, not a live handle that changes under you. Ask again for a newer view.

With tmux already running:

```swift
let server = try Server()
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

A server built with no socket passes tmux neither `-L` nor `-S`, so tmux picks
the server: the one you are inside, and its default socket elsewhere.
`LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET` names another, and
``Server/init(socketPath:tmuxExecutable:configurationFile:)`` or
``Server/init(socketName:tmuxExecutable:configurationFile:)`` names one in code
and leaves both variables unread.

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
- <doc:Waiting>
- <doc:PlatformSupport>

### Addressing a server

- ``Server``
- ``Endpoint``
- ``TmuxContext``
- ``TmuxCommand``
- ``TmuxReply``
- ``TmuxCommandList``
- ``TmuxVersion``

### Naming one thing

- ``SessionID``
- ``WindowID``
- ``PaneID``
- ``WindowLinkID``
- ``ServerIncarnation``

### What exists

- ``Session``
- ``Window``
- ``WindowLink``
- ``WindowAppearance``
- ``Pane``
- ``PaneSize``
- ``Client``
- ``Snapshot``

### Finding a server

- ``TmuxServers``
- ``ServerDiscovery``
- ``DiscoveredServer``

### Reading a pane

- ``Server/capture(_:includingHistory:)``
- ``Server/capture(_:since:limit:)``
- ``PaneCapture``
- ``IncrementalCapture``
- ``CaptureCursor``
- ``Pane/isDead``
- ``Pane/modeCount``
- ``Pane/isSynchronized``

### Controlling pane modes

- ``Server/enterCopyMode(_:)``
- ``Server/cancelModes(in:)``

### Laying out a window

- ``Server/validateLayouts(_:)``
- ``Server/selectLayout(_:_:)``
- ``WindowPlacement``
- ``PaneDirection``
- ``ResizeDirection``

### Waiting for work to finish

- <doc:Waiting>
- ``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)``
- ``OutputWait``
- ``OutputWaitError``
- ``Server/wait(for:)``
- ``Server/signal(_:)``

### Reading a field nothing models

- ``Server/format(_:)``
- ``Server/format(_:for:)-(String,Session)``
- ``Server/format(_:for:)-(String,WindowLink)``
- ``Server/format(_:for:through:)``

### Configuration

- ``EnvironmentScope``
- ``TmuxEnvironmentVariable``
- ``TmuxOption``
- ``TmuxHook``
- ``OptionScope``
- ``HookScope``

### Finding one object

- ``Server/session(_:)``
- ``Server/session(named:)``
- ``Server/window(_:)``
- ``Server/windows(named:)``
- ``Server/pane(_:)``
- ``Server/refresh(_:)-(Session)``
- ``Server/refresh(_:)-(Window)``
- ``Server/refresh(_:)-(Pane)``

### Letting tmux do the filtering

- ``Server/sessions(where:)``
- ``Server/windows(where:)``
- ``Server/panes(where:)``
- ``Server/clients(where:)``
- ``FilteredListingError``

### Keeping an error typed

- ``withTmuxError(_:)``

### Filter expressions

- ``FilterExpr``
- ``FilterOperator``
- ``FilterSchema``
- ``FilterLookup``
- ``Filterable``
- ``FilterValue``
- ``FilterOperation``
- ``RelationQuery``
- ``RelationQuantifier``
- ``CardinalityError``
- ``FilterSelectionError``
- ``FilterLookupError``
- ``FilterValidationError``
- ``QueryConstructionError``

### Bounded pattern matching

- ``RegexPattern``
- ``RegexCompileError``
- ``RegexMatchError``
- ``RegexUnsupportedConstruct``

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
- ``FormatSubscription``
- ``SubscriptionChange``
- ``ControlNotificationStream``

### Failures

- ``TmuxError``
- ``FormatDecodingError``
