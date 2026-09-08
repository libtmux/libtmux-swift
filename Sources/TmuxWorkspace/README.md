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
```

```swift
let workspace = Workspace(
    sessionName: "work",
    windows: [
        WindowPlan(
            windowName: "editor",
            layout: "even-horizontal",
            panes: [PanePlan(), PanePlan()]
        ),
        WindowPlan(
            windowName: "logs",
            panes: [PanePlan(shellCommands: ["tail -f /tmp/build.log"])]
        ),
    ]
)
```

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

Building refuses rather than adopting a session that already has the name: two
callers building the same workspace should not silently share one. A later
failure removes the exact session this build created; a rollback failure
reports both errors.

## YAML is behind a trait

A workspace described in Swift or read from JSON needs no parser, so none is
pulled in by default. `Workspace.decode(yaml:)` — and the [Yams][] dependency
behind it — appears only when the `YAMLWorkspaces` trait is enabled:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.4",
    traits: ["YAMLWorkspaces"]
)
```

With the trait off, nothing here resolves Yams at all.

## Which of tmuxp this covers

The modelled keys use tmuxp's spelling, so files limited to this structural
subset need no translation:

- workspace: `session_name`, `start_directory`, `windows`
- window: `window_name`, `start_directory`, `layout`, `panes`
- pane: `start_directory`, `shell_command`; commands may be strings or
  `{cmd:, enter:}` objects

Unknown keys are ignored. tmuxp's plugins, before/after hooks, environment
inheritance, and other runtime behavior are not modelled.

The suite compares JSON and YAML forms of selected upstream examples. The
fixtures cover representative data shapes, not tmuxp's full feature set; see
[their notice](../../Tests/TmuxWorkspaceTests/Fixtures/NOTICE.md).

[tmuxp]: https://tmuxp.git-pull.com/
[rs]: https://github.com/libtmux/libtmux-rs
[ts]: https://github.com/libtmux/libtmux-ts
[java]: https://github.com/libtmux/libtmux-java
[cs]: https://github.com/libtmux/libtmux-csharp
[Yams]: https://github.com/jpsim/Yams
