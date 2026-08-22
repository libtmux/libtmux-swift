# Writing

How this repository writes prose, for humans and agents alike. It governs
`README.md` and the product READMEs under `Sources/`, `CHANGELOG.md`, release
notes, commit messages, the DocC catalogue, doc comments, source comments, and
anything the MCP server or an error says to a person.

For building, testing, the gates, pull requests, and releases, see
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Voice

State facts rather than praise them. A reader who opened the page needs an
answer, not persuasion, and specificity is the personality — "one dependency"
and "eight tmux releases on every push" say more than "lightweight" and
"well-tested" ever will.

Every claim should be something a compiler, a script, or CI can contradict.
That is what the gates are for: the examples compile, the version pins are
checked against the version, and the benchmark writes its own table. Write
claims that could fail, then let them be checked.

- **Lead with the thing described, and stop.** The most useful editing
  operation is deleting the introductory sentence.
- **Present tense, active voice.** "Building refuses a session that already has
  the name", not "a session that already has the name will be refused".
- **Contractions are fine.** This is technical English, not enterprise prose.
- **Assume competence.** Explain the unusual decision, not the obvious syntax.
- **Name constraints, and name non-goals.** "This talks to tmux; it does not
  draw one" answers a question that would otherwise arrive as an issue.
- **Prefer the concrete noun to the pronoun.** "`Resolver` passes the
  `Configuration` to `PackageLoader`" beats "this then uses it to configure the
  former" — for a reader, and for anything retrieving a fragment out of order.

| Instead of | Prefer |
| --- | --- |
| "powerful", "robust", "elegant" | name the capability, or the failure handled |
| "seamless", "effortless" | say what the caller does not have to do |
| "simply", "just", "easily" | omit |
| "blazing-fast", "optimized" | give the magnitude, or omit |
| "production-ready" | state the guarantee |
| "comprehensive" | name what is covered |
| "leverage", "utilize" | "use" |
| "in order to" | "to" |
| "please note that" | state the fact |
| "under the hood" | omit unless it is observable |
| "various fixes" | name the components |
| "we added…" | "`Server` now…" |

## README

The README is a technical product sheet, not a landing page. It answers, in
this order: what is this, can I use it, show me, what are the constraints,
where do I go deeper.

- **The first paragraph says what the package provides and for whom.** No
  adjectives that a reader would have to take on trust.
- **A compiling example above the fold.** Swift readers judge an API surface in
  ten seconds — argument labels, `async`/`await`, value semantics, `Sendable`
  posture. That block is the real description.
- **Two badges.** They report CI state, which is a fact. A wall of shields is
  decoration.
- **The alpha warning states the same terms every port states**: releases carry
  an `-alpha` prerelease tag, the API is not settled, any release may change or
  remove exported identifiers without a deprecation period, pin an exact
  version, not recommended for production.
- **Compatibility is first-class content**, not a footnote: the toolchain
  floor, the platforms, the tmux range, and what the stability promise covers.
- **Non-goals get their own sentences.** They answer the architectural question
  behind the issues nobody has filed yet.
- **Stable, literal headings.** "Install", "Requirements", "Tests" retrieve;
  "Getting going" and "A few knobs" do not.

Two rules are enforced rather than trusted:

- Every `swift` fence in `README.md` or the DocC catalogue must also exist as a
  file under `Examples/Sources/`. `Scripts/check_examples.py` fails otherwise,
  so a documented example is compiled code and most of it is run.
- Every `exact:` pin must name the version in `LibTmuxVersion.current`.
  `Scripts/check_version.py` fails otherwise.

Quoting a command's output in the README makes that output a claim. Run the
command and paste what it printed; do not remember it.

## Changelog

`CHANGELOG.md` is the ledger and it follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/): `### Added`,
`### Changed`, `### Fixed`, `### Deprecated`, `### Removed`, `### Security`,
under a `## [<version>] - <date>` heading with an ISO date and a bare semver.
New entries land under `## [Unreleased]`; the release commit is what assigns
them a version.

Write for someone deciding whether to upgrade:

- **Lead with the identifier and a concrete verb.** Name symbols literally —
  `Server.waitForOutput(in:matching:)`, not "the new waiting API".
- **State the consequence, not the commit subject.** "Refactors subprocess
  handling" tells a consumer nothing. What they notice, and what they have to
  do about it, is the entry.
- **State a changed default explicitly, and an incompatibility more explicitly
  still, with the way forward in the same bullet.** A reader hitting a compile
  error should find the fix in the line that predicted it.
- **As long as the change needs, and no longer.** A subtle fix earns its
  paragraph; a new overload does not.
- **Do not sell a fix, and do not describe effort.** No "major improvements",
  no "extensive rework".

Leave out what a consumer cannot observe: CI bumps, formatting, test
reorganisation, internal refactors, and documentation-only changes — unless
they move a supported platform, the toolchain floor, or the published surface.

## Release notes

The changelog is the ledger; the GitHub release page is the briefing. It opens
with one hand-written paragraph answering "should I take this upgrade", names
the toolchain floor if it moved, and puts migration instructions ahead of the
exhaustive list. Nobody should read forty bullets to discover the compile error
they are about to get.

`.github/workflows/release.yml` lifts the notes out of `CHANGELOG.md` — the
section for the version being tagged becomes the release body, and an empty one
fails the release rather than publishing it. So the notes are written before
the tag, in the changelog, in the voice above.

## Commit messages

```
Scope(type[detail]): concise description

why: Explanation of necessity or impact.

what:
- Specific technical changes made
- Focused on a single topic
```

Keep the subject to 50 characters or fewer, excluding any trailing `(#NN)` pull
request reference, and wrap body lines at 72. Separate the `why:` and `what:`
blocks with a blank line.

The `why:` block is where rationale lives — the alternative weighed, the
tradeoff taken, the cost of leaving it alone. It is timestamped, attached to
the exact diff, and free to maintain, which is why the source comment above the
code does not have to carry it. State a cost before listing changes: what was
being paid for, and by whom.

Common types:

- **feat**: new features or enhancements
- **fix**: bug fixes
- **refactor**: restructuring without functional change
- **docs**: documentation updates
- **chore**: maintenance — dependencies, tooling, config
- **test**: test-related updates
- **style**: code style and formatting
- **swift(deps)**: dependencies
- **swift(deps[dev])**: dev dependencies
- **ai(rules[AGENTS])**: agent rule updates

Example:

```
Pane(feat[sendKeys]): Add support for a literal flag

why: Send characters without tmux interpreting them.

what:
- Add a literal parameter to sendKeys(_:)
- Pass -l when it is set
```

For multi-line messages, use a heredoc so the formatting survives the shell:

```console
$ git commit -m "$(cat <<'EOF'
Scope(feat[detail]): Concise description

why: Explanation of the change.

what:
- First change
- Second change
EOF
)"
```

### Release commits

Never create tags. Never push tags. The maintainer handles tagging and tag
pushes, because pushing a tag is what publishes.

Release commit subjects are plain and short: `Tag <version>`. The detailed
why and what go in the body. Do not use the `Scope(type[detail]):` format for a
release — it buries the lede.

A version is bare semver with no `v`, because that is what every established
Swift package tags: swift-nio, swift-log, swift-collections,
swift-argument-parser, Alamofire, Yams and swift-subprocess all resolve from
`1.2.3` rather than `v1.2.3`.

What a release commit must do, and what `release.yml` refuses the tag without,
is in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## API documentation

Doc comments are `///`, and they are the reference: DocC compiles them, Xcode
quick help renders them, the Swift Package Index hosts them, and an agent reads
the same source. One artifact, four consumers.

Begin with a summary that stands alone — a sentence fragment ending in a
period. A third-person verb for a method, a noun phrase for a property:

```swift
/// Sends keys to the pane.
/// The number of clients attached to this server.
```

One line, a period, a blank line, then the discussion. Use `- Parameters:`,
`- Returns:`, and `- Throws:` only where they say something the signature does
not. A parameter named `pane` of type `Pane` does not need a line explaining
that it is the pane.

Document what the type system cannot express, which for this package usually
means: ownership and lifetime, whether a call blocks, cancellation semantics,
actor isolation and `Sendable` assumptions, ordering guarantees, which tmux
releases behave differently, how a tmux error is mapped, and whether a value is
a snapshot or a live view. Never narrate the declaration — the compiler already
said what the parameters are.

Link symbols with double backticks, not prose backticks. ``Server`` and
``OutputWait/Outcome/stopped`` resolve, survive a rename, and can be followed;
`Server` in single backticks is just text. DocC warnings fail CI, so a broken
link is an error rather than a note.

Deprecation is a machine-actionable migration, and Swift is unusually good at
it. Prefer the attribute to a prose note:

```swift
@available(*, deprecated, renamed: "send(_:enter:)")
public func sendKeys(_ keys: String) async throws
```

A doc comment may carry a `swift` fence, and that fence is subject to the same
rule as the README's: it must exist as a file under `Examples/Sources/`.

## Source comments

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

## Terminology and capitalization

- **Sentence-case headings.** "Platform support", not "Platform Support".
- **tmux is lowercase**, always, including at the start of a sentence — it is
  the program's name. So is `libtmux`.
- **The project is "libtmux for Swift".** Not "LibTmux-Swift", not "the Swift
  port of libtmux" in a title position.
- **Backticks mean technical identity**: types, keywords, flags, paths,
  environment variables, socket names, tmux commands and format strings. Not
  every technical noun — "the Swift compiler" is prose, `Sendable` is not.
- **Use Swift's vocabulary exactly.** Value and reference, actor isolation,
  language mode, strict concurrency, trait, product, target, module. A "class"
  is a class; a `struct` is not one.
- **Use tmux's vocabulary exactly.** Server, session, window, pane, client,
  format, hook, control mode. The library models tmux's nouns, so a synonym
  invented here costs the reader the mapping.
- **Spell out the first use of an initialism** other than MCP, YAML, JSON, and
  CI.

## Markdown

Prose in Markdown files wraps at 80 columns. Table rows, reference-link
definitions, and code blocks are exempt: a wrapped table row does not render.
Pull request and issue bodies do not wrap at all — GitHub renders a single
newline in a comment as a hard break.

Links in `README.md` are reference-style, collected at the foot of the file, so
a paragraph stays readable in source.

Asides differ by renderer, and both forms are correct in their own place:
`README.md` uses GitHub's alert syntax (`> [!WARNING]`), and the DocC catalogue
uses DocC's own (`> Important:`). Do not carry one into the other's file.

Content between `<!-- ...:start -->` and `<!-- ...:end -->` is generated. Never
edit it by hand; run the generator. `Scripts/update_mode_matrix.py --check`
fails when the table has drifted, and CI runs that check.

## Code blocks

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

## Slop prevention

Slop is review-hostile noise. It is not proof that the text or the code is
wrong, but it costs a reviewer attention that the change itself deserved.

- **No AI signatures.** No "Generated by", no co-author trailers for a tool, no
  emoji, no cheerful filler.
- **No brittle references.** Line numbers, file counts, percentages nobody
  regenerates, bare commit SHAs, local absolute paths, and "as of today" all
  rot in place. Name the symbol or the file instead.
- **No diff narration.** The diff already shows what changed; prose that
  restates it earns nothing.
- **No branch-internal narrative.** An approach tried and abandoned mid-branch
  is not a fact about the software. It belongs in the commit that abandoned it,
  if anywhere.
- **No ownerless TODOs.** Unfinished work goes in the tracker.
- **No coded labels.** `[R1]`, "Option B", and "as discussed above" mean
  nothing to a reader arriving from a search result.

The carve-out: a comment explaining *why* is the point of this document, not
slop. Delete narration, keep constraints.
