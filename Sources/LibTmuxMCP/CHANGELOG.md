# Changelog

Notable changes to `LibTmuxMCP`.

It covers the `LibTmuxMCP` library and the `libtmux-mcp` executable. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.

The products share one version, so every release has a section here. Changes
to `LibTmux`, and changes that span products, such as documentation, CI and
release tooling, are in the [`LibTmux` changelog](../../CHANGELOG.md).
`TmuxWorkspace` keeps [its own](../TmuxWorkspace/CHANGELOG.md).

## [Unreleased]

## [0.1.1] - 2026-11-01

### Changed

- **Breaking.** `libtmux-mcp` with neither socket variable passes tmux no
  socket and serves
  the server tmux picks, where it used to start a daemon of its own on the
  socket `libtmux-mcp`, from a bundled configuration, grant it `teardown` and
  stop it when stdio ended. That daemon, the bundled configuration and the
  default `teardown` are gone; name `teardown` in `LIBTMUX_TOOLSETS` to grant
  it. Setting both variables is no longer an error: the path wins. An empty
  variable no longer fails startup, it counts as unset. `tmux://capabilities`
  reports `socket-path`, `socket-name` or `tmux-choice` as `socketProvenance`,
  where it said `operator-current` or `default-dedicated`, and names the
  socket in `attachCommand` once a server runs. (#93)

- **Breaking.** `ServerConfiguration` no longer has an
  `isDefaultDedicatedMinimal` property, and its `socketName` is `nil` unless
  `LIBTMUX_SOCKET` is set, where it was `libtmux-mcp`. `ToolAuthority` no
  longer takes or stores `usedExplicitToolsets`; drop the argument. (#93)

## [0.1.0] - 2026-10-25

No entries for `LibTmuxMCP`.

## [0.1.0-alpha.8] - 2026-10-24

No entries for `LibTmuxMCP`.

## [0.1.0-alpha.7] - 2026-10-18

No entries for `LibTmuxMCP`.

## [0.1.0-alpha.6] - 2026-09-26

### Fixed

- MCP `run_shell_command` reads its framing through `eval` in a pane whose
  shell captures inherited `DEBUG` traps (bash, zsh) instead of typing it,
  closing the same canonical-input-length gap the file-sourcing path already
  closed for every other shell. (#12)

## [0.1.0-alpha.5] - 2026-09-12

No entries for `LibTmuxMCP`.

## [0.1.0-alpha.4] - 2026-09-08

### Changed

- **Breaking.** The MCP surface is now an authoritative 45-tool capability
  registry split across `inspect`, `manage`, `execute`, and `teardown`.
  Registration, dispatch, schemas, descriptions, selection, and the static
  `tmux://capabilities` report use the same definitions. (#9)

- **Breaking.** `LIBTMUX_TOOLSETS`, `LIBTMUX_TOOLS`, and
  `LIBTMUX_EXCLUDE_TOOLS` replace safety tiers and the legacy allowlist.
  `LIBTMUX_SOCKET` selects a name, `LIBTMUX_SOCKET_PATH` selects an absolute
  path, and `LIBTMUX_TMUX_CONFIG` selects configuration provenance. An earlier
  exact `LIBTMUX_MCP_TOOLS` allowlist maps to empty `LIBTMUX_TOOLSETS` plus the
  same names in `LIBTMUX_TOOLS`. (#9)

- The default launch uses a dedicated `libtmux-mcp` socket and bundled minimal
  configuration. It grants teardown by default only when that daemon retains
  this process's launch nonce from the minimal configuration, and removes the
  daemon on exit only while both its nonce and incarnation still match. (#9)

### Fixed

- `run_shell_command` reaches a pane whose shell reads a bounded line. Its
  framing went to the pane as one line, and two ceilings cut it: a tty in
  canonical mode discards input past `MAX_CANON`, which is 1024 on Darwin
  against 4096 on Linux, and tmux drops a `send-keys` argument once it passes
  what tmux will carry. Either way the command never ran, the call timed out
  without a status, and the lease it kept refused that pane afterwards — so on
  macOS the tool did not work in a `dash` or plain `sh` pane at all, and lost
  long commands in a Bash or zsh pane. Shells that do not capture inherited
  traps now source the framing from a file created for this process alone and
  readable only by its owner; the rest stay typed, because Bash does not expose
  a `DEBUG` trap inside a sourced file, and the nonce naming each run is
  shorter so the line fits. (#9)

- `wait_for_text` answers within its own schema when it matches nothing.
  `matched`, `matchedIndex`, and `cursor` are declared present-and-nullable,
  but Swift's synthesised encoding drops a nil optional, so the reply omitted
  them and the server rejected its own response. They are encoded
  explicitly. (#9)

- `run_shell_command` preserves inherited Bash and zsh `ERR` and `DEBUG` traps
  for the authored command without exposing MCP framing to those traps. (#9)

### Removed

- **Breaking.** The MCP `enter_copy_mode` and `exit_copy_mode` tools are
  removed. Read history through the capture, search, snapshot, and cursor tools
  instead; none of them take ownership of a human client's pane modes. (#9)

- **Breaking.** MCP prompts, dynamic resources, raw command families,
  workspace and buffer surfaces, and ordered safety-tier APIs are removed. The
  static capability resource is the only MCP resource. (#9)

### Security

- Pane-input tools fail closed on incomplete or malformed caller context and
  refuse terminal-attended panes, dead panes, nonzero human-owned mode stacks,
  and active-operation overlap from fresh typed snapshots. Zoomed terminal
  clients protect their active pane, unzoomed clients protect their active
  window, and control clients do not count. Synchronized sends check every
  effective configured member; batch rows recheck independently, while paste
  remains target-only. Empty paste without Enter still runs its safety check,
  then returns without a buffer or input dispatch. (#9)

- `run_shell_command` requires one configured pane running a recognized POSIX
  shell, uses one nonqueueing reservation across setup and completion, rechecks
  before dispatch, pins its tmux route, and contains the requested command so
  shell state and `exit` do not escape into the interactive parent. A second
  run refuses instead of waiting. These checks assume a trusted shell, tmux
  daemon, and configuration. (#9)

- Tool definitions classify direct process reach, effects, output classes,
  secret and untrusted output, internal interpreter sinks, nested authority,
  and future input amplification. Public rows expose one schema-keyed
  `inputLiteralization` map instead of the sink table. Tmux-format-bearing
  names and paths are literalized before use, and synchronized pane input
  reports every resolved target. (#9)

- Each advertised tool carries the same complete capability row as the static
  resource under a namespaced `_meta` key. (#9)

- Pane search has fixed aggregate pane, line, byte, and wall-time ceilings plus
  a regex-work budget, and successful truncated results name the reached
  limit. (#9)

- The read aggregate retains full nested envelopes where they fit, marks
  per-row result truncation, reports success, failure, stop, and truncation
  totals, and keeps the complete newline-delimited JSON-RPC response at or
  below 1,000,000 bytes. Requests whose IDs cannot fit inside that ceiling fail
  with a bounded `id: null` invalid-request response before dispatch. (#9)

## [0.1.0-alpha.3] - 2026-08-30

### Added

- `ToolAuthority` provides an exact MCP tool allowlist, including
  `LIBTMUX_MCP_TOOLS` configuration. (#7)

### Changed

- **Breaking.** MCP targets and results use process-local opaque references
  instead of raw tmux identifiers; clients must list resources again after
  the MCP process restarts. (#7)

- MCP starts read-only by default, and an empty tool allowlist grants no
  mutation authority. (#7)

### Security

- MCP mutation tools enforce caller authority and exact resource identity
  before changing tmux state. (#7)

### Fixed

- `run_shell` preserves literal command text and reports the command's actual
  completion outcome. (#7)

### Removed

- **Breaking.** Obsolete public MCP result-carrier structs are removed; read
  the typed structured value from `ToolOutcome` instead. (#7)

## [0.1.0-alpha.2] - 2026-08-16

### Added

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

- Thirteen more MCP tools, chosen to close the gaps an agent actually hits:
  `list_servers` (the one question no other tool can answer), `show_options`,
  `show_environment` and `show_hooks` (reading configuration, where only
  writing it existed), `rename`, `select`, `resize_pane`, `select_layout`,
  `respawn_pane`, `paste_text` (text that must not be read as key names),
  `set_environment` and `kill_server`.
- MCP tools declare an `outputSchema` wherever the answer's shape is
  guaranteed, and listings answer under a name — `{"panes": [...]}` rather
  than a bare array. MCP types `structuredContent` as an object, so an array
  was not a result a validating client had to accept. The schemas are checked
  against what the tools really return rather than against each other.
- Long MCP calls report progress when the client asks for it with a
  `_meta.progressToken`, which the Codex CLI sends on every call.

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

### Added

- `LibTmuxMCP` and the `libtmux-mcp` executable, an MCP server over stdio.
