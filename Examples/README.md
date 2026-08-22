# Examples

Every Swift example in the documentation, as code the compiler accepts. A
snippet on a page is prose until something builds it — it can name an API that
was renamed, or quietly keep compiling while it stops being true — so each one
lives here, and [`Scripts/check_examples.py`](../Scripts/check_examples.py)
fails the build when a documented block appears in no file below.

```console
$ python3 Scripts/check_examples.py --min-executed 36
39 documented examples, each compiled; 36 of them run against a real tmux
```

## Why this is its own package

`Examples/` depends on the library rather than living inside it, so an example
reaches the products the way a reader does — no `@testable`, no internals. An
example kept in the suite could use what a consumer cannot and still pass,
which is the thing this split exists to prevent. The sibling ports settled on
the same shape: `libtmux-go` keeps `examples/` as its own module, `libtmux-ts`
as a private workspace package.

It also resolves the root package with `traits: [.defaults, "YAMLWorkspaces"]`,
which is why a trait-gated API is called unguarded here — see the traps below.

## How a fence finds its example

A documented block matches when its lines appear, in order and unbroken, inside
one example. Both sides are dedented first, so a fence shown at column zero
matches the same code nested inside a function:

```swift
public func travelling(_ server: Server) async throws -> [Pane] {
    let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
    let matching = try await server.panes().filter(expression)
    return matching
}
```

The two middle lines are what the README shows. The signature and the `return`
are not, which is the point: the example is a function so that a test can call
it.

An example is one **unit**, and a unit is one function. A new `func` starts a
new unit, so a block spanning two functions matches neither. `main.swift` has
no function to name, so it takes the name of the directory it builds —
`QuickStart`.

A unit counts as **executed** when a test under `Tests/` names it: by calling
`unit(...)`, or for an executable by naming `"QuickStart"` as a string and
spawning it. Compiling catches a call that was renamed; only running catches
one that kept its name and began answering something else. `--min-executed`
keeps that number from sliding.

## What is checked, and what is not

Two documents are scanned, and only two:

| Scanned | Not scanned |
| --- | --- |
| the top-level [`README.md`](../README.md) | the product READMEs under `Sources/` |
| every `Sources/**/*.docc/*.md` | [`Benchmarks/README.md`](../Benchmarks/README.md) |

A `swift` fence added to a product README is therefore **not** compiled by
anything. That is a gap rather than a decision: put an example a reader is
meant to rely on in the top-level README or in the DocC catalogue, where the
check can reach it.

Two more things the check does not do:

- **An example nothing quotes is not reported.** Code here that no page shows
  still compiles and still runs, so it goes stale silently. Delete an example
  when the prose that quoted it goes.
- **Manifest excerpts are exempt by name.** The `.package(...)` and
  `.product(...)` blocks in the README's Install section are Swift, and fenced
  as Swift so they highlight, but none is a statement that compiles alone. They
  are listed in the script rather than detected, so the next one is a decision
  somebody made rather than a heuristic somebody's example happened to match.
  Adding one means adding it to `MANIFEST_EXCERPTS`.

## Adding or changing an example

Edit the code here, never the block on the page, then bring the check across:

```console
$ python3 Scripts/check_examples.py
```

Run them for real, which is what the executed half of that count means:

```console
$ swift test --package-path Examples
```

Three things fail quietly, and all three have cost time:

- **A trait defines its compilation condition only inside the package that
  declares it.** `#if YAMLWorkspaces` here is always false, so it deletes the
  example rather than guarding it. Call the trait-gated API unguarded — this
  package resolves the dependency with the trait on.
- **The `return` a test asserts on goes after the documented block**, never
  inside it. Inside, it breaks the unbroken run of lines the fence matches.
- **A line inserted into the middle of a quoted span breaks the match**, even
  though both the example and the page still read correctly on their own.

Three examples are compiled and never run, for reasons that will not change:
`SIGPIPE` is a process-global disposition the test runner has already chosen,
`TmuxContext.current()` is only non-nil inside a pane, and the quick start is
top-level code no test can call — it is spawned instead.

Every test here provisions servers through the same fixture as the main suite,
so every socket stays under `/tmp/libtmux-swift-test/`.
