# Changelog

Notable changes to `LibTmux`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one.

The other products keep their own changelogs:
[`TmuxWorkspace`](Sources/TmuxWorkspace/CHANGELOG.md) and
[`LibTmuxMCP`](Sources/LibTmuxMCP/CHANGELOG.md). The products share one
version, so every release has a section in each file. Changes that span
products, such as documentation, CI and release tooling, are listed here.

## [Unreleased]

## [0.1.1] - 2026-11-01

### Added

- `Server()` builds a server that passes tmux neither `-L` nor `-S`, so tmux
  picks the server: the one in `TMUX` inside tmux, and its default socket
  elsewhere. It takes `tmuxExecutable`, `configurationFile` and `environment`,
  the last being where the two variables are read from. `LIBTMUX_SOCKET_PATH`
  (passed as `-S`) or `LIBTMUX_SOCKET` (passed as `-L`) names another, the path
  wins when both are set, and a variable that is empty or only whitespace counts
  as unset. `Server(socketPath:)` and `Server(socketName:)` leave both
  variables unread. (#93)

### Changed

- **Breaking.** `Endpoint` gained a `tmuxChoice` case, which is the
  `Server.endpoint` of a server that names no socket. A `switch` over
  `Endpoint` that lists only `.socketName` and `.socketPath` stops compiling;
  add a case for it, and read a socket from an endpoint only when it has one.
  (#93)

- This package's own test run must be started with `Scripts/swift-test`, which
  takes `swift test`'s arguments. It removes `TMUX`, `TMUX_PANE` and every
  `LIBTMUX_SOCKET*` variable, gives the run a private `TMUX_TMPDIR` under
  `/tmp/libtmux-swift-test/`, and stops any tmux server the run left behind,
  failing the run when it finds one. A bare `swift test` of this package is
  refused by the first fixture it reaches. A package that depends on
  `TmuxFixture` is held to the same rules only when its run sets
  `LIBTMUX_TEST_SANDBOX`, as the script does. (#92)

- `tmuxExecutablePath()` in `TmuxFixture` takes `LIBTMUX_TMUX_BIN`, then the
  first `tmux` on `PATH`, then `/usr/bin/tmux`, `/usr/local/bin/tmux` and
  `/opt/homebrew/bin/tmux`. It used to skip `PATH` and take the first of those
  three, so a suite started without the variable tested `/usr/bin/tmux` even
  when a newer `tmux` came first on `PATH`, and cases that need a newer tmux
  skipped. A bare name in the variable is now searched for on `PATH`, as
  `Server` searches for its `tmuxExecutable`. Set `LIBTMUX_TMUX_BIN` to keep
  testing one binary. (#96)

- JSON layouts (`layout-json`) require tmux 3.8, the first release that
  accepts one. `Server.selectLayout(_:_:)`, `Server.validateLayouts(_:)` and
  the MCP `select_layout` tool refuse one on an older tmux before the layout
  command is sent. A version probe may run first. The refusal names tmux 3.8
  as the minimum; upgrade to tmux 3.8 to apply a JSON layout.

  A raw `select-layout`, including one sent over a `ControlSession`, now
  refuses a JSON layout before it is sent on tmux below 3.8, and a malformed
  `{` operand on tmux 3.4 through versions below 3.8; tmux used to reject
  both after the send. (#82)

- CI tests tmux 3.3a and 3.8 on a push and a pull request. A tag, which is a
  release, and a `workflow_dispatch` with `scope: full` test every release
  from 3.3a through 3.8, the pinned master and the refusal lanes. A dispatch
  also takes `tmux-ref` (a release, tag, branch or commit), `swift` and
  `tmate`, and the `required` job reports whether every planned job passed.
  (#89)

## [0.1.0] - 2026-10-25

### Changed

- Releases are numbered `0.1.N` from `0.1.0` on, and none carries an `-alpha`
  tag unless the maintainer asks for one. Each release increments `N` and may
  change or remove exported identifiers; the changelog marks each break, so pin
  an exact version to avoid one. The README, the `LibTmux` documentation
  catalogue and the contributor guides say so in place of the alpha warning.
- The install section recommends `from: "0.1.0"`, which resolves once `0.1.0` is
  tagged; every earlier tag is a prerelease that a range does not match.
- The MCP `wait_for_text` description and `docs/mcp-contract.md` now say
  that it streams from tmux 3.7 and reads the screen on a timer below it,
  and list its outcomes. The platform page and README describe macOS as
  best effort with no CI, and the platform page lists what happens when a
  refused command is nested in command text. (#68)

## [0.1.0-alpha.8] - 2026-10-24

### Added

- `capabilities.json` at the repository root lists the tmux releases each
  optional feature and release defect covers, for the documentation's
  capability pages. It is written from the table the version gates read, and
  a test fails when the two differ. (#48)

### Changed

- CI no longer runs macOS: the `macos` workflow is gone, and the `ci` workflow
  carries no macOS branches. macOS stays supported on a best-effort basis, and
  CI coverage for it is highly limited, so a macOS-only regression is not
  caught before merge. (#60)

- `Server.connected(attachingTo:_:)`, `Server.using(_:_:)` with a connected
  mode and `Server.withControlMode(attachingTo:_:)` need a 3.7 daemon, decided
  before any client attaches, and throw
  `TmuxError.unsupportedTmuxVersion(reported:required:operation:)` below it.
  tmux 3.2a and 3.6b servers crash when a control client attaches and detaches
  quickly. Direct mode, `Server.snapshot()` and the workspace builder keep
  working on every supported release. (#48)

- `Server.waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)`
  reads the pane on a timer below 3.7 instead of attaching a control client;
  output that changes no row, such as a line of only blanks, is not seen as an
  event there. (#48)

- `Server.deleteBuffer(named:)` and the MCP `paste_text` tool need tmux 3.4:
  earlier releases can delete or rename an unrelated buffer when the named one
  is missing. `paste_text` refuses before it stages a buffer. (#48)

- A literal command batch is refused before dispatch when its release cannot
  run it safely: `break-pane` without `-n` on exactly 3.7, a window or session
  name holding `:` or `.` on exactly 3.7, `split-window -p` on exactly 3.4, a
  `select-layout` argument tmux 3.3a cannot parse, and `refresh-client -l`
  below 3.6a, which exits a 3.3a server with a client attached and a 3.4
  through 3.6 server when that client leaves before its terminal answers.
  Command names are read as tmux reads them, so an alias or a unique prefix
  such as `break-p` is the same command, and `ControlSession.send(_:)` applies
  the same check. Nested command strings, such as an `if-shell` body, are not
  read. (#48, #64)

### Fixed

- `Server.breakPane(_:from:named:)` returns the window of a pane that was alone
  in it on tmux 3.3a through 3.5, which print no id for that case. (#48)

- `Server.waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)`
  matches a pattern that spans a wrapped row, and a killed server ends it as
  `paneClosed` with the output so far, the same as a killed pane, instead of
  throwing a transport error. (#48)

## [0.1.0-alpha.7] - 2026-10-18

### Changed

- `Server` supports tmux 3.3a and newer, judged by the daemon the endpoint
  reaches rather than the client executable: it reads the daemon's release
  before it sends anything, refuses an older one with
  `TmuxError.unsupportedTmuxVersion(reported:required:operation:)` before the
  command has any effect, and holds every batch to the release it read, so a
  daemon replaced in between refuses the batch instead of running it. Where
  nothing listens yet, the executable that would start the daemon is held to
  the same floor. The release is read without running a command that fires a
  configured hook. A tmux 3.0a or 3.1c daemon is refused the same way, however
  it answers the probe. (#47)

- `TmuxVersion` ranks a release candidate (`3.8-rc2`) below the release it
  names, like a `next-` snapshot, and `Server.version()` accepts the banner
  tmux 3.3a prints when the executable is not named `tmux`. (#47)

- `tmux-workspace` reports a tmux older than 3.3a as `tmux_unsupported`, in
  text and JSON output, and `libtmux-mcp` names the floor and the remedy when
  it refuses to start on one. (#47)

- Panes built over a connection match panes built directly, heights included,
  on every supported release; the 3.2a exception is gone. (#47)

### Fixed

- `Server.validateLayouts(_:)`, `Server.selectLayout(_:_:)` and the MCP
  `select_layout` tool accept the JSON layout documents that tmux 3.8 and its
  release candidates from 3.8-rc2 report in `#{window_layout}`, so a layout
  read from such a window can be applied again, including
  `tmux-workspace freeze` followed by `load`. (#47)

## [0.1.0-alpha.6] - 2026-09-26

### Added

- `Server.validateLayouts(_:)` checks a batch of named or saved layouts with
  desired pane counts before mutation. Version-sensitive names follow the
  selected daemon; only an unbound cold endpoint uses the configured client.
  (#12)

- `Server.newSession`, `newWindow`, `split` and `splitWindow` accept
  `environment` and `shell` parameters: environment entries reach the created
  pane at start, and `shell` replaces its default shell the same way tmux's
  own trailing shell-command argument does. `newWindow` also accepts an
  explicit `at index:` placement; an occupied index fails. `newSession`
  escapes every argument it builds, so one of its values ending in `;`
  cannot split into a second command. (#12)

### Fixed

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

- `Server.hasSession(_:)` lists sessions and compares names in Swift instead of
  asking tmux to resolve a plain `-t name`, which reads an unambiguous
  abbreviation as a match: a server holding only `alphabet` answered yes for
  `hasSession("alpha")`. (#12)

- `TmuxVersion`'s `Comparable` conformance ranks a `next-X.Y` build below the
  release it names instead of equal to it; every other build tag (`rc`,
  `openbsd`, `master`) still ranks with the number it names. (#12)

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

- The MCP guide maps every earlier public route and all four removed prompt
  workflows to the current typed tools or an explicit no-replacement
  boundary. (#9)

### Fixed

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

- `Server.waitForOutput(in:matching:stoppingAt:requiringFreshOutput:timeout:tailLimit:)`
  throws `OutputWaitError.tmux(.cancelled)` when its task is cancelled while
  the wait is suspended between tmux notifications. It previously ignored
  cancellation there and never returned, so a cancelled wait left its caller
  suspended for the life of the process. (#8)

### Development

- Every CI job carries a timeout. The `ubuntu-latest / tmux 3.7a` lane hung in
  its test step for six hours before GitHub's ceiling stopped it, while its
  seven sibling lanes finished in about three minutes. (#10)

## [0.1.0-alpha.3] - 2026-08-30

### Added

- `PaneCapture` reports captured content and any trailing bytes discarded to
  satisfy a caller's limit. (#7)

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

### Fixed

- Alternate-screen output waits retain split escape sequences, honor the
  remaining deadline, and return the last complete snapshot. (#7)

- Waits apply death, match, and timeout precedence consistently and read their
  initial pane state only once. (#7)

- Control-mode blocks preserve notification order and literal semicolons.
  (#7)

- Option reads and writes resolve the requested tmux scope instead of falling
  through to a similarly named option elsewhere. (#7)

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

### Changed

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
- `ControlSession.notifications` hands every observer its own stream. It was a
  single `AsyncStream`, and two iterators of one of those divide the elements
  rather than each receiving all of them — so a waiter and a watcher on the
  same connection each silently missed about half of what they asked for.
  Anything that arrived before the first observer is replayed to it.

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
- `TmuxTestSupport`, the fixture the suite provisions servers through, vended
  so a consumer's own tests can use it.

### Notes

- Requires Swift 6.2. On Darwin, build with Xcode's toolchain rather than one
  from swift.org — see the platform notes in the README.
- Tested against tmux 3.2a through 3.7b on Linux, and against the ends of that
  range on macOS.
