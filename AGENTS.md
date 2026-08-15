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

`Server` has no default endpoint, so this is a convention about *callers* rather
than a setting: a socket path is chosen at every call site that creates one.

## The toolchain is not on `PATH`

Swift is installed through mise, and a plain shell will not find it:

```console
$ export PATH="$(mise where swift)/usr/bin:$PATH"
```

`Scripts/update_mode_matrix.py` reads `$SWIFT` for the same reason.

Point the suite at one tmux release with `LIBTMUX_TMUX_BIN`. Every test resolves
its binary through it, so this exercises the release named rather than whichever
one the machine ships:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.2a/bin/tmux swift test
```

## What has to pass before a commit

Each of these gates CI, and each can fail:

```console
$ swift format lint --recursive --strict Sources Tests Snippets Benchmarks Package.swift
```

```console
$ swift test --traits YAMLWorkspaces
```

The trait is off by default, and six tests come with it — the YAML reader and
everything that exercises it. A bare `swift test` passes while covering less,
which is why the gate names the trait. That the default configuration still
builds is its own check:

```console
$ swift build
```

Run the trait-on command last: a default-trait resolve drops the Yams pin from
`Package.resolved`, and SwiftPM will not put it back into a file that is
missing it. Committing that deletion is the mistake to avoid.

```console
$ swift package generate-documentation --target LibTmux
```

DocC warnings fail the job, so a broken symbol link is an error rather than a
note.

```console
$ python3 Scripts/check_examples.py
```

```console
$ python3 Scripts/update_mode_matrix.py --check
```

Python under `Scripts/` is held to the ruff configuration beside it, in
`Scripts/.ruff.toml`.

## Documented examples are compiled

Anything inside a `swift` fenced block in `README.md` or the DocC catalogue must
also appear in a file under `Snippets/`, which the build compiles. Add the
example to a snippet rather than writing it twice — `Scripts/check_examples.py`
fails when a fence appears in no snippet.

## Measured claims are generated, not typed

The mode matrix in `README.md` and `Modes.md` is written by
`swift run --package-path Benchmarks libtmux-bench --markdown` through `Scripts/update_mode_matrix.py`.
Never edit the table between its markers.

`Scripts/parity_report.py` sorts Python libtmux's API into covered, declined,
and pending. Record a divergence in the table it belongs to rather than leaving
it to read as an omission, and keep the module-wide rules off format fields —
counting those as covered restates a curated subset as parity.
