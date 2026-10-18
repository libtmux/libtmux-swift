<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/library.svg" type="image/svg+xml">
    <img src="../../assets/library.png" width="128" height="128" alt="libtmux for Swift">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# [`LibTmux`][mod-libtmux]

The library. Servers, sessions, windows, panes and clients as values, with
options, hooks, formats, filtering, snapshots and streaming over them.

</div>

One dependency ([swift-subprocess][]), and the only product most callers need.

```swift
.product(name: "LibTmux", package: "libtmux-swift")
```

**Contents** — [Quick start](#quick-start) ·
[Values you hold](#values-you-hold) ·
[Find things](#find-sessions-windows-and-panes) ·
[What is in here](#what-is-in-here) · [Products](#products) ·
[Documentation](#documentation)

## Quick start

With tmux already running on its default socket:

```swift
import LibTmux

let server = try Server(socketName: "default")
for session in try await server.sessions() {
    print(session.name, session.windowCount)
}
```

A [`Server`][api-server] addresses a tmux socket by name, and
[`Server.sessions()`][api-server-sessions] asks it for every session. It prints
one line per session: the name, then the window count.

## Values you hold

Everything that comes back is a value. A [`Session`][api-session] you hold is
what the server reported when you asked, and it stays that way when tmux
changes. Ask again for a newer view.

- **Sendable and Codable.** Every type crossing your API is `Sendable` and
  `Codable`.
- **One actor.** The mutable part, the process boundary and the live
  connection, sits behind an actor the value shares.
- **Input state.** [`Pane`][api-pane] also projects
  [`Pane.isDead`][api-pane-isdead], the exact
  [`Pane.modeCount`][api-pane-modecount], and effective
  [`Pane.isSynchronized`][api-pane-issynchronized].
- **Malformed fails.** A missing or malformed value fails decoding; none
  becomes a writable default.

## Find sessions, windows, and panes

### [`Server.windows()`][api-server-windows]: every window at once

[`Server.sessions()`][api-server-sessions] and
[`Server.panes()`][api-server-panes] are its siblings, and each returns a plain
array of values:

```swift
let sessions = try await server.sessions()
let windows = try await server.windows()
let panes = try await server.panes()
```

`QueryingTests` runs this on a fixture server and asserts one session, one
window, and one pane.

### [`Pane`][api-pane]: what is running in it

A pane knows its [`Pane.currentCommand`][api-pane-currentcommand] and
[`Pane.currentPath`][api-pane-currentpath]:

```swift
for pane in try await server.panes() {
    print(pane.id, pane.currentCommand, pane.currentPath)
}
```

It prints one line per pane: the id, the command, and the path. The [repository
README](../../README.md) builds from here to changing, waiting, and
[modes][ref-concept-transports].

## What is in here

| File | What it holds |
| --- | --- |
| `Server.swift`, `Endpoint.swift` | Addressing a server, and the listings |
| `Session.swift`, `Window.swift`, `Pane.swift` | The model, as values |
| `Snapshot.swift` | A bounded aggregate, with the relationships resolved |
| `Mutations.swift`, `Navigation.swift` | Creating, splitting, renaming, selecting, pane modes |
| `Options.swift`, `Environment.swift` | tmux options, hooks, and its two environments |
| `Filter*.swift` | [`FilterExpr`][api-filterexpr], the filter that encodes and travels |
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
[API pages][ref-libtmux-reference] on libtmux.org and
[Swift Package Index][spi-libtmux].

[`Server.version()`][api-server-version] reports what the server runs, and
[`TmuxVersion`][api-tmuxversion] compares properly:

```swift
if try await server.version() < TmuxVersion(major: 3, minor: 4) {
    print("this release predates the behaviour relied on below")
}
```

`PlatformSupportTests` runs this against a fixture server.

### [`TmuxWorkspace`][dir-tmuxworkspace]: workspaces from Swift

Builds a session from a [tmuxp][] workspace written in Swift, JSON, or YAML.
Reference: the [API pages][ref-ws-reference] and
[Swift Package Index][spi-workspace].

[`WorkspaceBuilder`][api-workspacebuilder] creates the session for a
[`Workspace`][api-workspace] value, such as the one under
[Workspaces][r-readme-md-workspaces-from-a-file-or-from-swift]:

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

### [`tmux-workspace`][dir-tmux-workspace]: the command

Loads, lists, searches, converts, imports, and captures workspaces from a
shell. It is partial; the [command manual][ref-cli] lists what remains.

With a [workspace file][ref-ws-config] saved as `project.yaml`,
[`load`][ref-cli-load] builds it on a tmux socket named `project` without
attaching to it:

```console
$ tmux-workspace load \
    -L project \
    -d \
    project.yaml
```

The [README][cli-readme] has an example for each subcommand.

### [`LibTmuxMCP`][dir-libtmuxmcp]: tmux tools to embed

The tools [`libtmux-mcp`][mod-libtmux-mcp] serves, as a library for a server of
your own. Reference: the [API pages][ref-mcp-reference], [Swift Package
Index][spi-mcp], and one page per [tool][ref-mcp-tools].

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

`MCPEmbeddingTests` asserts the exact selection exposes only those two tools.

### [`libtmux-mcp`][dir-libtmux-mcp]: the MCP server

A [Model Context Protocol][MCP] server over stdio, started by an MCP client.
Reference: the [overview][ref-mcp], the [client guide][ref-mcp-guide], and
one page per [tool][ref-mcp-tools].

Register a built binary with Claude Code, limited to the `inspect` toolset:

```console
$ claude mcp add tmux \
    -e LIBTMUX_TOOLSETS=inspect \
    -- /path/to/.build/debug/libtmux-mcp
```

Other clients take the JSON configuration under
[tmux as MCP tools][r-readme-md-tmux-as-mcp-tools].

### [`TmuxFixture`][dir-tmuxfixture]: a real tmux for tests

Provisions a private tmux server for a test or benchmark and reaps it when the
body returns, throws, or the process is killed. Guide:
[Testing with libtmux][ref-guide-testing]. The example is under
[Testing your own code][r-readme-md-testing-your-own-code].


## Documentation

The [DocC catalogue][r-libtmux-docc] is the reference — modes, snapshots,
filtering, streaming and platform support:

```console
$ swift package --disable-sandbox preview-documentation --target LibTmux
```

- **Examples with output** live in the [repository README][r-readme-md].
- **Hosted:** the [API pages][ref-libtmux-reference], [guides][ref-guides],
  [concepts][ref-concepts], and [topics][ref-topics] on libtmux.org, and
  [Swift Package Index][spi-libtmux].

[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
[MCP]: https://modelcontextprotocol.io
[tmuxp]: https://tmuxp.git-pull.com/
[cli-readme]: ../TmuxWorkspaceCLI/README.md
[spi-libtmux]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmux
[spi-mcp]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmuxmcp
[spi-workspace]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/tmuxworkspace
[api-filterexpr]: https://libtmux.org/en/swift/latest/reference/filterexpr/
[api-pane-currentcommand]: https://libtmux.org/en/swift/latest/reference/pane-currentcommand/
[api-pane-currentpath]: https://libtmux.org/en/swift/latest/reference/pane-currentpath/
[api-pane-isdead]: https://libtmux.org/en/swift/latest/reference/pane-isdead/
[api-pane-issynchronized]: https://libtmux.org/en/swift/latest/reference/pane-issynchronized/
[api-pane-modecount]: https://libtmux.org/en/swift/latest/reference/pane-modecount/
[api-pane]: https://libtmux.org/en/swift/latest/reference/pane/
[api-server-panes]: <https://libtmux.org/en/swift/latest/reference/server-panes()/>
[api-server-sessions]: <https://libtmux.org/en/swift/latest/reference/server-sessions()/>
[api-server-version]: <https://libtmux.org/en/swift/latest/reference/server-version()/>
[api-server-windows]: <https://libtmux.org/en/swift/latest/reference/server-windows()/>
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[api-session]: https://libtmux.org/en/swift/latest/reference/session/
[api-tmuxtools]: https://libtmux.org/en/swift/latest/mcp/reference/tmuxtools/
[api-tmuxversion]: https://libtmux.org/en/swift/latest/reference/tmuxversion/
[api-toolauthority]: https://libtmux.org/en/swift/latest/mcp/reference/toolauthority/
[api-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/workspace/
[api-workspacebuilder]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder/
[dir-libtmux-mcp]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/libtmux-mcp
[dir-libtmux]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/LibTmux
[dir-libtmuxmcp]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/LibTmuxMCP
[dir-tmux-workspace]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspaceCLI
[dir-tmuxfixture]: https://github.com/libtmux/libtmux-swift/tree/master/Tests/TmuxFixture
[dir-tmuxworkspace]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspace
[mod-libtmux-mcp]: https://libtmux.org/en/swift/latest/mcp/
[mod-libtmux]: https://libtmux.org/en/swift/latest/reference/
[r-libtmux-docc]: LibTmux.docc
[r-readme-md-testing-your-own-code]: ../../README.md#testing-your-own-code
[r-readme-md-tmux-as-mcp-tools]: ../../README.md#tmux-as-mcp-tools
[r-readme-md-workspaces-from-a-file-or-from-swift]: ../../README.md#workspaces-from-a-file-or-from-swift
[r-readme-md]: ../../README.md
[ref-cli-load]: https://libtmux.org/en/swift/latest/workspace/cli/load/
[ref-cli]: https://libtmux.org/en/swift/latest/workspace/cli/
[ref-concept-transports]: https://libtmux.org/en/swift/latest/concepts/transports/
[ref-concepts]: https://libtmux.org/en/swift/latest/concepts/
[ref-guide-testing]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
[ref-guides]: https://libtmux.org/en/swift/latest/guides/
[ref-libtmux-reference]: https://libtmux.org/en/swift/latest/reference/
[ref-mcp-guide]: https://libtmux.org/en/swift/latest/mcp/guides/
[ref-mcp-reference]: https://libtmux.org/en/swift/latest/mcp/reference/
[ref-mcp-tools]: https://libtmux.org/en/swift/latest/mcp/tools/
[ref-mcp]: https://libtmux.org/en/swift/latest/mcp/
[ref-topics]: https://libtmux.org/en/swift/latest/topics/
[ref-ws-config]: https://libtmux.org/en/swift/latest/workspace/configuration/
[ref-ws-reference]: https://libtmux.org/en/swift/latest/workspace/reference/
[`create_window`]: https://libtmux.org/en/swift/latest/mcp/tools/create_window/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
