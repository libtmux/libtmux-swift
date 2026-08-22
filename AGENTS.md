# AGENTS.md

Rules for working in this repository: `libtmux` for Swift, a port of
[libtmux](https://github.com/tmux-python/libtmux) for Python, which stays the
reference for what tmux behaviour is worth having.

The package is the repository — `Package.swift` at the root, `Sources/` and
`Tests/` beside it — because SwiftPM resolves a package from a repository root
and cannot be pointed at a subdirectory.

## Every socket names this port

Several ports of libtmux are developed side by side on one machine, and `/tmp`
is shared between all of them. A socket named `libtmux-…` says nothing about
which port left it, so two suites running at once can find each other's servers,
and anything sweeping up by prefix can kill a server it never started. Debugging
that looks like a flaky test in whichever port noticed first.

So every tmux socket this package creates lives under a language-scoped root:

| Root | Who uses it |
| --- | --- |
| `/tmp/libtmux-swift-test/` | the test suite, one directory per case |
| `/tmp/libtmux-swift-dev/` | the benchmark, and anything run by hand |

Two rules follow:

- Never create a socket outside those roots — including in a throwaway shell
  command while investigating something. A probe socket is the easiest way to
  leave a server another port then trips over.
- Never remove anything under `/tmp/libtmux-*` that is not one of these two
  roots. Those belong to other ports, and a running server may be behind them.

`Scripts/check_socket_namespace.py` is what makes this fail rather than be
remembered — `libtmux-ts` gates the same invariant the same way. It reads every
`Server(socketPath:)` given a literal, which is where a stray root gets written
down. It does not read `Server(socketName:)`: tmux resolves a name inside
`TMUX_TMPDIR`, so the literal says nothing about where the socket lands, and
`namedSocketsAvailable` is what gates that instead. Nor can it see whether a
server was *started* — nothing reaches the filesystem until a command runs
against it — so the couple of cases that name a path outside the roots and never
create one are listed in the script rather than detected.

`Server` has no default endpoint, so this is a convention about *callers* rather
than a setting: a socket path is chosen at every call site that creates one.

## Writing

For changes to documentation, user-facing text, `CHANGELOG.md`, release notes,
commit messages, DocC and doc comments, or source comments, follow
[`.github/WRITING.md`](.github/WRITING.md). It is the single home for the
comment gates, the commit message format, and the code block rules.

## Contributing

For building, running the tests, the checks that must pass, pull requests,
review, releases, and what this package is compatible with, follow
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md).
