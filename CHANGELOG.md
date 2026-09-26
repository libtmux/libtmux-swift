# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Everything up to `0.1.0` is alpha: the public API may change in any release,
without a deprecation first and without a major version to announce it.
Semantic versioning starts describing this package at `0.1.0`; before that a
version number says only which alpha you have. Pin an exact one.

## [Unreleased]

## [0.1.0-alpha.6] - 2026-09-26

### Added

- `tmux-workspace` is a native executable for tmuxp workspaces: discovery,
  loading, capture, conversion, imports and a Python-tmuxp shell bridge, with
  JSON and NDJSON output, terminal load progress and shell completions. (#12)

- `Server.validateLayouts(_:)` checks a batch of named or saved layouts with
  desired pane counts before mutation. Version-sensitive names follow the
  selected daemon; only an unbound cold endpoint uses the configured client.
  (#12)

- `WindowPlan` gains `windowIndex`, `focus`, `environment` and `windowShell`;
  `PanePlan` gains `focus`, `environment`, `shell`, `sleepBefore` and
  `sleepAfter` — tmuxp's window-index, focus, per-window and per-pane
  environment, shell override and sleep keys. A pane's own `environment`/
  `shell` overrides its window's. (#12)

- `Server.newSession`, `newWindow`, `split` and `splitWindow` accept
  `environment` and `shell` parameters: environment entries reach the created
  pane at start, and `shell` replaces its default shell the same way tmux's
  own trailing shell-command argument does. `newWindow` also accepts an
  explicit `at index:` placement; an occupied index fails. `newSession`
  escapes every argument it builds, so one of its values ending in `;`
  cannot split into a second command. (#12)

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

- `Server.setEnvironment(_:to:in:)` and `Server.setOption(_:to:scope:)` keep a
  value's trailing `;` instead of losing it and everything after it, which
  tmux's argv parser reads as the end of the command. (#12)

- `Server.setEnvironment(_:to:in:)` accepts a variable name beginning with `-`,
  which tmux previously read as flags it does not have. (#12)

- `Server.selectLayout(_:_:)` and MCP `select_layout` reject malformed saved
  trees and unsupported names before dispatch; MCP checks syntax before target
  lookup. (#12)

- `Server.environmentValue(_:in:)` preserves embedded and trailing newlines.
  Missing sessions and other command failures throw; unknown variables and
  removal markers still return `nil`. (#12)

- `WorkspaceBuilder` rebalances a window between splits, so a window of five or
  more panes builds at a default terminal size instead of failing with "size or
  position no space for a new pane". (#12)

- `WorkspaceBuilder.build(_:on:)` rejects invalid layout names and saved-layout
  trees before scripts or session changes, protecting existing sessions from
  malformed layouts that can crash tmux. Geometry correction and pruning remain
  with tmux. (#12)

- `Server.hasSession(_:)` lists sessions and compares names in Swift instead of
  asking tmux to resolve a plain `-t name`, which reads an unambiguous
  abbreviation as a match: a server holding only `alphabet` answered yes for
  `hasSession("alpha")`. (#12)

- `TmuxVersion`'s `Comparable` conformance ranks a `next-X.Y` build below the
  release it names instead of equal to it; every other build tag (`rc`,
  `openbsd`, `master`) still ranks with the number it names. (#12)

- MCP `run_shell_command` reads its framing through `eval` in a pane whose
  shell captures inherited `DEBUG` traps (bash, zsh) instead of typing it,
  closing the same canonical-input-length gap the file-sourcing path already
  closed for every other shell. (#12)

## [0.1.0-alpha.5] - 2026-09-12

### Added

- `Server.sessions(where:)`, `Server.windows(where:)`, `Server.panes(where:)`
  and `Server.clients(where:)` answer a `FilterExpr` through tmux instead of
  listing a whole server and discarding most of it, so a narrow query costs
  what its result costs rather than what the server holds. They throw
  `FilteredListingError`. The answer matches `filter(_:)` exactly. What tmux
  cannot be trusted to answer the same way widens the predicate and is decided
  locally instead: a regular expression, which runs on this package's bounded
  engine rather than tmux's; a literal tmux cannot compare byte for byte,
  meaning one that is not ASCII — Swift's `==` is canonical equivalence — or
  that contains `#`, whose escape has an exception before `[`; and a glob
  pattern containing a backslash. A glob is pushed down but never negated,
  because tmux matches bytes where Swift matches characters.
  `Server.clients(where:)` never pushes down at all, because `list-clients`
  gained `-f` in tmux 3.4 and this package supports 3.2a. (#11)

- `Server.session(_:)`, `Server.session(named:)`, `Server.window(_:)`,
  `Server.windows(named:)` and `Server.pane(_:)` read one object back without
  listing the rest, and `Server.refresh(_:)` re-reads a `Session`, `Window` or
  `Pane` already held. Absence is `nil`; only a server that cannot answer
  throws. A re-read against a replaced daemon throws
  `TmuxError.serverRestarted` rather than returning the same-numbered object,
  because tmux restarts its ids at zero. (#11)

- `withTmuxError(_:)` narrows a scope's thrown type back to `TmuxError`.
  `Server.using(_:_:)`, `Server.connected(attachingTo:_:)` and
  `Server.withControlMode(attachingTo:_:)` take a closure, and Swift 6.2
  cannot carry a closure's thrown type out of one, so a `throws(TmuxError)`
  function wrapping any of them failed with `thrown expression type 'any
  Error' cannot be converted to error type 'TmuxError'`. (#11)

- `Filterable.filterFormatField(_:)` names the tmux format field a filter id
  reads, which is what lets an expression reach tmux. It defaults to `nil`, so
  an existing conformance keeps compiling and simply filters locally. (#11)

## [0.1.0-alpha.4] - 2026-09-08

### Added

- `Server.enterCopyMode(_:)` enters pane copy mode, while
  `Server.cancelModes(in:)` idempotently clears the pane's entire mode stack.
  Cancellation is not a copy-mode-only inverse. (#9)

### Changed

- **Breaking.** `Pane` now projects typed `isDead`, `modeCount`, and
  `isSynchronized` state, and its public initializer requires those values.
  (#9)

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

- The MCP guide maps every earlier public route and all four removed prompt
  workflows to the current typed tools or an explicit no-replacement
  boundary. (#9)

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

- Development MCP swaps resolve the Swift executable before writing client
  configuration, recognize this repository's root package, and fail without a
  configuration change when Swift is unavailable. Selected swaps and reverts
  now plan and stage every config, backup, and recovery-state destination as
  one reverse-rollback transaction. Versioned recovery ownership refuses later
  edits, replacements, or symlink changes without consuming recovery, and dry
  runs remain read-only. (#9)

- Explicit dimensions for detached sessions are preserved on tmux 3.2a,
  matching newer supported releases when tmux initially uses its default
  size. (#9)

- Leading-dash key input, pasted text, names, and wait channels are passed to
  tmux as literal operands on every supported release. (#9)

- `run_shell_command` preserves inherited Bash and zsh `ERR` and `DEBUG` traps
  for the authored command without exposing MCP framing to those traps. (#9)

- `Server.waitForOutput(in:matching:stoppingAt:requiringFreshOutput:timeout:tailLimit:)`
  throws `OutputWaitError.tmux(.cancelled)` when its task is cancelled while
  the wait is suspended between tmux notifications. It previously ignored
  cancellation there and never returned, so a cancelled wait left its caller
  suspended for the life of the process. (#8)

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

### Development

- Every CI job carries a timeout. The `ubuntu-latest / tmux 3.7a` lane hung in
  its test step for six hours before GitHub's ceiling stopped it, while its
  seven sibling lanes finished in about three minutes. (#10)

## [0.1.0-alpha.3] - 2026-08-30

### Added

- `PaneCapture` reports captured content and any trailing bytes discarded to
  satisfy a caller's limit. (#7)

- `ToolAuthority` provides an exact MCP tool allowlist, including
  `LIBTMUX_MCP_TOOLS` configuration. (#7)

### Changed

- **Breaking.** Public session, window, pane, client, and server identifiers
  are typed values tied to a `ServerIncarnation`; use `rawValue` only when a
  textual identifier is required. (#7)

- **Breaking.** Window-placement APIs use `WindowLink`, and window creation
  returns `WindowAppearance`; use its `window` property when only the
  underlying window is needed. (#7)

- **Breaking.** Regex filters take `RegexPattern` and can throw
  `RegexMatchError`; construct the pattern with `try` and handle filtering as
  a throwing operation. (#7)

- **Breaking.** Control notifications use a throwing stream; consume them with
  `for try await` and handle terminal transport failures. (#7)

- **Breaking.** `TmuxServers.discover` returns `ServerDiscovery`; read
  `servers`, inspect truncation, and handle cancellation as an error. (#7)

- **Breaking.** The package product `TmuxTestSupport` is renamed
  `TmuxFixture`; update package dependencies and imports. (#7)

- **Breaking.** MCP targets and results use process-local opaque references
  instead of raw tmux identifiers; clients must list resources again after
  the MCP process restarts. (#7)

- MCP starts read-only by default, and an empty tool allowlist grants no
  mutation authority. (#7)

- Output waits preserve the final partial snapshot and report
  `expiredWhileReading` when the deadline expires during capture. (#7)

- MCP and control-mode reads return typed limit and transport failures instead
  of unbounded or silently truncated data. (#7)

### Security

- Format-reading and format-watching APIs reject shell interpolation syntax
  such as `#()` before invoking tmux. (#7)

- Session names, working directories, buffer paths, and command arguments are
  passed as literal data rather than reinterpreted as shell or tmux syntax.
  (#7)

- MCP mutation tools enforce caller authority and exact resource identity
  before changing tmux state. (#7)

### Fixed

- Alternate-screen output waits retain split escape sequences, honor the
  remaining deadline, and return the last complete snapshot. (#7)

- Waits apply death, match, and timeout precedence consistently and read their
  initial pane state only once. (#7)

- Control-mode blocks preserve notification order and literal semicolons.
  (#7)

- Workspace rollback requests cancellation and returns after a five-second
  cleanup deadline even when the transport ignores cancellation. Cleanup
  failure is reported without hiding the original error. (#7)

- Option reads and writes resolve the requested tmux scope instead of falling
  through to a similarly named option elsewhere. (#7)

- `run_shell` preserves literal command text and reports the command's actual
  completion outcome. (#7)

### Removed

- **Breaking.** Obsolete public MCP result-carrier structs are removed; read
  the typed structured value from `ToolOutcome` instead. (#7)

## [0.1.0-alpha.2] - 2026-08-16

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

- Thirteen more MCP tools, chosen to close the gaps an agent actually hits:
  `list_servers` (the one question no other tool can answer), `show_options`,
  `show_environment` and `show_hooks` (reading configuration, where only
  writing it existed), `rename`, `select`, `resize_pane`, `select_layout`,
  `respawn_pane`, `paste_text` (text that must not be read as key names),
  `set_environment` and `kill_server`.
- `TmuxServers.discover(in:tmuxExecutable:)` finds the tmux servers running on
  a machine. A socket file is not a server — tmux leaves the file behind when
  it exits — so each candidate is asked whether it answers.
- `Server.tmuxExecutable` and `Server.shellInvocation`, for a consumer that
  must spawn or compose a tmux command reaching this same server.
- `Server.capture(_:since:limit:)` and the `capture_since` tool read only what
  a pane has printed since a cursor, so watching something across turns stops
  re-sending the screen. The cursor remembers what the last row said as well as
  where it was, because a row rewritten in place — a spinner, a progress bar —
  is new content at an old position. A respawned pane is reported rather than
  read as a continuation of the program it replaced.
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

Never tagged: this was superseded by `0.1.0-alpha.2` before it was
published, so there is no release to install. The notes are kept because
they describe what the package is, which the next entry then changes.

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
