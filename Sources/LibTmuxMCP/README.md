<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/mcp.svg" type="image/svg+xml">
    <img src="../../assets/mcp.png" width="128" height="128" alt="libtmux for Swift MCP">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# [`LibTmuxMCP`][mod-libtmuxmcp]

tmux as [Model Context Protocol][MCP] tools you can embed:
[`TmuxTools`][api-tmuxtools], [`MCPRequestHandler`][api-mcprequesthandler], and
[`MCPService`][api-mcpservice], without the stdio executable.

[![libtmux.org](https://img.shields.io/badge/docs-libtmux.org-0b7285)](https://libtmux.org/en/swift/latest/mcp/)
[![Swift Package Index](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flibtmux%2Flibtmux-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/libtmux/libtmux-swift)

</div>

[`libtmux-mcp`][r-libtmux-mcp] serves these tools over stdio, for an MCP client
to launch.

```swift
.product(name: "LibTmuxMCP", package: "libtmux-swift")
```

**Contents** — [Quick start](#quick-start) · [The tools](#the-tools) ·
[Pane input](#pane-input-checks) · [Adding a tool](#adding-a-tool) ·
[Reference](#reference)

## Quick start

```swift
import LibTmux
import LibTmuxMCP
```

### [`TmuxTools`][api-tmuxtools]: the tools, as values

`TmuxTools` wraps a [`Server`][api-server]. `visibleDefinitions` lists the tools
it exposes, and a [`ToolCall`][api-toolcall] names the tool to run:

```swift
public func useEmbeddedTools(on server: Server) async throws(ToolError) -> Int {
    let tools = TmuxTools(server: server)
    for definition in tools.visibleDefinitions {
        print(definition.name, definition.summary)
    }
    let result = try await tools.call(ToolCall(name: "list_panes"))
    return result.structured["panes"]?.arrayValue?.count ?? 0
}
```

`MCPEmbeddingTests` runs this against a fixture server and asserts it lists the
fixture's one pane. It prints each tool's name and summary.

- **Default.** `TmuxTools(server:)` exposes the 18 `inspect` tools.
- **The registry** has 45: 18 `inspect`, 14 `manage`, nine `execute`, and four
  `teardown`.
- **No authorization.** Toolsets choose which tools a client can call. Every
  call still runs as the tmux user.

### [`ToolAuthority`][api-toolauthority]: grant more, or less

Pass an explicit `ToolAuthority` to add the independent `manage`, `execute`,
or `teardown` groups. For least authority, pass a typed exact selection:

```swift
let authority = ToolAuthority(
    toolsets: [],
    includedTools: ["create_window", "list_sessions"]
)
let tools = TmuxTools(server: server, authority: authority)
```

`MCPEmbeddingTests` asserts this exposes only [`create_window`] and
[`list_sessions`].

- **Inclusions** apply after toolset expansion.
- **Exclusions** apply last, and also remove names from aggregate authority.

## The tools

The [tool index][ref-mcp-tools] has one page per tool, and the
[root tool table][r-readme-md-toolset-the-tools-a-client-is-offered] groups
them by intent:

- **By toolset.** `inspect` reads bounded state, `manage` changes tmux objects,
  `execute` starts or drives pane processes, and `teardown` deletes tmux state.
- **By definition.** `visibleDefinitions` exposes the effective rows: native
  input and output schemas, process reach, tmux effects, output classes, and
  aggregate authority.

### [`select_layout`]: names, abbreviations, saved layouts

- **Accepts** named layouts, unique abbreviations for the running daemon's
  version, and checksummed saved layouts, plus a JSON layout document on
  tmux 3.8 and later.
- **Checks syntax** before window lookup, then uses the core mutation's
  captured-window guard on the selected transport.
- **Leaves geometry** and pruning to tmux. The result's `layout` field echoes
  the accepted input.

### [`capture_pane`]: bounded history, no pane modes

- **History.** Use `capture_pane` ranges, [`search_panes`] for discovery,
  and [`snapshot_pane`] for metadata and content in one response. The
  snapshot is several reads, so a pane can change between them.
- **Following.** An opaque [`capture_since`] cursor returns the output
  that came after.
- **Pane modes.** Read `pane_in_mode` or `pane_mode` with
  [`get_tmux_variables`], then report the human-owned state without
  entering or cancelling it.

### [`tmux://capabilities`][ref-capabilities]: the report of what is served

- **One report.** `CapabilityResources` publishes the surface fixed at startup,
  and tool registration metadata carries the same capability rows.
- **Common objects.** The report also carries the execution boundary and the
  connection provenance.
- **References.** Hierarchy rows carry opaque references for follow-up reads.
  They bind the row to the current tmux daemon and expire when the MCP process
  restarts; re-list to replace one.

[`TmuxTools`][api-tmuxtools] is written against [`Server`][api-server] and never
mentions a mode, so it works the same directly or over a connection.

## Pane input checks

### [`send_keys`]: the checks before input

- **Fresh state.** Pane-input tools read typed pane state and refuse dead panes,
  nonzero mode stacks, incomplete or malformed caller context, and
  terminal-attended panes.
- **Attendance.** A zoomed terminal client protects its active pane; an
  unzoomed one protects every pane in its active window. Control clients do not
  count.
- **`force=true`** bypasses only an exact caller-pane match.
- **Synchronized panes.** `send_keys` reserves every configured member through
  dispatch, and [`send_keys_batch`] checks each row on its own. The returned
  `resolvedPaneIds` lists the members that were checked; it does not confirm
  delivery.

### [`paste_text`] and [`run_shell_command`]: one buffer, one subshell

- **`paste_text`** checks its target before staging and again before its one
  paste dispatch, in a private buffer it removes on success or failure.
- **`run_shell_command`** checks before setup and before dispatch, and refuses a
  second run. It needs one target running a recognized POSIX shell, and runs the
  command in a subshell.
- **Trusted shells.** The guards assume a trusted shell, tmux daemon, and
  configuration; a hostile shell can get around them. Pane state can still
  change after the final check.

The full text of each guard is in
[`docs/mcp-contract.md`][r-docs-mcp-contract-md-pane-input].

## Adding a tool

A tool has three code-native declarations, and tests hold them together:

- a case on `ToolOperation`, whose raw value is the name a client calls;
- a row in `CapabilityRegistry`, carrying its toolset, native input schema,
  capability fields, and handler;
- an exact structured result schema in `CapabilityOutputSchemas`.

`CapabilityManifestTests` rejects a missing row, a schema/sink or tmux-format
control mismatch, undeclared nested authority, invalid recursive input or
output, or drift between registration metadata and the capability resource.

## Reference

- [API pages][ref-mcp-reference]: the embedding types, typed tool authority,
  and the separate protocol catalogue
- [MCP overview][ref-mcp], [toolset selection][ref-mcp-topics], and the
  [embedded example][ref-mcp-examples]
- [Tool pages][ref-mcp-tools], one per tool, and the
  [`tmux://capabilities`][ref-capabilities] resource
- [Swift Package Index][spi-mcp]
- [Changelog](CHANGELOG.md): what each release changed, for this product and
  the `libtmux-mcp` server

[MCP]: https://modelcontextprotocol.io
[spi-mcp]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/libtmuxmcp
[api-mcprequesthandler]: https://libtmux.org/en/swift/latest/mcp/reference/mcprequesthandler/
[api-mcpservice]: https://libtmux.org/en/swift/latest/mcp/reference/mcpservice/
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[api-tmuxtools]: https://libtmux.org/en/swift/latest/mcp/reference/tmuxtools/
[api-toolauthority]: https://libtmux.org/en/swift/latest/mcp/reference/toolauthority/
[api-toolcall]: https://libtmux.org/en/swift/latest/mcp/reference/toolcall/
[mod-libtmuxmcp]: https://libtmux.org/en/swift/latest/mcp/reference/
[r-docs-mcp-contract-md-pane-input]: ../../docs/mcp-contract.md#pane-input
[r-libtmux-mcp]: ../libtmux-mcp
[r-readme-md-toolset-the-tools-a-client-is-offered]: ../../README.md#toolset-the-tools-a-client-is-offered
[ref-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
[ref-mcp-examples]: https://libtmux.org/en/swift/latest/mcp/examples/
[ref-mcp-reference]: https://libtmux.org/en/swift/latest/mcp/reference/
[ref-mcp-tools]: https://libtmux.org/en/swift/latest/mcp/tools/
[ref-mcp-topics]: https://libtmux.org/en/swift/latest/mcp/topics/
[ref-mcp]: https://libtmux.org/en/swift/latest/mcp/
[`capture_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_pane/
[`capture_since`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_since/
[`create_window`]: https://libtmux.org/en/swift/latest/mcp/tools/create_window/
[`get_tmux_variables`]: https://libtmux.org/en/swift/latest/mcp/tools/get_tmux_variables/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
[`paste_text`]: https://libtmux.org/en/swift/latest/mcp/tools/paste_text/
[`run_shell_command`]: https://libtmux.org/en/swift/latest/mcp/tools/run_shell_command/
[`search_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/search_panes/
[`select_layout`]: https://libtmux.org/en/swift/latest/mcp/tools/select_layout/
[`send_keys_batch`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys_batch/
[`send_keys`]: https://libtmux.org/en/swift/latest/mcp/tools/send_keys/
[`snapshot_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/snapshot_pane/
