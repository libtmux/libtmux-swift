# `LibTmuxMCP`

tmux as [Model Context Protocol][MCP] tools you can embed: `TmuxTools`,
`MCPRequestHandler`, and `MCPService`, without the stdio executable.

To *run* one rather than embed it, use [`libtmux-mcp`](../libtmux-mcp), which is
these tools served over stdio.

```swift
.product(name: "LibTmuxMCP", package: "libtmux-swift")
```

```swift
import LibTmux
import LibTmuxMCP
```

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

`TmuxTools(server:)` exposes the `inspect` toolset. Pass an explicit
`ToolAuthority` to add the independent `manage`, `execute`, or `teardown`
groups. Toolsets shape the callable interface; they do not authorize commands
or confine the tmux user.

The default constructor exposes 18 inspect tools. The complete registry has 45:
18 `inspect`, 14 `manage`, nine `execute`, and four `teardown`.

For least authority, pass a typed exact selection:

```swift
let authority = ToolAuthority(
    toolsets: [],
    includedTools: ["create_window", "list_sessions"]
)
let tools = TmuxTools(server: server, authority: authority)
```

Named inclusions apply after toolset expansion. Exclusions apply last and also
remove names from aggregate authority.

## The tools

The [root tool catalogue](../../README.md#the-tools) lists the authoritative
registry, grouped by intent: `inspect` reads bounded state, `manage` changes
tmux objects, `execute` starts or drives pane processes, and `teardown` deletes
tmux state. `visibleDefinitions` exposes the effective rows, including native
input and output schemas, process reach, tmux effects, output classes, one
`inputLiteralization` map, and aggregate authority. Detailed input sink tables
remain internal validation data.

`CapabilityResources` publishes that same frozen surface at
`tmux://capabilities`. Tool registration metadata and the resource use the same
complete capability rows. The report also marks itself frozen and carries the
common execution boundary and connection-provenance objects.

Hierarchy rows carry opaque references for follow-up reads. They bind the row
to the current tmux daemon and expire when the MCP process restarts; re-list to
replace one that has expired. Exact window occurrences carry both a global
`windowRef` and session-local `linkRef`.

`TmuxTools` is written against [`LibTmux`](../LibTmux)'s `Server` and never
mentions a mode, so it works the same directly or over a connection.

That boundary is deliberate. Use `capture_pane` ranges for bounded history,
`search_panes` for discovery, `snapshot_pane` for metadata and content in one
MCP response, and an opaque `capture_since` cursor for subsequent output.
`snapshot_pane` performs separate reads; it does not promise atomicity. Read
`pane_in_mode` or `pane_mode` with `get_tmux_variables` when mode state matters,
then report the human-owned state without entering or cancelling it.

Pane-input tools read fresh typed pane state and refuse dead panes, nonzero mode
stacks, incomplete or malformed caller context, and terminal-attended panes. A
zoomed terminal client protects its active pane; an unzoomed terminal client
protects every pane in its active window. Control clients do not count.
`force=true` bypasses only an exact caller-pane match; it never bypasses
attendance, active-operation, mode, death, shell, or target-count checks.
`send_keys` derives effective synchronized membership from each pane's
configured value and reserves every configured member through dispatch. Its
`resolvedPaneIds` are the checked configuration, not an attestation that tmux
delivered bytes to every member. Batch rows are checked individually, and
every check remains observational rather than atomic.

`paste_text` checks the target before staging and again immediately before its
one paste dispatch. It puts non-empty text and its optional newline in one
private, target-only buffer, then removes the buffer on success or failure.
Empty text without Enter still performs the initial guard, then returns without
a buffer or input dispatch. `run_shell_command` likewise checks exactly before
setup and before dispatch, and a second run refuses instead of waiting. It
requires one configured target running a recognized POSIX shell, pins the
selected tmux executable and socket route, and isolates the command in a
subshell so `cd`, variables, traps, syntax errors, and `exit` do not alter or
terminate the interactive parent.

These are safeguards for a trusted shell, tmux daemon, and configuration, not
universal containment for a hostile shell environment. Pane state can still
change after the final check.

## Adding a tool

A tool has three code-native declarations, and tests hold them together:

- a case on `ToolOperation`, whose raw value is the name a client calls;
- a row in `CapabilityRegistry`, carrying its toolset, native input schema,
  capability fields, and handler;
- an exact structured result schema in `CapabilityOutputSchemas`.

`CapabilityManifestTests` rejects a missing row, a schema/sink or tmux-format
control mismatch, undeclared nested authority, invalid recursive input or
output, or drift between registration metadata and the capability resource.

[MCP]: https://modelcontextprotocol.io
