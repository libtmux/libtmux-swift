# `LibTmux`

The library. Servers, sessions, windows, panes and clients as values, with
options, hooks, formats, filtering, snapshots and streaming over them.

One dependency ([swift-subprocess][]), and the only product most callers need.

```swift
.product(name: "LibTmux", package: "libtmux-swift")
```

With tmux already running on its default socket:

```swift
import LibTmux

let server = try Server(socketName: "default")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

Everything that comes back is a value. A `Session` you hold is what the server
looked like when you asked, not a live handle that changes under you — ask again
for a newer view. Every type crossing your API is `Sendable` and `Codable`, and
the mutable part (the process boundary, the live connection) sits behind an
actor the value shares.

## What is in here

| File | What it holds |
| --- | --- |
| `Server.swift`, `Endpoint.swift` | Addressing a server, and the listings |
| `Session.swift`, `Window.swift`, `Pane.swift` | The model, as values |
| `Snapshot.swift` | A bounded aggregate, with the relationships resolved |
| `Mutations.swift`, `Navigation.swift` | Creating, splitting, renaming, selecting |
| `Options.swift`, `Environment.swift` | tmux options, hooks, and its two environments |
| `Filter*.swift` | `FilterExpr`, the filter that encodes and travels |
| `Regex*.swift` | Bounded pattern syntax, compilation, and matching |
| `TmuxMode.swift`, `ControlMode.swift` | Direct and connected, and the switch between |
| `Wait.swift`, `WaitForOutput.swift` | Channels and event-driven pane output waits |
| `TmuxVersion.swift` | What the server runs, compared properly |

## Documentation

The [DocC catalogue](LibTmux.docc) is the reference — modes, snapshots,
filtering, streaming and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

Usage examples with output live in the [repository README](../../README.md).

[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
