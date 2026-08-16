# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Everything up to `0.1.0` is alpha: the public API may change in any release,
without a deprecation first and without a major version to announce it.
Semantic versioning starts describing this package at `0.1.0`; before that a
version number says only which alpha you have. Pin an exact one.

## [Unreleased]

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
