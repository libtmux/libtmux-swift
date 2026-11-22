# Writing

Prose in this repository follows the shared organization writing guide at
[`libtmux/.github/WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md)
for voice, plain CommonMark, code blocks, README shape
([ADR 0005](https://github.com/libtmux/central/blob/master/docs/decisions/0005-readme-shape.md)),
the three-gate source-comment ceiling, slop prevention, and commit and pull
request formatting. This file records the rules specific to `libtmux-swift`:
`README.md` and the product READMEs under `Sources/`, per-product changelogs,
release notes and bare-semver release tags, the DocC catalogue, `///` doc
comments, and generated tables.

For building, testing, the gates, pull requests, and releases, see
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## Checkable claims

Every claim in repository documentation should be something the compiler, a
script, or CI can contradict: documented Swift examples compile from
`Examples/`, version pins are checked against `LibTmuxVersion.current`, and the
mode benchmark writes its own tables. Write claims that can fail, and let the
gates check them.

## README shape

Root and product READMEs follow the shared
[README shape decision](https://github.com/libtmux/central/blob/master/docs/decisions/0005-readme-shape.md)
with these Swift-specific rules and gates:

- **Header and stability callout.** Open `README.md` with the logo block,
  centred title, and badge row (CI, Swift Package Index release and Swift
  versions, [libtmux.org](https://libtmux.org/en/swift/), license), followed by
  a concise summary and the plain CommonMark `0.1.N` blockquote (`> Releases are
  numbered ...`), never GitHub-only `> [!WARNING]` or `> [!NOTE]` markers.
- **Order and API-linked headings.** Put `## Install` and `## Quick start`
  first, then one `##` section per reader task. Head each subsection with a
  public API symbol in backticks linked to its `libtmux.org` reference page, a
  colon, and its job in plain words.
- **Prose ceiling.** Keep prose blocks to at most 240 rendered characters once
  markup is stripped; `scripts/check_readme_links/check_readme_links.py` fails
  a longer paragraph, list item, or blockquote in `README.md` or a product
  README. Move deeper protocol or CLI contracts to [`docs/`](../docs/) or
  `libtmux.org`.
- **Products and required links.** `README.md` and `Sources/LibTmux/README.md`
  include one heading per shipped product linking its directory on `master`,
  and `README.md` links the primary `LibTmux`, `TmuxWorkspace`, and
  `LibTmuxMCP` entry-point types; `check_readme_links.py` enforces both.
- **Compiled and executed examples.** Every `swift` fence in `README.md`,
  `Sources/*/README.md`, or `Sources/**/*.docc/*.md` must match consumer code
  under `Examples/Sources/` (or an explicit `Package.swift` excerpt in
  `MANIFEST_EXCERPTS`), enforced by
  `scripts/check_examples/check_examples.py`. Open each section's first example
  with its `import` lines, provision private servers through `withTmuxServer`
  from `TmuxFixture` rather than shell `tmux` setup, and cover `FilterExpr`,
  `TmuxCommandList`, `TmuxMode`, and `Server.connected(attachingTo:_:)`.
- **Version pins and tmux floor.** Every `exact:` pin names
  `LibTmuxVersion.current` and every `from:` bound names a final release no
  newer than it (`scripts/check_version/check_version.py`). Floor pages state
  `tmux <oldest> or newer` matching `scripts/ci_plan/tmux-matrix.json`
  (`scripts/ci_plan/check_ci.py`).

## Changelogs and release notes

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
under `## [Unreleased]` and `## [<version>] - <date>` headings with an ISO date
and bare semver.

Each public product keeps its own changelog, and an entry goes in the file of
the product it names:

- `Sources/TmuxWorkspace/CHANGELOG.md` for `TmuxWorkspace` and `tmux-workspace`
- `Sources/LibTmuxMCP/CHANGELOG.md` for `LibTmuxMCP` and `libtmux-mcp`
- `CHANGELOG.md` at the root for `LibTmux`, cross-product entries, and
  repository-wide changes

All products share one version, so every changelog has a heading for every
release; a release with nothing for a product states ``No entries for
`TmuxWorkspace`.`` under it (`scripts/changelogs/changelogs.py check`). Lead
entries with exact Swift identifiers (such as
`Server.waitForOutput(in:matching:)`), checked against the declared symbols by
`scripts/check_changelog_symbols/check_changelog_symbols.py`, and state changed
defaults or incompatibilities with their migration path in the same bullet.

`.github/workflows/release.yml` assembles GitHub Release notes directly from
those changelog sections (root first, then each product under its name) and
refuses a tag if any section is missing. Open a release's notes with a brief
upgrade summary and put migration steps ahead of the detailed list.

## Commits and release tags

Follow the `Scope(type[detail]):` commit format in
[`libtmux/.github/WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md)
(subject at most 50 characters excluding `(#NN)`, body wrapped at 72, blank line
between `why:` and `what:`). Swift-specific dependency and rule scopes use
`swift(deps)`, `swift(deps[dev])`, and `ai(rules[AGENTS])`.

### Release commits

Never create or push tags; the maintainer handles tagging because pushing a tag
publishes the release.

- **Subject:** `Tag <version>` (plain and short, not `Scope(type[detail]):`),
  followed by `why:` and `what:` in the body.
- **Bare semver without `v`:** SwiftPM ecosystems (`swift-nio`, `swift-log`,
  `swift-collections`, `swift-argument-parser`, `Yams`, `swift-subprocess`)
  resolve tags as `1.2.3` rather than `v1.2.3`.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the release checklist enforced by
`release.yml`.

## API documentation

Doc comments use `///` and serve four consumers from one source: DocC, Xcode
quick help, Swift Package Index, and agents reading the declarations.

Begin with a standalone summary fragment ending in a period — a third-person
verb for a method, a noun phrase for a property:

```swift
/// Sends keys to the pane.
/// The number of clients attached to this server.
```

Follow the summary with a blank line before any discussion. Include
`- Parameters:`, `- Returns:`, and `- Throws:` only when they add information
beyond the declaration. Document what the Swift type system cannot express:
ownership and lifetime, suspension or blocking, cancellation semantics, actor
isolation and `Sendable` assumptions, ordering guarantees, `tmux` version
differences, `TmuxError` mapping, and whether a value is a snapshot or a live
stream.

Link symbols with double backticks (` ``Server`` `,
` ``OutputWait/Outcome/stopped`` `) rather than single backticks so DocC
resolves them; DocC warnings fail CI.

Prefer `@available` attributes over prose deprecation notes so compiler fix-its
guide callers:

```swift
@available(*, deprecated, renamed: "send(_:enter:)")
public func sendKeys(_ keys: String) async throws
```

Any `swift` fence inside a `///` doc comment or `.docc` article must also appear
under `Examples/Sources/`.

## Source comments

Apply the three source-comment gates (Loss, Standard-library ceiling, Upkeep)
from
[`libtmux/.github/WRITING.md`](https://github.com/libtmux/.github/blob/main/WRITING.md).
The upkeep gate rejects hand-synced counts from our own code while keeping
frozen external `tmux` facts:

Bad (delete):

```swift
// There are 321 tests to complete for servers.
```

Good (keep):

```swift
// tmux < 3.2 reports the pane ID only after the command completes,
// so this query must stay separate.
```

DocC `///` summaries and `- Parameter` / `- Returns` / `- Throws` fields are
exempt from the loss gate because they document caller contracts, while keeping
the same brevity and upkeep bar.

## Terminology and Markdown conventions

- **Project name:** "libtmux for Swift" in prose and titles, never
  "LibTmux-Swift". Keep `tmux` and `libtmux` lowercase everywhere.
- **Swift and tmux vocabulary:** Use exact Swift terms (value, reference, actor
  isolation, language mode, strict concurrency, trait, product, target, module;
  a `struct` is not a class) and exact `tmux` nouns (`server`, `session`,
  `window`, `pane`, `client`, `format`, `hook`, `control mode`). Spell out the
  first use of an initialism other than MCP, YAML, JSON, and CI.
- **Reference links and callouts:** Collect links in `README.md` as
  reference-style definitions at the foot of the file. Repository `.md` files
  use plain CommonMark blockquotes (`> ...`) and never GitHub alert markers
  (`> [!NOTE]`, `> [!WARNING]`); `.docc` articles use DocC callouts
  (`> Important:`).
- **Generated markers:** Content between `<!-- ...:start -->` and
  `<!-- ...:end -->` is written by
  `scripts/update_mode_matrix/update_mode_matrix.py`; never edit it by hand.
