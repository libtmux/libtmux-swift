# Reading the whole server at once

A consistent picture, or none.

## Overview

A listing is one tmux command. Reading sessions, windows, panes, and clients
separately means four, and a server can change between them.
``Server/snapshot()`` reads all four and verifies they came from the same
server, failing closed if a daemon died and a replacement bound the socket
midway.

```swift
let snapshot = try await server.snapshot()
for window in snapshot.windows(of: session) {
    print(window.name, snapshot.panes(of: window).count)
}
```

Relations resolve inside the snapshot, so walking them cannot spawn tmux. A
partial snapshot is never returned: if the reads disagree about which server
answered them, ``TmuxError/serverRestarted`` is thrown instead of handing back a
picture that never existed.

## Finding the server you are already inside

A program started from a pane is told where its tmux is, in `$TMUX`.
``TmuxContext`` reads it, so a tool can talk to the server that launched it
without being passed a socket:

```swift
if let context = TmuxContext.current() {
    let server = try context.server()
    let here = try await server.sessions().first { $0.id == context.sessionID }
    print(here?.name ?? "not in a session")
}
```

tmux writes the session there as a bare number where ``Session/id`` carries the
`$`. ``TmuxContext`` normalises it, because comparing the two spellings
directly fails in a way that looks like a missing session.
