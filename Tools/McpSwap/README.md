# MCP config swap tool

`mcp-swap` is a private development utility for pointing supported agent clients
at this repository's MCP server. It can target the working tree, an existing
debug or release build, an installed executable, or a pull request, then restore
the exact pre-swap config bytes.

The tool has its own nested Swift package. It is not a product of the root
[`Package.swift`](../../Package.swift), is not included in library archives, and
is not published for consumers. See the repository's
[`CONTRIBUTING.md`](../../.github/CONTRIBUTING.md) for its required checks.

## Quick start

Run these commands from the repository root. `swift run` builds the private tool
when needed.

List the clients whose binary and config file can be found:

```console
$ swift run --package-path Tools/McpSwap mcp-swap detect
```

Inspect their current entry for the server name derived from `Package.swift`:

```console
$ swift run --package-path Tools/McpSwap mcp-swap status
```

Preview a working-tree swap without locking, starting the server, or writing a
file:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --dry-run
```

Apply it transactionally:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local
```

Restore every recorded client:

```console
$ swift run --package-path Tools/McpSwap mcp-swap revert
```

Inspect entries, strict recovery state, orphaned Swift backups, and authentication
environment overrides:

```console
$ swift run --package-path Tools/McpSwap mcp-swap doctor
```

The complete option reference is available from the executable:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --help
```

## Sources

`use-local` derives the default server and entry names from the first executable
product in the repository's `Package.swift`. A trailing `-mcp` is removed from
the server name, so an executable named `libtmux-mcp` produces the server key
`libtmux`.

| Source | Invocation written to client configs | Preparation |
| --- | --- | --- |
| `dev` | `swift run --package-path <repo> <entry>` | None; SwiftPM rebuilds changed sources when the client starts it |
| `debug` | `<repo>/.build/debug/<entry>` | Build the debug executable first |
| `release` | `<repo>/.build/release/<entry>` | Build the release executable first |
| `installed` | `<entry>` | Put the published executable on `PATH` |
| `--pr N` | `uvx --from git+<origin>@refs/pull/N/head <entry>` | Put `uvx` on `PATH`; the ref is resolved by preflight |

Select a prebuilt debug executable:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --flavour debug
```

Select a prebuilt release executable:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --flavour release
```

Select an installed executable:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --flavour installed
```

Point at a pull request without checking it out:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --pr 115
```

Override a repository whose registered server key differs from the derived name:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --server tmux
```

Override the executable entry independently:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --entry libtmux-mcp
```

Debug and release entry overrides must be a single executable name; path
components and traversal are rejected before a `.build` destination is formed.

Existing server environment values are retained. Repeated `--env` values are
layered over them, with the explicit value winning:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --env LIBTMUX_SOCKET=test-socket --env LOG_LEVEL=debug
```

`LIBTMUX_SAFETY` has been retired. The tool rejects an explicit value and
removes a stored value only when the current request explicitly supplies
`LIBTMUX_TOOLSETS`. Otherwise the exact inherited environment reaches preflight,
where the server reports the required migration without the tool silently
widening authority. `--no-preflight` retains that inherited value unchanged.

The initialize preflight runs once for every selected config that would change,
using that client's final merged environment. `--no-preflight` is available for
an offline or deliberately prevalidated source:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --no-preflight
```

## Supported clients and config ownership

The tool owns one explicit config path per client. It does not search for or
merge project-local alternatives.

| Client selector | Config | Format and container | Scope |
| --- | --- | --- | --- |
| `claude` | `$HOME/.claude.json` | JSON `mcpServers` | Independent `user` and `project` layers |
| `codex` | `$HOME/.codex/config.toml` | TOML `mcp_servers` | Global |
| `cursor` | `$HOME/.cursor/mcp.json` | JSON `mcpServers` | Global |
| `gemini` | `$HOME/.gemini/settings.json` | JSON `mcpServers` | Global |
| `grok` | `$HOME/.grok/config.toml` | TOML `mcp_servers` | Global |
| `agy` or `antigravity` | `$HOME/.gemini/config/mcp_config.json` | JSON `mcpServers` | Global |
| `opencode` | `$XDG_CONFIG_HOME/opencode/opencode.jsonc` | JSONC `mcp` | Global |
| `pi` | `$HOME/.pi/agent/mcp.json` | JSONC `mcpServers` | Global, through `pi-mcp-adapter` |

Repeat `--cli` or provide comma-separated selectors. The tool canonicalizes the
order, so every one of the 40,320 permutations of all eight names produces the
same transaction order.

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --cli claude,cursor --cli antigravity
```

Without `--cli`, mutating commands select clients that have both their binary on
`PATH` and their config present. An explicit selector requires its config but is
useful when the client binary itself is temporarily absent.

### Claude scopes

Claude's default `project` scope writes
`projects[<absolute-repo>].mcpServers` in `$HOME/.claude.json`. Only that checkout
sees the override:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --cli claude --scope project
```

The `user` scope writes the top-level `mcpServers` fallback:

```console
$ swift run --package-path Tools/McpSwap mcp-swap use-local --cli claude --scope user
```

Both can coexist. They receive independent backups and sequence numbers, and a
full Claude revert unwinds them in last-in, first-out order. A scope-specific
revert is accepted only when that layer is currently on top:

```console
$ swift run --package-path Tools/McpSwap mcp-swap revert --cli claude --scope user
```

For every other client, `--scope` normalizes to `user` because the owned config
has no project layer.

### Client-specific limits

- Cursor, Gemini, opencode, and the other non-Claude clients may also support
  workspace files. This tool deliberately leaves those human/project UX layers
  alone. Use the client's own command or edit the workspace file when its
  precedence matters.
- opencode loads `config.json`, `opencode.json`, and `opencode.jsonc` from its
  global config directory and merges them with JSONC winning. This tool owns only
  the JSONC file that opencode writes. A stale same-name entry in a sibling file
  can still merge underneath it.
- pi does not provide an MCP client itself. Its config takes effect through the
  third-party `pi-mcp-adapter` extension. `detect` reports this prerequisite
  when the adapter directory is absent.
- Binary discovery is intentionally `PATH`-based. Custom Homebrew, npm, or
  per-user install directories work only when present on `PATH`.

## What the transaction protects

Before staging a write, the native implementation parses every selected config
and authenticates every config and backup named by the complete active Swift
recovery ledger—even when the command selects only one unrelated client. A later
malformed config therefore cannot leave an earlier client partly swapped.

JSON, JSONC, and TOML inputs must be valid UTF-8. The complete document is parsed,
including syntax outside the server entry. JSONC comments and trailing commas are
accepted; comments, unrelated keys, Unicode, and existing layout remain in the
document. TOML is validated as TOML 1.0 and edits retain unrelated tables,
arrays-of-tables, values, and comments.

The mutation path then:

1. stages config, backup, and checksummed ledger bytes on each destination's own
   filesystem;
2. rechecks the shared lock, logical route, every symlink identity and target,
   resolved parent, mode, inode, size, timestamp, link count, and SHA-256 digest;
3. publishes absent files without replacement and replaces existing files by an
   atomic exchange;
4. validates the committed ledger and every owned artifact; and
5. removes only temporary files whose exact identities are still owned.

If any boundary changes, the transaction stops and rolls completed steps back in
reverse. A file that appears at a destination is never overwritten as cleanup.
When safe rollback cannot prove ownership, the error names the retained recovery
artifact rather than deleting uncertain bytes.

Hard-linked mutable artifacts are refused. Symlinked configs are supported,
including targets on another filesystem, because config stages are created beside
the resolved target while recovery records retain the logical path, every symlink
text and identity, and the resolved parent. Replacing a file with a new inode is a
change even when its bytes are identical.

`--dry-run` performs the parsing, recovery authentication, alias checks, and plan,
then prints proposed bytes. It does not create the lock or state directories, run
initialize preflight, create a backup, or stage a file.

## Initialize preflight

The preflight sends one MCP `initialize` request using protocol version
`2025-06-18`. It requires JSON-RPC 2.0, the matching request ID, a result object,
and a nonempty returned `protocolVersion`. A normal stdio MCP server remains alive
after replying, so the probe accepts the matching response immediately, terminates
the dedicated process group, and reaps its child. It does not wait for process exit
or pipe EOF.

The probe has a bounded timeout and output budget, passes the final entry
environment, reports the tail of stderr when no response arrives, and terminates
descendants on success, timeout, malformed output, or oversized output. No config,
backup, or ledger write begins until every required probe succeeds.

## Recovery state

All ports coordinate mutation with the shared lock:

`$XDG_STATE_HOME/libtmux-mcp-dev/swap/state.lock`

Swift holds that file with a POSIX `lockf` record lock, the same lock family
used by the other native ports, and verifies the open descriptor and path
identity while it is held.

Swift recovery is deliberately namespaced beneath it:

`$XDG_STATE_HOME/libtmux-mcp-dev/swap/swift/state.json`

Backups use the suffix `.bak.mcp-swap-swift-<timestamp>` (plus a Claude scope and
collision counter when needed). They are mode `0600`; the ledger records the
original config mode separately so revert restores it.

The Swift ledger is bounded, versioned, strictly shaped, checksummed, and bound to
the exact config and backup routes and identities. It deliberately does not decode
or migrate the superseded Python tool's recovery file. Before changing tool
versions, finish any outstanding swap with the version that created it. Do not
delete an unrecognized backup merely because `doctor` calls it orphaned; it may be
the only surviving pre-swap copy.

Swapping an already recorded layer keeps its first backup. If that layer sits
beneath a newer Claude layer, the newer backup is transactionally rewritten so
later LIFO recovery reveals the updated lower layer. `revert` restores the oldest
selected top-contiguous backup byte-for-byte and removes only the exact selected
recovery artifacts.

## Development

Run the focused suite with the package's resolved dependency versions:

```console
$ swift test --package-path Tools/McpSwap --jobs 5 --force-resolved-versions
```

Run its formatting gate from the repository root:

```console
$ swift format lint --recursive --strict Tools/McpSwap/Sources/McpSwapCore Tools/McpSwap/Sources/McpSwap Tools/McpSwap/Tests Tools/McpSwap/Package.swift
```

The safety behavior is executable in
[`Tests/McpSwapCoreTests`](Tests/McpSwapCoreTests/); the C shim is limited to the
portable filesystem, lock, spawn, polling, and wait primitives in
[`Sources/CMcpSwap`](Sources/CMcpSwap/). Higher-level parsing, planning,
preflight, transactions, recovery, diagnostics, and CLI behavior remain Swift.
