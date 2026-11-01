# Changelog

Notable changes to `TmuxWorkspace`.

It covers the `TmuxWorkspace` library and the `tmux-workspace` executable. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.

The products share one version, so every release has a section here. Changes
to `LibTmux`, and changes that span products, such as documentation, CI and
release tooling, are in the [`LibTmux` changelog](../../CHANGELOG.md).
`LibTmuxMCP` keeps [its own](../LibTmuxMCP/CHANGELOG.md).

## [Unreleased]

## [0.1.1] - 2026-11-01

### Changed

- `tmux-workspace` with no `-S` or `-L` uses the socket `LIBTMUX_SOCKET_PATH`
  and then `LIBTMUX_SOCKET` name, and with neither passes tmux no socket, where
  it used to pass the `TMUX` socket as `-S` and, outside tmux, refused to run.
  Outside tmux it now acts on tmux's default socket, which is your own server
  unless the environment says otherwise; name `-L` for a server of its own. An
  attached `load` inside tmux, `load --append` and `freeze` without a session
  name still use the `TMUX` socket, and `shell` passes tmuxp a socket a variable
  chose, because tmuxp reads neither variable. (#93)

## [0.1.0] - 2026-10-25

No entries for `TmuxWorkspace`.

## [0.1.0-alpha.8] - 2026-10-24

No entries for `TmuxWorkspace`.

## [0.1.0-alpha.7] - 2026-10-18

No entries for `TmuxWorkspace`.

## [0.1.0-alpha.6] - 2026-09-26

### Added

- `tmux-workspace` is a native executable for tmuxp workspaces: discovery,
  loading, capture, conversion, imports and a Python-tmuxp shell bridge, with
  JSON and NDJSON output, terminal load progress and shell completions. (#12)

- `WindowPlan` gains `windowIndex`, `focus`, `environment` and `windowShell`;
  `PanePlan` gains `focus`, `environment`, `shell`, `sleepBefore` and
  `sleepAfter` — tmuxp's window-index, focus, per-window and per-pane
  environment, shell override and sleep keys. A pane's own `environment`/
  `shell` overrides its window's. (#12)

- `tmux-workspace load`, inside tmux, verifies the invoking pane before
  building anything — a valid `TMUX`/`TMUX_PANE` naming an attached client on
  the target socket — and refuses at exit 2 rather than build against the
  wrong server; `-d` loads without attaching, including from a `run-shell` key
  binding. (#12)

- `tmux-workspace load`, with a terminal and no `-y`/`--yes`, asks before
  switching to or attaching a session the load would create or reuse.
  Declining is a normal outcome, exit 0: nothing is built or changed. Without
  a terminal, under `--json`/`--ndjson`, or with `-y`/`--yes`, it proceeds
  without asking. A session an interruption left standing is named in the
  failure record's `retained_state`, `status: partial`. (#12)

- `tmux-workspace load --append` moves the client to an appended window only
  when that window sets `focus: true`; honours an explicit `window_index`,
  failing with tmux's own reason on a collision with a window already in the
  session; and with no invoking pane is a usage error, exit 2. `-a` is accepted
  as its short form. The human summary after appending says `Appended
  <session>`, naming the session that received the windows. (#12)

- `tmux-workspace load` reads `workspace_builder_options` (`pane_readiness`,
  `global_options`, `options_after`, `start_directory`); a setting it does not
  implement is a warning, not a refusal, and any key prefixed `x-`, at any
  level, passes through unevaluated instead of failing the load. (#12)

- `tmux-workspace load` sizes every window it creates from the terminal it
  runs in, matching tmuxp's `TMUXP_DETECT_TERMINAL_SIZE` and its `COLUMNS`,
  `ROWS` and `LINES` overrides. (#12)

- `tmux-workspace load`'s JSON/NDJSON envelope and error codes match the
  shape the other six ports share; its stderr error record is
  `{"schema_version":1,"code":...,"message":...}`, and an argument, import or
  unhandled error prints one plain sentence rather than a doubled prefix or a
  Swift enum literal. (#12)

- `tmux-workspace load --ndjson` streams a `session-created` event per
  session and brackets `before_script` output live with `script-started`,
  `script-output` and `script-completed`, instead of only reporting it once
  the whole load finishes. (#12)

- `--log-level` (`debug`, `info`, `warning`, `error`, `critical`; default
  `warning`) sets the minimum severity for advisory diagnostics: capture,
  bootstrap and shell warnings are hidden below it, while result data and
  fatal errors stay visible regardless. `load --log-file` appends the same
  records as compact, owner-only JSON to a regular file, opened before any
  document or backend work. (#12)

- `tmux-workspace freeze` selects an explicit, current-pane or sole session,
  prompting human callers when several sessions remain, and captures local
  session and window options. `--quiet` preserves documents and machine results
  while suppressing explanatory messages. (#12)

- `tmux-workspace freeze` omits the top-level `environment` block that would
  otherwise carry the caller's own `SSH_AUTH_SOCK`, `SSH_AGENT_PID`, `DISPLAY`
  and `WAYLAND_DISPLAY`, and omits a pane's `shell_command` when it runs the
  session's own `default-shell` rather than naming it explicitly; when written,
  `shell_command` is always a YAML list. It infers JSON from a `.json`
  destination regardless of letter case, and requires `--save-to` or
  `--json`/`--ndjson`, naming both in the usage error otherwise. (#12)

- `tmux-workspace freeze` refuses a session name holding `.` or `:` before
  checking whether it exists, rather than risk `-t name` resolving to the
  wrong session on a tmux version that treats either character as a
  separator. (#12)

- `tmux-workspace import teamocil` and `import tmuxinator` translate a source
  into a native workspace, preserving command groups, pane order and default
  focus. `import tmuxinator` additionally refuses unexpanded ERB markup
  (`<%= %>`) rather than load it as a literal command; `import teamocil`
  evaluates no templates, so it preserves the same markup as text. (#12)

- `tmux-workspace shell -c` delegates to tmuxp's Python bridge and reports
  the envelope dotnet, go, java, rs and ts already share; `shell -c --ndjson`
  streams script output live rather than buffering it until the child exits.
  (#12)

- `tmux-workspace ls` lists every `.tmuxp.yaml`, `.tmuxp.yml` and
  `.tmuxp.json` workspace found across the global and project-local
  directories, deduplicated by resolved path. `--tree` groups human output
  under its directory; `--full` adds each row's parsed document. (#12)

- `tmux-workspace search` matches each term as a regular expression against a
  workspace's name, path, session name, window names and pane commands,
  without launching Python. A `field:pattern` term or `--field` (`name`,
  `session`/`s`, `path`/`p`, `window`/`w`, `pane`) narrows which fields a
  pattern reaches; `--any` matches on one pattern rather than all,
  `--invert-match` reports the rows that did not match, and `--ignore-case`,
  `--smart-case`, `--fixed-strings` and `--word-regexp` change how a pattern
  reads. (#12)

- `tmux-workspace convert` writes a workspace as the other of YAML/JSON,
  preserving document mapping values including extension fields. `-y` writes
  it beside the source under the flipped extension without a destination;
  `--save-to` and `--workspace-format` name one explicitly, and `--force`
  permits replacing it. Machine conversion with no destination returns the
  document instead of writing a file. (#12)

- `tmux-workspace edit` opens a resolved workspace file in `$EDITOR`,
  defaulting to `vi`, and refuses one naming no executable at exit 2. (#12)

- `ls` and `search` color workspace names and paths in human output.
  `--color auto|always|never` selects the policy; `NO_COLOR` and
  `FORCE_COLOR` steer `auto`. `load -2` forces 256-color handling in native
  tmux clients. (#12)

- `tmux-workspace --version` and `debug-info` print plain text unless `--json`
  is given; `--help` documents the built-in `--generate-completion-script` flag.
  `tmux-workspace` discovers and resolves a bare name in the first existing
  configured, XDG or legacy directory: a missing configured path falls through,
  an existing empty directory is authoritative, empty `XDG_CONFIG_HOME` defaults
  to `~/.config`, and an imported name stays in its source directory. (#12)

### Changed

- **Breaking.** `WorkspaceBuilderError` gained a `callback(any Error)` case,
  carrying a build callback's own error whole rather than flattening it into a
  tmux invocation failure, and dropped both `Sendable` and `Hashable`: an
  arbitrary `any Error` cannot be guaranteed either. (#12)

- `WorkspaceBuilder` leaves the last pane it built active in a window whose
  panes ask for no focus, matching tmuxp. It left the first. (#12)

- `WorkspaceBuilder.build` no longer rolls an owned session back when the build
  is interrupted rather than failed: the same signal that stopped the build
  could just as well stop the cleanup that would follow it. Rollback now fires
  on an ordinary failure only. (#12)

- `WorkspaceBuilder.build` waits for a newly built pane's shell to draw its
  prompt before sending that pane's first command, instead of sending
  immediately and leaving the terminal to echo the command once and the shell to
  redraw it a second time. A pane or window that names its own `shell` skips
  the wait, and so does one that cannot be read; either sends right away.
  (#12)

### Fixed

- `WorkspaceBuilder.build(_:on:)` retains configured pane order when creating
  three or more panes, so directories, commands and focus follow source order.
  (#12)

- `WorkspaceBuilder.build(_:on:)` focuses the pane its plan configured even when
  the window arrives holding panes the workspace did not ask for, which a user
  hook on `after-new-window` or `split-window` produces. Focus previously landed
  on a pane that had run none of the plan's commands. (#12)

- `WorkspaceBuilder` rebalances a window between splits, so a window of five or
  more panes builds at a default terminal size instead of failing with "size or
  position no space for a new pane". (#12)

- `WorkspaceBuilder.build(_:on:)` rejects invalid layout names and saved-layout
  trees before scripts or session changes, protecting existing sessions from
  malformed layouts that can crash tmux. Geometry correction and pruning remain
  with tmux. (#12)

## [0.1.0-alpha.5] - 2026-09-12

No entries for `TmuxWorkspace`.

## [0.1.0-alpha.4] - 2026-09-08

No entries for `TmuxWorkspace`.

## [0.1.0-alpha.3] - 2026-08-30

### Fixed

- Workspace rollback requests cancellation and returns after a five-second
  cleanup deadline even when the transport ignores cancellation. Cleanup
  failure is reported without hiding the original error. (#7)

## [0.1.0-alpha.2] - 2026-08-16

No entries for `TmuxWorkspace`.

## [0.1.0-alpha.1] - 2026-08-16

### Added

- `TmuxWorkspace`, which builds a session from a plan described in Swift or
  JSON — and from a tmuxp YAML file behind the `YAMLWorkspaces` trait.
