# AGENTS.md

Rules for working in this repository: `libtmux` for Swift, a port of
[libtmux](https://github.com/tmux-python/libtmux) for Python, which stays the
reference for what tmux behaviour is worth having. A convention you recognise
from that project — pytest, mypy, doctests, NumPy docstrings — does not apply
here unless a file named below says so.

The package is the repository — `Package.swift` at the root, `Sources/` and
`Tests/` beside it — because SwiftPM resolves a package from a repository root
and cannot be pointed at a subdirectory.

## Change discipline

- Make the smallest coherent change that solves the verified problem, and keep
  unrelated cleanup out of it.
- Reuse an existing type, helper, fixture, or test before adding a new one.
- Keep new API internal until a caller outside the module needs it. Anything
  exported is something the alpha promise will eventually have to keep.
- Add a file only for a durable boundary — a distinct responsibility, or
  independent reuse — not for a single-use helper.
- A passing gate is evidence only once it has been shown capable of failing.
  Pair a new test with a deliberate break that proves it bites.

## Every socket names this port

Several ports of libtmux are developed side by side on one machine, and `/tmp`
is shared between all of them. A socket named `libtmux-…` says nothing about
which port left it, so two suites running at once can find each other's
servers, and anything sweeping up by prefix can kill a server it never started.
Debugging that looks like a flaky test in whichever port noticed first.

So every tmux socket this package creates lives under a language-scoped root:

| Root | Who uses it |
| --- | --- |
| `/tmp/libtmux-swift-test/` | the test suite, one directory per case |
| `/tmp/libtmux-swift-dev/` | the benchmark, and anything run by hand |

Two rules follow, and they bind every change rather than only the ones that
touch the suite:

- Never create a socket outside those roots — including in a throwaway shell
  command while investigating something. A probe socket is the easiest way to
  leave a server another port then trips over.
- Never remove anything under `/tmp/libtmux-*` that is not one of these two
  roots. Those belong to other ports, and a running server may be behind them.

`Server` has no default endpoint, so this is a convention about *callers*
rather than a setting: a socket path is chosen at every call site that creates
one. `Scripts/check_socket_namespace.py` is what makes it fail rather than be
remembered — `libtmux-ts` gates the same invariant the same way — and
[`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md) covers what that gate can
and cannot see.

## Which policy applies

- Documentation, user-facing text, `CHANGELOG.md`, release notes, commit
  messages, DocC, doc comments, and source comments:
  [`.github/WRITING.md`](.github/WRITING.md)
- Building, running the tests, the checks that must pass, pull requests,
  review, releases, and compatibility:
  [`.github/CONTRIBUTING.md`](.github/CONTRIBUTING.md)
- Reporting or assessing a vulnerability:
  [`.github/SECURITY.md`](.github/SECURITY.md)

Each of those is the single home for its subject. Where a rule seems to be
stated twice, the file listed above is the one that governs.
