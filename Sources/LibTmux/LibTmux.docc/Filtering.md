# Filtering

Use the standard library locally; use ``FilterExpr`` when the filter has to
travel.

## Overview

Filter with the standard library when the predicate is local to your code:

```swift
let editors = try await server.panes().filter { $0.currentCommand == "nvim" }
```

Reach for ``FilterExpr`` when the filter has to *travel* — stored in a config,
sent to another process, or handed to a tool. It is built from key paths, so the
compiler rejects a text operator on a number, and it holds no closures, so it
can be encoded:

```swift
let expression = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
let matching = try await server.panes().filter(expression)
```

Regular-expression filters carry a compiled ``RegexPattern`` rather than an
unchecked string:

```swift
let editors = try RegexPattern("^(n?vim|hx)$", options: [.caseInsensitive])
let expression = try FilterExpr<Pane>.where(\.currentCommand, .matches(editors))
let matching = try await server.panes().filter(expression)
```

The bounded dialect rejects lookaround and backreferences. Evaluation throws a
``RegexMatchError`` if its aggregate work budget is exhausted; it never turns a
safety refusal into `false`.

`exactlyOne(_:)` distinguishes matching failures, no match, and several matches
through ``FilterSelectionError``.

Matching happens over values already in hand, so iterating results never spawns
tmux.

## Letting tmux do the narrowing

`filter(_:)` on a `Sequence` runs an expression over values you already have. The
listings on ``Server`` take the expression with them instead, so the rows that
would have been discarded never cross the process boundary:

```swift
let editors = try await server.panes(
    where: .where(\.currentCommand, .isIn(["nvim", "vim"]))
)
```

The two give the same answer. The difference is what crosses the process
boundary: the rows a filter discards are never formatted, piped or decoded, so
the cost tracks the size of the result rather than the size of the server.

### What tmux can and cannot be asked

An expression is lowered to a tmux `-f` predicate that admits *at least*
everything the expression matches, and the result is filtered again here. That
second pass is not a fallback; it is what lets the first one be approximate.

Most of the vocabulary lowers exactly. Two things do not, and both simply widen
the predicate rather than failing:

- ``FilterOperation/matches(pattern:)`` runs on this package's bounded regular
  expression engine, which is not the one tmux would use. It is left out of the
  predicate entirely.
- A glob operator whose text contains a backslash. `fnmatch` reads a backslash
  as its own escape, with no portable way to spell a literal one.

``Server/clients(where:)`` is the exception that pushes nothing: tmux only
grew `list-clients -f` in 3.4, and a server has one client per attachment, so
there is no long listing to narrow. It filters here and answers the same.

Because the predicate may be wide, it is only ever *narrowed* where that is
sound: an `and` keeps whichever side it understands, an `or` containing a branch
it cannot evaluate gives up on the whole disjunction, and a `not` only negates a
child that lowered exactly.
