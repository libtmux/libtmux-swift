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
$ swift format lint --recursive --strict Sources Tests Examples Benchmarks Package.swift
```

```console
$ swift test --package-path Examples
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
missing it. Committing that deletion is the mistake to avoid. `swift build` and
the DocC command are both default-trait resolves, so both do it; the examples
package has its own `Package.resolved` and leaves this one alone.

```console
$ swift package generate-documentation --target LibTmux
```

DocC warnings fail the job, so a broken symbol link is an error rather than a
note.

```console
$ python3 Scripts/check_examples.py --min-executed 29
```

```console
$ python3 Scripts/check_socket_namespace.py
```

```console
$ python3 Scripts/check_script_modes.py
```

```console
$ python3 Scripts/update_mode_matrix.py --check
```

Python under `Scripts/` is held to the ruff configuration beside it, in
`Scripts/.ruff.toml`.

## Documented examples are compiled, and most are run

Anything inside a `swift` fenced block in `README.md` or the DocC catalogue must
also appear in a file under `Examples/Sources/`. Add the example there rather
than writing it twice — `Scripts/check_examples.py` fails when a fence appears
in no example.

`Examples/` is a package of its own that depends on this one, so an example
reaches the library the way a reader does: through the products, with no
`@testable`. An example kept inside the suite can use internals a consumer
cannot and still pass, which is the thing that split is there to prevent. Both
sibling ports settled on the same shape — `libtmux-go` keeps `examples/` as its
own module, `libtmux-ts` as a private workspace package.

Every example is a function, so a test in `Examples/Tests/` calling it by name
is what makes it *executed*. That is worth more than compiling: a renamed call
stops the build either way, but a call that kept its name and changed its answer
is only caught by running it. The check reports the split, so the number that
run is a fact rather than a claim, and `--min-executed` keeps it from sliding:

```console
$ swift test --package-path Examples
```

`SIGPIPE` and `TmuxContext.current()` are compiled and never run: the first is
a process-global disposition the runner has already chosen, the second is only
non-nil inside a pane. The quick start is top-level code, so no test can call
it — it is run instead, by spawning the executable it builds.

Two rules govern porting an example, and both fail quietly. A trait defines its
compilation condition only inside the package that declares it, so `#if
YAMLWorkspaces` in `Examples/` is always false and deletes the example rather
than guarding it — call the trait-gated API unguarded, because the dependency is
resolved with the trait on. And the `return` a test asserts on goes *after* the
documented block, never inside it, or it breaks the run of lines the fence is
matched by.

Those tests provision servers through the same fixture as everything else, which
keeps every socket under `/tmp/libtmux-swift-test/`. `withNamedTmuxServer` is the
socket-*name* half, and a name is resolved by tmux inside `TMUX_TMPDIR` — whose
default is shared with every other tmux on this machine, the other ports'
included. So the run names the directory and the suite reads it:

```console
$ TMUX_TMPDIR=/tmp/libtmux-swift-test/named swift test --traits YAMLWorkspaces
```

Without it those cases skip and say why. The fixture does not set the variable
itself: `setenv` writes to `environ` while other cases are concurrently reading
it to build a tmux environment, which is a data race whether or not it has
bitten yet.

## Measured claims are generated, not typed

The mode matrix in `README.md` and `Modes.md` is written by
`swift run --package-path Benchmarks libtmux-bench --markdown` through `Scripts/update_mode_matrix.py`.
Never edit the table between its markers.

`Scripts/parity_report.py` sorts Python libtmux's API into covered, declined,
and pending. Record a divergence in the table it belongs to rather than leaving
it to read as an omission, and keep the module-wide rules off format fields —
counting those as covered restates a curated subset as parity.

## Comments earn their maintenance cost

A comment ships only if it passes all three gates. Fail any: delete or rewrite.
Borderline: delete — borderline means the information is reconstructible, which
is what makes deletion cheap.

**Loss.** Three years from now, would losing this cost a maintainer real time
rediscovering intent, an invariant, a constraint, or a failure mode the code and
tests do not already make obvious?

**Elite.** Would SQLite, Redis, the Go standard library, or CPython write this
comment, at this length? Those projects state the constraint and stop. They do
not argue with an imagined objector.

**Upkeep.** Will it stay true without maintenance? A comment that hand-syncs a
value the code owns — a count, an offset, a line reference, a duplicated
constant — is false the first time that value moves.

### Ceiling

One or two lines. A comment reaching four is either carrying several facts, in
which case split it, or arguing, in which case cut it to the fact.

Rationale, alternatives weighed, and the story of how the code got here belong
in the commit message: timestamped, attached to the exact diff, and free to
maintain.

A comment often holds both a constraint and the deliberation that found it. Keep
the constraint, cut the deliberation. "Runs at most once per second" survives;
"this is the right trade for now" does not.

### Keep

- Why over how: upstream quirks, protocol and compatibility constraints,
  performance tradeoffs still part of the contract.
- Invariants, preconditions, ordering, lifetime, and concurrency requirements
  that types and tests cannot express.
- Code that looks wrong but is not, so a later cleanup does not reintroduce the
  bug.
- A high-level sketch of an algorithm whose local operations do not reveal the
  whole.

### Delete

- Narration of the next lines; code translated into English.
- Restated names, types, defaults, or control flow.
- Values duplicated from the code and hand-synced.
- Justification, hedging, or apology for a choice.
- Speculation about future requirements.
- History version control already holds, including commented-out code.
- Ticket and issue numbers. They say nothing to a reader without tracker access,
  and they rot when the tracker moves. Unfinished work goes in the tracker, not
  the source.
- Transient observations — "currently", "for now", "the latest release" —
  that go stale with no nearby edit.

### The upkeep gate in practice

It reaches values that track our own code. It does not reach frozen external
facts.

Bad (Delete):

```swift
// There are 321 tests to complete for servers.
```

Good (Keep):

```swift
// tmux < 3.2 reports the pane ID only after the command completes,
// so this query must stay separate.
```

### Documentation exception

Doctests, minimal usage examples, and param, return, and raises lines on public
API are exempt from the loss gate — they serve the caller, not the maintainer.
They are exempt from nothing else. Ceiling: a good man page entry.

DocC summaries and `- Parameter` and `- Returns` fields fall under this
exception.

## Git Commit Standards

Format commit messages as:
```
Scope(type[detail]): concise description

why: Explanation of necessity or impact.

what:
- Specific technical changes made
- Focused on a single topic
```

Keep the subject ≤50 chars (excluding any trailing `(#NN)` PR ref); wrap
body lines at ≤72 chars. Separate the `why:` and `what:` blocks with a
blank line.

Common commit types:
- **feat**: New features or enhancements
- **fix**: Bug fixes
- **refactor**: Code restructuring without functional change
- **docs**: Documentation updates
- **chore**: Maintenance (dependencies, tooling, config)
- **test**: Test-related updates
- **style**: Code style and formatting
- **swift(deps)**: Dependencies
- **swift(deps[dev])**: Dev Dependencies
- **ai(rules[AGENTS])**: AI rule updates

Example:
```
Pane(feat[sendKeys]): Add support for a literal flag

why: Send characters without tmux interpreting them.

what:
- Add a literal parameter to sendKeys(_:)
- Pass -l when it is set
```

### Release commits

Never create tags. Never push tags. The user handles tagging and tag
pushes (tags trigger the CI publish workflow).

Release commit subjects are plain and short: `Tag v<version>`. Put
the detailed why/what in the commit body. Don't use the
`Scope(type[detail]):` format for releases — don't bury the lede.

For multi-line commits, use heredoc to preserve formatting:
```bash
git commit -m "$(cat <<'EOF'
Scope(feat[detail]): Concise description

why: Explanation of the change.

what:
- First change
- Second change
EOF
)"
```

## Code Blocks

Code blocks are paste-and-run units: pasting one block runs exactly one
intended action. Doctests and other executed examples are exempt — the test
suite runs them, nobody pastes them.

- **One command per block.** Multiple steps may share a block only when
  explicitly chained with `&&`, `;`, or `\` continuations — the chain is
  then one logical command.
- **Explanations go in prose above the block**, never as `#` comments inside it.
- **Command menus are per-command blocks with prose lead-ins**, not tables.
- **Shell commands use the `console` tag with a `$ ` prefix.** This separates
  interactive commands from scripts and enables prompt-aware copy.
- **Split long commands with `\`** — one flag or flag+value pair per indented
  continuation line, positional arguments last.

Good:

Show the last ten commits as a graph:

```console
$ git log \
    --max-count=10 \
    --graph \
    --oneline
```

Bad:

```console
# Show the last ten commits as a graph
$ git log --max-count=10 --graph --oneline
```
