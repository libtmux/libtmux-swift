# LibTmuxMCP contributor guide

## Surface boundary

The MCP is a curated, semantic, detached-safe surface. Library parity does not
imply MCP parity: core APIs may expose lower-level tmux operations that should
not become public tools.

Exclude modal human-client UX when a noninteractive equivalent exists. This
includes copy mode, clock mode, choose-tree interfaces, prompts, menus, popups,
and mouse gestures. Read scrollback with `capture_pane`, locate output with
`search_panes`, return metadata plus content with `snapshot_pane`, and follow new
output with the opaque `capture_since` cursor. Read `pane_in_mode` or `pane_mode`
through `get_tmux_variables` when mode state matters; report it without entering
or cancelling the human-owned mode.

Paired cleanup, unclear ownership, and dependencies on key tables, mouse state,
clipboard integration, or interaction timing are exclusion signals. Keep useful
core library APIs even when they do not belong in MCP.

Every public tool belongs to exactly one ADR toolset. `CapabilityRegistry` owns
the runtime manifest, documentation catalogue, and test expectations; update all
of them together.

## Testing

Run every Swift build or test on CPUs 0 through 4 with at most five jobs. Tests
that use real tmux must share the repository lock and run without parallel test
execution:

```console
$ taskset -c 0-4 mise exec -- flock /tmp/libtmux-swift-test/.swift.lock swift test --jobs 5 --no-parallel --force-resolved-versions
```

Keep test sockets under `/tmp/libtmux-swift-test`. Do not exercise live MCP
client configurations from this target's tests.
