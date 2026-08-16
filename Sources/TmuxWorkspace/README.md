# `TmuxWorkspace`

Builds a whole tmux session from a [tmuxp][] workspace — written in Swift, read
from JSON, or read from YAML.

The module is `TmuxWorkspace` and the thing that does the building is
`WorkspaceBuilder`. Swift has no namespaces worth the name: importing a module
puts its types straight into your file, so the module carries the prefix that
says which `Workspace` this is, and the type keeps the verb. The rest of the
family names it the same way — [`tmux-workspace`][rs], [`@libtmux/workspace`][ts],
[`libtmux-workspace`][java], [`LibTmux.Workspace`][cs].

```swift
.product(name: "TmuxWorkspace", package: "libtmux-swift")
```

```swift
import TmuxWorkspace

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
    exact: "0.1.0-alpha.2",
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
See [the fixtures' notice](../../Tests/TmuxWorkspaceTests/Fixtures/NOTICE.md).

[tmuxp]: https://tmuxp.git-pull.com/
[rs]: https://github.com/libtmux/libtmux-rs
[ts]: https://github.com/libtmux/libtmux-ts
[java]: https://github.com/libtmux/libtmux-java
[cs]: https://github.com/libtmux/libtmux-csharp
[Yams]: https://github.com/jpsim/Yams
