<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/library.svg" type="image/svg+xml">
    <img src="../../assets/library.png" width="128" height="128" alt="libtmux for Swift">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# `LibTmux`

The library. Servers, sessions, windows, panes and clients as values, with
options, hooks, formats, filtering, snapshots and streaming over them.

</div>

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

Everything that comes back is a value. A [`Session`][api-session] you hold is
what the server looked like when you asked, not a live handle that changes under
you — ask again for a newer view. Every type crossing your API is `Sendable` and
`Codable`, and the mutable part (the process boundary, the live connection) sits
behind an actor the value shares.

[`Pane`][api-pane] also projects the input-relevant state tmux reports:
`isDead`, the exact `modeCount`, and effective `isSynchronized`. Missing or
malformed values fail decoding instead of being treated as writable defaults.

## What is in here

| File | What it holds |
| --- | --- |
| `Server.swift`, `Endpoint.swift` | Addressing a server, and the listings |
| `Session.swift`, `Window.swift`, `Pane.swift` | The model, as values |
| `Snapshot.swift` | A bounded aggregate, with the relationships resolved |
| `Mutations.swift`, `Navigation.swift` | Creating, splitting, renaming, selecting, pane modes |
| `Options.swift`, `Environment.swift` | tmux options, hooks, and its two environments |
| `Filter*.swift` | `FilterExpr`, the filter that encodes and travels |
| `Regex*.swift` | Bounded pattern syntax, compilation, and matching |
| `TmuxMode.swift`, `ControlMode.swift` | Direct and connected, and the switch between |
| `Wait.swift`, `WaitForOutput.swift` | Channels and event-driven pane output waits |
| `TmuxVersion.swift` | What the server runs, compared properly |

## Products

These ship from the one package. Each heading links to the directory that holds
the product.

### [`LibTmux`][dir-libtmux]: the library

Servers, sessions, windows, panes, and clients as values, with options, hooks,
filtering, snapshots, and streaming over them. Reference: the
[API pages][ref-libtmux] on libtmux.org and [Swift Package Index][spi-libtmux].

A [`Server`][api-server] lists the [`Session`][api-session],
[`Window`][api-window], and [`Pane`][api-pane] values it holds. A pane knows
what is running in it and where:

```swift
for pane in try await server.panes() {
    print(pane.id, pane.currentCommand, pane.currentPath)
}
```

### [`TmuxWorkspace`][dir-workspace]: workspaces from Swift

Builds a session from a [tmuxp][] workspace written in Swift, JSON, or YAML.
Reference: the [API pages][ref-workspace] on libtmux.org and
[Swift Package Index][spi-workspace].

[`WorkspaceBuilder`][api-workspacebuilder] creates the session for a
[`Workspace`][api-workspace] value, such as the one under
[Workspaces](../../README.md#workspaces-from-a-file-or-from-swift):

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

### [`tmux-workspace`][dir-cli]: the command

Loads, lists, searches, converts, imports, and captures workspaces from a
shell. It is partial; the [command guide][ref-cli] lists what remains.
Reference: the [`load`][ref-cli-load] and [`freeze`][ref-cli-freeze] pages.

With a [workspace file][ref-workspace-config] saved as `project.yaml`, `load`
builds it on a tmux socket named `project` without attaching to it:

```console
$ tmux-workspace load \
    -L project \
    -d \
    project.yaml
```

### [`LibTmuxMCP`][dir-mcp]: tmux tools to embed

The tools `libtmux-mcp` serves, as a library for a server of your own.
Reference: the [API pages][ref-mcp-reference] on libtmux.org,
[Swift Package Index][spi-mcp], and one page per [tool][ref-mcp-tools].

[`TmuxTools`][api-tmuxtools] exposes the `inspect` toolset, which reads bounded
state, unless a [`ToolAuthority`][api-toolauthority] says otherwise. This one
exposes [`create_window`] and [`list_sessions`] and nothing else:

```swift
let authority = ToolAuthority(
    toolsets: [],
    includedTools: ["create_window", "list_sessions"]
)
let tools = TmuxTools(server: server, authority: authority)
```

### [`libtmux-mcp`][dir-mcp-server]: the MCP server

A [Model Context Protocol][MCP] server over stdio, started by an MCP client.
Reference: the [overview][ref-mcp], the [client guide][ref-mcp-guide], and one
page per [tool][ref-mcp-tools].

Register a built binary with Claude Code, limited to the `inspect` toolset:

```console
$ claude mcp add tmux \
    -e LIBTMUX_TOOLSETS=inspect \
    -- /path/to/.build/debug/libtmux-mcp
```

Other clients take the JSON configuration under
[tmux as MCP tools](../../README.md#tmux-as-mcp-tools).

### [`TmuxFixture`][dir-fixture]: a real tmux for tests

Provisions a private tmux server for a test or benchmark and reaps it when the
body returns, throws, or the process is killed. Guide:
[Testing with libtmux][ref-testing].

[`withTmuxServer`][api-withtmuxserver] hands the body a server with one
`bootstrap` session on a socket under `/tmp/libtmux-swift-test/`. After
`import TmuxFixture`, this prints `bootstrap: 1 window`, `build: 1 window`, and
`work: 1 window`:

```swift
try await withTmuxServer { @Sendable server in
    _ = try await server.newSession(named: "work")
    _ = try await server.newSession(named: "build")
    let sessions = try await server.sessions()
    for session in sessions.sorted(by: { $0.name < $1.name }) {
        print("\(session.name): \(session.windowCount) window")
    }
}
```

## Documentation

The [DocC catalogue](LibTmux.docc) is the reference — modes, snapshots,
filtering, streaming and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

Usage examples with output live in the [repository README](../../README.md).

The same reference is hosted on libtmux.org, with [guides][ref-guides],
[concepts][ref-concepts], and [topics][ref-topics] beside the
[API pages][ref-libtmux], and on [Swift Package Index][spi-libtmux].

[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
[MCP]: https://modelcontextprotocol.io
[tmuxp]: https://tmuxp.git-pull.com/
[`create_window`]: https://libtmux.org/en/swift/latest/mcp/tools/create_window/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
[api-pane]: https://libtmux.org/en/swift/latest/reference/pane/
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[api-session]: https://libtmux.org/en/swift/latest/reference/session/
[api-tmuxtools]: https://libtmux.org/en/swift/latest/mcp/reference/tmuxtools/
[api-toolauthority]: https://libtmux.org/en/swift/latest/mcp/reference/toolauthority/
[api-window]: https://libtmux.org/en/swift/latest/reference/window/
[api-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/workspace/
[api-workspacebuilder]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder/
[dir-cli]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspaceCLI
[dir-fixture]: https://github.com/libtmux/libtmux-swift/tree/master/Tests/TmuxFixture
[dir-libtmux]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/LibTmux
[dir-mcp]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/LibTmuxMCP
[dir-mcp-server]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/libtmux-mcp
[dir-workspace]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspace
[ref-cli]: https://libtmux.org/en/swift/latest/workspace/cli/
[ref-cli-freeze]: https://libtmux.org/en/swift/latest/workspace/cli/freeze/
[ref-cli-load]: https://libtmux.org/en/swift/latest/workspace/cli/load/
[ref-concepts]: https://libtmux.org/en/swift/latest/concepts/
[ref-guides]: https://libtmux.org/en/swift/latest/guides/
[ref-libtmux]: https://libtmux.org/en/swift/latest/reference/
[ref-mcp]: https://libtmux.org/en/swift/latest/mcp/
[ref-mcp-guide]: https://libtmux.org/en/swift/latest/mcp/guides/
[ref-mcp-reference]: https://libtmux.org/en/swift/latest/mcp/reference/
[ref-mcp-tools]: https://libtmux.org/en/swift/latest/mcp/tools/
[ref-testing]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
[ref-topics]: https://libtmux.org/en/swift/latest/topics/
[ref-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/
[ref-workspace-config]: https://libtmux.org/en/swift/latest/workspace/configuration/
[spi-libtmux]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmux
[spi-mcp]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmuxmcp
[spi-workspace]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/tmuxworkspace
[api-withtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withtmuxserver(socketfilename-_-)/>
