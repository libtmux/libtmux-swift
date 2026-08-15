# `WorkspaceBuilder`

Builds a whole tmux session from a [tmuxp][] workspace — written in Swift, read
from JSON, or read from YAML.

```swift
.product(name: "WorkspaceBuilder", package: "libtmux-swift")
```

```swift
import WorkspaceBuilder

let workspace = Workspace(
    sessionName: "work",
    windows: [
        WindowPlan(
            windowName: "editor",
            layout: "even-horizontal",
            panes: [PanePlan(), PanePlan()]
        )
    ]
)
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

Building refuses rather than adopting a session that already has the name: two
callers building the same workspace should not silently share one.

## YAML is behind a trait

A workspace described in Swift or read from JSON needs no parser, so none is
pulled in by default. `Workspace.decode(yaml:)` — and the [Yams][] dependency
behind it — appears only when the `YAMLWorkspaces` trait is enabled:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.1",
    traits: ["YAMLWorkspaces"]
)
```

With the trait off, nothing here resolves Yams at all. That is measurable: a
consumer of this package without the trait fetches `swift-subprocess` and
`swift-system`, and nothing else.

## Which of tmuxp this covers

The keys match tmuxp's, so an existing workspace file is readable without
translation. This is a useful subset rather than a reimplementation: tmuxp's
runtime — plugins, before/after hooks, environment inheritance — is not
modelled, and a file using them builds its windows and ignores the rest.

The suite decodes tmuxp's own example files both ways and compares them, which
tests the two readers against each other over files this project did not write.
See [the fixtures' notice](../../Tests/WorkspaceBuilderTests/Fixtures/NOTICE.md).

[tmuxp]: https://tmuxp.git-pull.com/
[Yams]: https://github.com/jpsim/Yams
