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

`exactlyOne(_:)` distinguishes "nothing matched" from "several matched", because
a caller addressing one object needs to know which mistake it made.

Matching happens over values already in hand, so iterating results never spawns
tmux.
