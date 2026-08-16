# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Everything up to `0.1.0` is alpha: the public API may change in any release,
without a deprecation first and without a major version to announce it.
Semantic versioning starts describing this package at `0.1.0`; before that a
version number says only which alpha you have. Pin an exact one.

## [Unreleased]

### Added

- Waiting that is driven by tmux rather than by a timer.
  `Server.waitForOutput(in:matching:stoppingAt:requiringFreshOutput:timeout:tailLimit:)`
  blocks on a pane's `%output` and matches against the rendered grid, so a
  quiet pane costs nothing while it waits. The condition is checked before it
  is blocked on — a pattern already showing returns at once with
  `matchedAtEntry` set, because "wait until it is listening" is answered by
  something already listening; `requiringFreshOutput` is the opposite reading,
  for re-running a command whose output looks identical. Each read takes a
  bounded lookback above the visible rows, so output that scrolls past between
  two reads is still found. `FormatSubscription` and
  `ControlSession.watch(_:)` register a `refresh-client -B` subscription, which
  reports a format's value changing without reading any scrollback at all —
  `#{pane_current_command}` answers "is my command done?" exactly.
  A new `Waiting` article in the DocC catalogue covers which to reach for.
- `LibTmuxMCP` grew from six tools to twenty-five, and gained the surfaces an
  MCP client expects: `tmux://` resources, workflow prompts, server
  instructions, per-tool JSON Schema with behaviour annotations,
  `structuredContent`, and protocol-revision negotiation from `2024-11-05`
  through `2025-11-25`.
- Safety tiers on the MCP server. `LIBTMUX_SAFETY` selects `readonly`,
  `mutating` or `destructive`, and anything above the tier is hidden from
  `tools/list` as well as refused.
- The MCP server recognises the pane it is running in. `list_panes` marks it,
  `describe_server` names it, and the kill tools refuse it unless
  `confirm_self` is passed. Identity is the tmux server's process id rather
  than its socket path, so a pane id repeated on another tmux is not mistaken
  for the caller's.
- `apply_workspace`, `snapshot`, `run_shell`, `run_commands`, `search_panes`,
  `capture_pane` and `describe_server` as MCP tools.

### Changed

- MCP tools declare an `outputSchema` wherever the answer's shape is
  guaranteed, and listings answer under a name — `{"panes": [...]}` rather
  than a bare array. MCP types `structuredContent` as an object, so an array
  was not a result a validating client had to accept. The schemas are checked
  against what the tools really return rather than against each other.
- Long MCP calls report progress when the client asks for it with a
  `_meta.progressToken`, which the Codex CLI sends on every call.

- `ControlSession.notifications` hands every observer its own stream. It was a
  single `AsyncStream`, and two iterators of one of those divide the elements
  rather than each receiving all of them — so a waiter and a watcher on the
  same connection each silently missed about half of what they asked for.
  Anything that arrived before the first observer is replayed to it.
- The MCP server serves requests concurrently, and honours
  `notifications/cancelled`. It read one line, answered it, and only then read
  the next, so a single blocking call stopped everything — including the
  `ping` that would have shown it was alive.
- Every MCP wait is clamped to a ceiling
  (`LIBTMUX_MCP_WAIT_MAX_SECONDS`, itself capped at 300 seconds) and reports
  the value actually enforced.
- MCP tools reject an argument they do not declare, naming the ones they
  accept. Silently ignoring a misspelt `pattern` made a wait look like a quiet
  pane.
- `run_command` refuses the tmux commands that cannot return without a
  terminal — `wait-for`, `attach-session`, `command-prompt`, `choose-*` — and
  names the tool that does the same job safely.

### Fixed

- `read_format` could not be called over MCP. The protocol layer built its
  request by naming the arguments it carried and did not carry `template` or
  `target`, so every call failed as though the client had sent nothing. Tool
  arguments now travel as one object and are read through the same declaration
  that generates the schema, which is what makes the two impossible to
  disagree.

## [0.1.0-alpha.1] - 2026-08-16

The first alpha. Everything below is new, so this says what the package is
rather than what changed in it.

### Added

- `Server`, `Session`, `Window`, `Pane` and `Client` as values, addressed by
  socket path or socket name. Copies of a server compare equal and share one
  runtime, so passing one across a task boundary needs no ceremony.
- Listings, `capture`, `run`, and the mutations tmux exposes for building and
  rearranging sessions, windows and panes.
- `snapshot()`, which reads every object as one consistent picture and refuses
  a partial one: the server's identity is read before and after, so a daemon
  that died and was replaced mid-read is reported rather than described.
- Control mode. `connected(attachingTo:)` runs work over one connection, and
  the server reports what changed on `notifications` without being asked.
  Concurrent sends are matched to their replies by the number tmux answers with.
- `FilterExpr`, a filter that travels: it lowers a Swift key path to a stable
  wire id, so a predicate can cross a process boundary as JSON.
- `TmuxWorkspace`, which builds a session from a plan described in Swift or
  JSON — and from a tmuxp YAML file behind the `YAMLWorkspaces` trait.
- `LibTmuxMCP` and the `libtmux-mcp` executable, an MCP server over stdio.
- `TmuxTestSupport`, the fixture the suite provisions servers through, vended
  so a consumer's own tests can use it.

### Notes

- Requires Swift 6.2. On Darwin, build with Xcode's toolchain rather than one
  from swift.org — see the platform notes in the README.
- Tested against tmux 3.2a through 3.7b on Linux, and against the ends of that
  range on macOS.
