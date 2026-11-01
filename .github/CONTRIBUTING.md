# Contributing

How this repository is built, tested, reviewed, and released.

The package is the repository: `Package.swift` at the root, `Sources/` and
`Tests/` beside it, because SwiftPM resolves a package from a repository root
and cannot be pointed at a subdirectory. Six products ship from it —
`LibTmux`, `TmuxWorkspace`, `LibTmuxMCP`, the `libtmux-mcp` and
`tmux-workspace` executables, and
`TmuxFixture` — and `Examples/`, `Benchmarks/`, and `dev/Spikes/` are
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

SwiftPM compiles with one job per core, and the suite starts a tmux server per
case on top of that, so a full run makes the machine it is running on unusable
for anything else. Half the cores leaves it responsive and costs little, because
these builds are not compile-bound:

```console
$ swift build --jobs 5 --force-resolved-versions
```

Hosted CI gets a runner to itself and should keep the default; this is for a
machine someone is also working on. Serial tests are worth pairing with it —
they keep a loaded machine from being the reason a timing case fails — and one
lock file keeps two runs from overlapping. `Scripts/swift-test` stands where
`swift test` does, and the next section says why:

```console
$ nice -n 10 flock /tmp/libtmux-swift-test/.swift.lock \
    Scripts/swift-test --jobs 5 --no-parallel --force-resolved-versions
```

That the default configuration builds is its own check, because the trait-on
test below covers a different graph:

```console
$ swift build --force-resolved-versions
```

**On Darwin, build with Xcode's toolchain rather than one from swift.org.**
[swift-subprocess][] reaches `Span.bytes`, whose accessor back-deploys only
from Swift 6.3, so a 6.2 toolchain fails inside the dependency at any
deployment target below macOS 26 — and SwiftPM compiles a dependency at *that
dependency's* declared minimum, so no number in `Package.swift` reaches it.
Xcode 26 ships Swift 6.3, which is what upstream's own CI uses. With that
toolchain every command is prefixed `xcrun`.

## Running the tests

The suite runs against real tmux — no mocks of the server — one private socket
per case, with servers reaped even when a run is killed outright.

Start it with `Scripts/swift-test`, which takes the same arguments as
`swift test`. tmux follows an inherited `TMUX` to the server its caller is
inside, ahead of `TMUX_TMPDIR`, and `TMUX_PANE` and the `LIBTMUX_SOCKET*`
variables pick a pane and a socket for the executables. A suite started from a
tmux pane would reach that server as soon as one case named no socket, so the
script removes them and gives the run a fresh owner-only `TMUX_TMPDIR` under
`/tmp/libtmux-swift-test/`, removed when the run ends. It marks the run in
`LIBTMUX_TEST_SANDBOX`, which the fixtures check: a test run of this package
started any other way is refused by the first fixture it reaches, and fails
`SandboxTests`, both naming the script. A package that depends on `TmuxFixture`
is held to the sandbox only when its run carries the marker.

Before it removes its directory the script looks for sockets anywhere under it,
whoever named them, and stops any server still listening on one, since removing
the socket of a live server leaves one nothing can address. It checks for up to
three seconds that each stopped server no longer accepts a connection, and fails
the run naming those sockets even when the tests passed. A socket file nothing
listens on is not a leak. A case that starts a server, on tmux's default socket
or one it names with `-S`, stops it and waits for it to go. If a server cannot
be stopped the directory stays. Checking takes `python3`.

The `YAMLWorkspaces` trait is off by default; the YAML reader and the tests
that exercise it come with it. A bare
`Scripts/swift-test --force-resolved-versions` passes while covering less,
which is why the gate names the trait:

```console
$ Scripts/swift-test --traits YAMLWorkspaces --force-resolved-versions
```

The named-socket cases resolve a socket *name*, which tmux looks up inside
`TMUX_TMPDIR` — whose default is shared with every other tmux on this machine,
the other ports' included. The script's directory is under the test root, so
those cases run. To put the run's directory under a parent of your own, name
an absolute path in `LIBTMUX_TEST_TMUX_TMPDIR`; the script makes its owner-only
directory inside it and removes that directory afterwards. It refuses a parent
that is a link, is not empty, holds a `tmux-<uid>` directory, or is so long that
the default socket under it would pass 100 bytes, and it never changes the mode
of one that exists, so it cannot be pointed at a directory some tmux is using.
The named-socket cases skip and say why unless the directory is under the test
root.

The fixture does not set `TMUX_TMPDIR` itself: `setenv` writes to `environ`
while other cases are concurrently reading it to build a tmux environment,
which is a data race whether or not it has bitten yet. A child process a case
starts takes `sandboxedEnvironment()` instead of the process environment, so it
holds none of those variables either way.

Point the suite at one tmux release with `LIBTMUX_TMUX_BIN`. Every test
resolves its binary through it, so this exercises the release named rather than
whichever one the machine ships:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.3a/bin/tmux \
    Scripts/swift-test \
    --force-resolved-versions
```

The examples are their own package and are run separately:

```console
$ Scripts/swift-test --package-path Examples --force-resolved-versions
```

`Tools/McpSwap` starts no tmux, so its suite runs as plain `swift test`.
`dev/Spikes` does start tmux, through its own fixture and
`dev/Spikes/Scripts/test-spikes.sh`; neither the script nor the canary covers
it.

CI also copies `tmux-workspace` outside `.build` and runs its terminal checks
on every platform and tmux version. Run these after the trait-on test build;
they create and clean up private sockets under `/tmp/libtmux-swift-dev/`:

```console
$ python3 Scripts/check_workspace_terminal.py .build/debug/tmux-workspace
```

```console
$ python3 Scripts/check_workspace_progress.py \
    .build/debug/tmux-workspace "$LIBTMUX_TMUX_BIN"
```

```console
$ python3 Scripts/check_workspace_attach.py \
    .build/debug/tmux-workspace "$LIBTMUX_TMUX_BIN"
```

`Package.resolved` tracks a superset that includes Yams even when the trait is
off. Root commands use `--force-resolved-versions` to take the pinned revisions
for the dependencies they resolve and leave the unused Yams pin intact.
Downstream packages that use the libraries resolve independently. The examples
package enforces its own `Package.resolved` and leaves the root file alone.

## Running the programs by hand

`tmux-workspace`, `libtmux-mcp` and a program that builds `Server()` pass tmux
no socket unless `LIBTMUX_SOCKET_PATH` or `LIBTMUX_SOCKET` names one, so tmux
picks the server: the one you are inside, and your default socket otherwise. Run
from your shell, they drive your own tmux. To keep a direct invocation away from
it, give development a socket of its own in a `.env`. `.gitignore` keeps that
file out of the tree and no target packages it:

```console
$ mkdir -p /tmp/libtmux-swift-dev
$ printf 'LIBTMUX_SOCKET_PATH=/tmp/libtmux-swift-dev/dev.sock\n' > .env
```

Nothing here starts a server for a variable that names a socket nobody listens
on, so start one before the first command, and stop it when you are done:

```console
$ set -a && . ./.env && set +a
$ tmux -S "$LIBTMUX_SOCKET_PATH" -f /dev/null new-session -d -s dev
$ .build/debug/tmux-workspace freeze dev --json
$ tmux -S "$LIBTMUX_SOCKET_PATH" kill-server
```

The test suite does not read `.env`: `Scripts/swift-test` removes the variables
before anything runs.

## Flaky, or broken?

The suite drives real tmux, and the cases that wait on an event can be delayed
by a loaded machine. One failure is worth re-running before it is blamed on the
change, and worth investigating rather than shrugged at.

Three signs it is the machine and not the code: the failing case moves between
runs or between matrix cells, the failure is the suite's time limit rather than
a wrong value, and the commit touched nothing the case reads. Re-running the one
case in a loop is cheaper than another round of CI:

```console
$ for _ in $(seq 20); do Scripts/swift-test --force-resolved-versions --filter observersDoNotDivideNotifications || break; done
```

Every suite carries `.timeLimit(.minutes(5))`, and that number is a backstop
rather than a stopwatch. The suite runs its cases in parallel, one tmux server
each, so what a case reports is mostly time spent waiting for a core: on a
loaded runner, the slowest cases all took nearly as long as the whole run. A
one-minute limit against that is not a limit on the case, it is a limit on how
loaded the runner may be, and it went red on a lane that had nothing wrong
with it. Five minutes still catches a
hang long before the job's own thirty.

Raise it here rather than per suite. A limit that differs between suites
invites reading it as a performance claim about the code underneath, which is
the thing these numbers cannot support.

All three can hold and it can still be a defect. A run where every cell from
tmux 3.6 up failed and every earlier one passed read as load, and was a client
whose protocol version differed from the server's: the example composed
`tmux wait-for -S` as a bare command, so the pane reached whichever tmux was on
its `PATH` rather than the one serving it. `Server.shellInvocation` is what
fixed it. A wait that hangs looks the same whether nothing signalled it or the
thing meant to signal it never ran.

A case that waits therefore establishes what it is waiting on before producing
it. Task start is not an ordering: an `async let` evaluates its initializer in
the child task, which on a loaded runner is late enough to miss the event the
child was written to catch.

## Running CI against any tmux

A push and a pull request run the oldest and newest released tmux in
[the table](#compatibility). Any other tmux runs on demand: dispatch `ci.yml`
from any branch with `scope=custom` and a comma-separated `tmux-ref`, each item
a release, a tag, a branch or a 40-hex commit from
[github.com/tmux/tmux](https://github.com/tmux/tmux).

```console
$ gh workflow run ci.yml --ref my-branch -f scope=custom -f tmux-ref=3.6b,master
```

A release in the table keeps its tarball. Anything else is resolved to a commit
and built from it, and `master` here is the current tip, not the pinned commit
the full table tests. `swift` repeats each tmux ref once per toolchain.
`scope=full` runs the whole table, the pinned master and the refusal cells, as a
tag does.

```console
$ gh workflow run ci.yml --ref my-branch -f scope=custom -f tmux-ref=3.8 -f swift=6.1,6.2
```

`tmate=on-failure` opens an
[`action-tmate`](https://github.com/mxschmitt/action-tmate) SSH session after a
failing leg, and `tmate=before-tests` opens one before the build and tests. Only
the account that dispatched the run can connect, so it needs a public SSH key on
its GitHub profile. The plan accepts a session on exactly one leg, which means
one `tmux-ref` and at most one `swift`. The build is in `~/tmux-<ref>`, shortened to 12
characters for a commit, and `LIBTMUX_TMUX_BIN` points the suite at its
`bin/tmux`.

```console
$ gh workflow run ci.yml --ref my-branch -f scope=custom -f tmux-ref=3.7b -f tmate=on-failure
```

The dispatch form is only available once `ci.yml` carries the inputs on the
default branch. This prints the legs a dispatch would run, without a runner:

```console
$ python3 Scripts/ci_plan.py matrix --event workflow_dispatch --scope custom --tmux-ref 3.6b,master
```

The tmux versions CI runs come from one manifest, `Scripts/tmux-matrix.json`.
Adding a release there is the whole change to CI, and `Scripts/check_ci.py`
names each page that has to say so. Each dispatch is its own run: it does not
cancel the push run on its branch, and another dispatch does not cancel it.

## Checks that must pass

Each of these gates CI, and each can fail. Build and test run on every cell of
the matrix; the tooling checks run once, on the cell with the newest released
tmux. The two that run a tmux binary, the parity manifests and the mode matrix,
run on tmux 3.7b, which a tag and a full-scope dispatch include and a push does
not.

CI runs Linux only. macOS is supported on a best-effort basis, and CI coverage
for it is highly limited: no job builds or tests there, so a macOS-only
regression is not caught before merge. Run the suite on a Mac when a change
touches Darwin handling.

Formatting, against `.swift-format` at the root — four spaces, 100 columns:

```console
$ swift format lint --recursive --strict \
    Sources Tests Examples Benchmarks \
    Tools/McpSwap/Sources/McpSwapCore Tools/McpSwap/Sources/McpSwap \
    Tools/McpSwap/Tests Package.swift Tools/McpSwap/Package.swift
```

The private native MCP swap utility is a nested package, so the root build does
not compile or archive it. Run its own locked test suite after changing it:

```console
$ swift test \
    --package-path Tools/McpSwap \
    --jobs 5 \
    --force-resolved-versions
```

Its C portability shim has a package-local format policy:

```console
$ clang-format --dry-run --Werror \
    Tools/McpSwap/Sources/CMcpSwap/mcp_swap.c \
    Tools/McpSwap/Sources/CMcpSwap/include/mcp_swap.h
```

Its usage, recovery model, and runnable examples live in
[`Tools/McpSwap/README.md`](../Tools/McpSwap/README.md).

The documentation. DocC warnings fail the job, so a broken symbol link is an
error rather than a note:

```console
$ swift package \
    --force-resolved-versions \
    generate-documentation \
    --target LibTmux
```

```console
$ swift package \
    --force-resolved-versions \
    generate-documentation \
    --target TmuxWorkspace
```

```console
$ swift package \
    --force-resolved-versions \
    generate-documentation \
    --target LibTmuxMCP
```

Python under `Scripts/` is held to the ruff configuration beside it, in
`Scripts/.ruff.toml`. CI pins the action version deliberately — 0.16.3 broke a
lane on an unrelated commit:

```console
$ ruff check Scripts/
```

Every documented example maps to consumer source, and the floor keeps its
live-test call sites from sliding. The trait-on test later compiles and runs
that package:

```console
$ python3 Scripts/check_examples.py --min-executed 40
```

Every link in a README or under `docs/` that points into this repository or at
a libtmux.org API page names something that exists, and no prose block in a
product README runs past 240 characters. The check reads the tree rather than
the network, so it passes before the documentation publishes:

```console
$ python3 Scripts/check_readme_links.py
```

Every socket this repository names by literal lives under one of this port's
two roots — the invariant itself is in [`AGENTS.md`](../AGENTS.md):

```console
$ python3 Scripts/check_socket_namespace.py
```

That script reads literal `Server(socketPath:)` and `Server(socketName:)` calls.
A path records its root; a name must identify this port, while
`namedSocketsAvailable` separately proves the suite placed it under the test
root. It also fails a `Server` constructed with no socket, a
`TmuxContext.current()` with no environment, and a `makeServer()` outside
`Sources/`: each follows `TMUX` or tmux's default socket, so a test that calls
one drives the server its developer is inside. The script cannot see whether a
server was *started* — nothing reaches the filesystem until a command runs
against it — so deliberate exceptions are listed beside their reason.

Every continuation the library suspends can be resumed by cancelling it:

```console
$ python3 Scripts/check_continuations.py
```

A continuation nobody resumes is not a slow call, it is one that never returns,
and the usual ways of bounding a wait cannot end it — `.timeLimit` cancels a
case and then waits for it, so a parked continuation turns a slow test into a
run that cannot finish. One lane spent six hours there. The script requires
`withTaskCancellationHandler` to open just above the continuation; where the
*caller* releases the park instead, which is legitimate,
`Sources/LibTmuxMCP/OrderedOutbound.swift` being the example, the exception is
listed beside the code that resumes it.

`Package.resolved` still carries the Yams pin that makes it a superset:

```console
$ jq -e '.pins[] | select(.identity == "yams")' Package.resolved > /dev/null
```

`swift test` with no traits resolves without Yams and rewrites the file to drop
that pin. Every command above passes `--force-resolved-versions` so it does
not, but the trait-off one is easy to reach for, and the drift is invisible in
review — a lock file with one fewer entry. Checking the committed file is what
catches it, because a later run that already has the pin never restores it.

CI runs `git diff --exit-code Package.resolved Examples/Package.resolved`
beside that, which answers a different question: whether a step in the job
rewrote a lock rather than reading it.

Every tracked file with a shebang is executable in git, so a script that CI
invokes directly does not fail only there:

```console
$ python3 Scripts/check_script_modes.py
```

Every `exact:` pin in the documentation names the version the package claims,
and every `from:` bound names a final release no newer than it:

```console
$ python3 Scripts/check_version.py
```

Every symbol `CHANGELOG.md` names on a type this package declares still exists
on it:

```console
$ python3 Scripts/check_changelog_symbols.py
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
check against, and CI does not build on macOS. Review for it by hand.
Naming a generic's failure type (`AsyncSequence<T, Never>`) is the one that has
bitten: it needs macOS 15.

## Documented examples

Anything inside a `swift` fenced block in the top-level `README.md`, a product
README under `Sources/`, or the DocC catalogue must also appear in a file under
`Examples/Sources/`. Add the example there rather than writing it twice —
`Scripts/check_examples.py` fails when a fence appears in no example.

`Examples/` is a package of its own that depends on this one, so an example
reaches the library the way a reader does: through the products, with no
`@testable`. An example kept inside the suite can use internals a consumer
cannot and still pass, which is the thing that split is there to prevent.

Every example is a function, so a test in `Examples/Tests/` calling it by name
marks it for the live suite. That is worth more than compiling: a renamed call
stops the build either way, but a call that kept its name and changed its answer
is only caught by running it. The check reports those call sites and
`--min-executed` keeps the count from sliding; the Examples test run proves the
code actually executes.

Edit the example, never the block on the page, then run the check:

```console
$ python3 Scripts/check_examples.py
```

Console commands in the Markdown are held to the code the same way. The suite
parses every `$ tmux-workspace ...` command against the executable's command
tree (`DocumentedCommandsTests`), and passes every MCP client configuration —
the JSON `env` blocks and the `-e` settings of `claude mcp add` — through
`ServerConfiguration`, the parse `libtmux-mcp` runs at startup
(`ReadmeDocumentationTests`). The same file holds each tool name in the
Markdown to its libtmux.org page.

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

`Scripts/benchmark_workspace_cli.py` compares an installed release
`tmux-workspace` against tmuxp on startup, discovery, cold-server load and
YAML capture. Like the mode matrix's own numbers, a live timing run is not
part of the CI gate; the full invocation is in
[`Sources/TmuxWorkspaceCLI/README.md`](../Sources/TmuxWorkspaceCLI/README.md).

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
  exported is something the release policy will eventually have to keep.
- **Whether a claim in prose is checkable.** A number in the README that no
  script regenerates is a number that will be wrong.

## Releases

The maintainer creates and pushes tags; nobody else does. Pushing the tag is
what publishes — SwiftPM resolves a package from its git history and nothing is
uploaded anywhere — and `.github/workflows/release.yml` turns that push into
the GitHub Release every established Swift package carries, marking it a
prerelease whenever the version has a suffix. No release has one unless the
maintainer asks for it. Increment `N` in `0.1.N` for each release.

The release commit does two things, and the workflow refuses the tag if either
is missing:

- Set `LibTmuxVersion.current` to the version being tagged. Every `exact:` pin
  in the documentation names it, and every `from:` bound is a final release no
  newer than it. `Scripts/check_version.py` fails when one is not.
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
| tmux | 3.3a, 3.4, 3.5, 3.6, 3.7, 3.7a, 3.7b, 3.8, master |

A push or pull request builds the oldest and newest of those, 3.3a and 3.8, from
their release tarballs and runs the suite against each on Linux. A tag, and a
dispatch with `scope=full`, do the same for every one of them, with master as a
pinned commit. macOS is supported on a best-effort basis and has no
CI lane. What differs on Darwin is this package's own handling rather than
anything that varies by tmux release: the `TMPDIR` a socket path cannot afford,
keg-only libevent and ncurses, `F_SETNOSIGPIPE`, and a pty cap low enough that
a parallel run needs it raised first.

3.3a is the floor, and the daemon's release decides:
every command is refused before it has an effect when the daemon it would reach
is older, whatever the client executable reports. 3.0a, 3.1c, 3.2a and the
unpatched 3.3 are built too, as refusal lanes that only a tag and a full-scope
dispatch run: they run only the version check suites, which assert the refusal and that nothing it refused happened. 3.0a and
3.1c keep the client's stdout open from the daemon, so their lanes run behind a
3.3a client named in `LIBTMUX_TMUX_CLIENT_BIN`; the test job sets the same
variable to a second tmux, so a client that reports another release than its
daemon is exercised too. A feature that needs a newer release says so where it
is described and refuses by itself; none of them raises this floor.

Releases are numbered `0.1.N`, and each release increments `N`. The API is not
settled: any release may change or remove exported identifiers, and the
changelog marks each break. Pin an exact version to avoid one. What is
tested is the tmux behaviour — the Swift surface around it is what has not
settled.

[swift-subprocess]: https://github.com/swiftlang/swift-subprocess
