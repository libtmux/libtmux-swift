# Contributing

How this repository is built, tested, reviewed, and released.

The package is the repository: `Package.swift` at the root, `Sources/` and
`Tests/` beside it, because SwiftPM resolves a package from a repository root
and cannot be pointed at a subdirectory. Five products ship from it —
`LibTmux`, `TmuxWorkspace`, `LibTmuxMCP`, the `libtmux-mcp` executable, and
`TmuxTestSupport` — and `Examples/`, `Benchmarks/`, and `dev/Spikes/` are
packages of their own, so the shipped manifest names only what ships.

How this project writes prose — README, changelog, release notes, commit
messages, API documentation, and source comments — is set out separately in
[`WRITING.md`](WRITING.md). Read that before changing any of it.

## Building

Swift is installed through mise, and a plain shell will not find it:

```console
$ export PATH="$(mise where swift)/usr/bin:$PATH"
```

`Scripts/update_mode_matrix.py` reads `$SWIFT` for the same reason.

That the default configuration builds is its own check, because the trait-on
test below covers a different graph:

```console
$ swift build
```

**On Darwin, build with Xcode's toolchain rather than one from swift.org.**
[swift-subprocess][] reaches `Span.bytes`, whose accessor back-deploys only
from Swift 6.3, so a 6.2 toolchain fails inside the dependency at any
deployment target below macOS 26 — and SwiftPM compiles a dependency at *that
dependency's* declared minimum, so no number in `Package.swift` reaches it.
Xcode 26 ships Swift 6.3, which is what the macOS lane and upstream's own CI
both use. On that lane every command is prefixed `xcrun`.

## Running the tests

The suite runs against real tmux — no mocks of the server — one private socket
per case, with servers reaped even when a run is killed outright.

The `YAMLWorkspaces` trait is off by default and six tests come with it, the
YAML reader and everything that exercises it. A bare `swift test` passes while
covering less, which is why the gate names the trait:

```console
$ swift test --traits YAMLWorkspaces
```

The named-socket cases resolve a socket *name*, which tmux looks up inside
`TMUX_TMPDIR` — whose default is shared with every other tmux on this machine,
the other ports' included. Name the directory and those cases run; without it
they skip and say why:

```console
$ TMUX_TMPDIR=/tmp/libtmux-swift-test/named swift test --traits YAMLWorkspaces
```

The fixture does not set that variable itself: `setenv` writes to `environ`
while other cases are concurrently reading it to build a tmux environment,
which is a data race whether or not it has bitten yet.

Point the suite at one tmux release with `LIBTMUX_TMUX_BIN`. Every test
resolves its binary through it, so this exercises the release named rather than
whichever one the machine ships:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.2a/bin/tmux swift test
```

The examples are their own package and are run separately:

```console
$ swift test --package-path Examples
```

**Run the trait-on command last.** A default-trait resolve drops the Yams pin
from `Package.resolved`, and SwiftPM will not put it back into a file that is
missing it. Committing that deletion is the mistake to avoid. `swift build` and
the DocC command are both default-trait resolves, so both do it; the examples
package has its own `Package.resolved` and leaves this one alone.

## Checks that must pass

Each of these gates CI, and each can fail. Build and test run on every cell of
the matrix; the tooling checks run once, on the Linux tmux 3.7b cell.

Formatting, against `.swift-format` at the root — four spaces, 100 columns:

```console
$ swift format lint --recursive --strict Sources Tests Examples Benchmarks Package.swift
```

The documentation. DocC warnings fail the job, so a broken symbol link is an
error rather than a note:

```console
$ swift package generate-documentation --target LibTmux
```

Python under `Scripts/` is held to the ruff configuration beside it, in
`Scripts/.ruff.toml`. CI pins the action version deliberately — 0.16.3 broke a
lane on an unrelated commit:

```console
$ ruff check Scripts/
```

Every documented example is compiled, and the floor keeps the number that
actually run from sliding:

```console
$ python3 Scripts/check_examples.py --min-executed 36
```

Every socket this repository names by literal lives under one of this port's
two roots — the invariant itself is in [`AGENTS.md`](../AGENTS.md):

```console
$ python3 Scripts/check_socket_namespace.py
```

That script reads every `Server(socketPath:)` given a literal, which is where a
stray root gets written down. It does not read `Server(socketName:)`: tmux
resolves a name inside `TMUX_TMPDIR`, so the literal says nothing about where
the socket lands, and `namedSocketsAvailable` is what gates that instead. Nor
can it see whether a server was *started* — nothing reaches the filesystem
until a command runs against it — so the few cases that name a path outside the
roots and never create one are listed in the script rather than detected.

Every tracked file with a shebang is executable in git, so a script that CI
invokes directly does not fail only there:

```console
$ python3 Scripts/check_script_modes.py
```

Every `exact:` pin in the documentation names the version the package claims:

```console
$ python3 Scripts/check_version.py
```

The generated tables still match what the benchmark measures:

```console
$ python3 Scripts/update_mode_matrix.py --check
```

The parity report runs, sorting Python libtmux's API into covered, declined,
and pending:

```console
$ python3 Scripts/parity_report.py
```

The Python tooling has its own suite:

```console
$ python3 -m pytest Scripts/tests -q
```

CI additionally checks the parity manifests against a real libtmux checkout,
cloned at the commit recorded in `Parity/python-public-api.json`. Reproducing
that locally needs the checkout; the check itself is
`Scripts/extract-python-parity.py --check --python-repo <path>`.

None of these catch a symbol that exists only on a newer macOS than the package
supports — `Package.swift` says 13, and a Linux compiler has no availability to
check against. The macOS lane is the only thing that fails, after a push.
Naming a generic's failure type (`AsyncSequence<T, Never>`) is the one that has
bitten: it needs macOS 15.

## Documented examples

Anything inside a `swift` fenced block in the top-level `README.md` or the DocC
catalogue must also appear in a file under `Examples/Sources/`. Add the example
there rather than writing it twice — `Scripts/check_examples.py` fails when a
fence appears in no example. Those two documents are the whole of what the
check scans: a `swift` fence added to a product README under `Sources/` is
compiled by nothing.

`Examples/` is a package of its own that depends on this one, so an example
reaches the library the way a reader does: through the products, with no
`@testable`. An example kept inside the suite can use internals a consumer
cannot and still pass, which is the thing that split is there to prevent.

Every example is a function, so a test in `Examples/Tests/` calling it by name
is what makes it *executed*. That is worth more than compiling: a renamed call
stops the build either way, but a call that kept its name and changed its answer
is only caught by running it. The check reports the split, so the number that
run is a fact rather than a claim, and `--min-executed` keeps it from sliding.

Edit the example, never the block on the page, then run the check:

```console
$ python3 Scripts/check_examples.py
```

[`Examples/README.md`](../Examples/README.md) is the reference for the rest —
how a fence is matched to an example, what the check cannot see, and the three
ways an example fails quietly. Read it before adding or moving one.

## Measured claims are generated

The mode matrix in `README.md` and `Modes.md` is written by the benchmark
through `Scripts/update_mode_matrix.py`:

```console
$ swift run --package-path Benchmarks libtmux-bench --markdown
```

Never edit the table between its markers. `update_mode_matrix.py --check` fails
when it has drifted, and CI runs that check, so a hand-typed number is caught
rather than believed.

`Scripts/parity_report.py` sorts Python libtmux's API into covered, declined,
and pending. Record a divergence in the table it belongs to rather than leaving
it to read as an omission, and keep the module-wide rules off format fields —
counting those as covered restates a curated subset as parity.

## Pull requests

One subject per pull request. Unrelated cleanup found along the way belongs in
its own commit, and usually in its own pull request.

The commit message format is in [`WRITING.md`](WRITING.md); the constraints on
what a change may touch are in [`AGENTS.md`](../AGENTS.md). Neither is restated
here.

## Review

What a reviewer is looking for, beyond whether it works:

- **Which gate would have caught this.** If none would, that is the finding —
  a check is worth more than the fix that prompted it.
- **Whether a new test was shown capable of failing.** A green test proves
  nothing until it has been made to go red on purpose.
- **Whether the public surface grew without a caller needing it.** Anything
  exported is something the alpha promise will eventually have to keep.
- **Whether a claim in prose is checkable.** A number in the README that no
  script regenerates is a number that will be wrong.

## Releases

The maintainer creates and pushes tags; nobody else does. Pushing the tag is
what publishes — SwiftPM resolves a package from its git history and nothing is
uploaded anywhere — and `.github/workflows/release.yml` turns that push into
the GitHub Release every established Swift package carries, marking it a
prerelease whenever the version has a suffix.

The release commit does two things, and the workflow refuses the tag if either
is missing:

- Set `LibTmuxVersion.current` to the version being tagged. Every `exact:` pin
  in the documentation names it, and `Scripts/check_version.py` fails when one
  does not.
- Rename `## [Unreleased]` in `CHANGELOG.md` to `## [<version>] - <date>` and
  open a fresh `## [Unreleased]` above it. Those lines become the release
  notes, so an empty section fails the release rather than publishing one.

Rehearse before tagging. This runs every check and stops before publishing, so
the release path is not being executed for the first time on the release:

```console
$ gh workflow run release --ref master -f dry_run=true
```

## Compatibility

| | |
| --- | --- |
| Swift | 6.2, language mode 6, strict concurrency, no unsafe flags |
| Platforms | Linux and macOS; `Package.swift` declares `macOS(.v13)` |
| tmux | 3.2a, 3.3a, 3.4, 3.5, 3.6, 3.7, 3.7a, 3.7b |

CI builds each of those tmux releases from its own release tarball and runs the
suite against it on Linux. macOS runs the ends of the range only — 3.2a and
3.7b — because what differs on Darwin is this package's own handling rather
than anything that varies by tmux release: the `TMPDIR` a socket path cannot
afford, keg-only libevent and ncurses, `F_SETNOSIGPIPE`, and a pty cap low
enough that the lane raises it before the suite.

The package is alpha. The public API can change in any release with no
deprecation first, so semantic versioning starts describing this package at
`0.1.0`; before that a version number says only which alpha you have. What is
tested is the tmux behaviour — the Swift surface around it is what has not
settled.

[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
