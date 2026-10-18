<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/workspace.svg" type="image/svg+xml">
    <img src="../../assets/workspace.png" width="128" height="128" alt="libtmux for Swift workspace">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# `TmuxWorkspace`

Builds a whole tmux session from a [tmuxp][] workspace — written in Swift, read
from JSON, or read from YAML.

</div>

The module is `TmuxWorkspace` and the thing that does the building is
[`WorkspaceBuilder`][api-workspacebuilder]. Swift has no namespaces worth the
name: importing a module puts its types straight into your file, so the module
carries the prefix that says which `Workspace` this is, and the type keeps the
verb. The rest of the family names it the same way — [`tmux-workspace`][rs],
[`@libtmux/workspace`][ts], [`libtmux-workspace`][java],
[`LibTmux.Workspace`][cs].

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

Every configured layout is checked through `Server.validateLayouts(_:)`
before session changes. The check uses each window's desired pane count and
shares the native core and MCP grammar. Missing or empty layouts leave tmux's
layout unchanged; named abbreviations follow the running daemon. Saved layouts
require a checksum and a nonempty tree with enough pane cells. Geometry and
pruning remain tmux's responsibility.

## YAML is behind a trait

A workspace described in Swift or read from JSON needs no parser, so none is
pulled in by default. [`Workspace.decode(yaml:)`][api-decode-yaml] — and the
[Yams][] dependency behind it — appears only when the `YAMLWorkspaces` trait is
enabled:

```swift
.package(
    url: "https://github.com/libtmux/libtmux-swift.git",
    exact: "0.1.0-alpha.6",
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

## From a shell

[`tmux-workspace`][dir-cli] reads the same tmuxp files and is a separate reader
of the format; every session it creates goes through `WorkspaceBuilder`. With a
workspace file saved as `project.yaml`, [`load`][ref-cli-load] builds it on a
socket named `project` and leaves the session detached:

```console
$ tmux-workspace load \
    -L project \
    -d \
    project.yaml
```

[`freeze`][ref-cli-freeze] writes a running session back out as a workspace
file. Its [README][cli-readme] has a command example for each subcommand.

## Reference

- [API pages][ref-workspace]: [`Workspace`][api-workspace],
  [`WindowPlan`][api-windowplan], [`PanePlan`][api-paneplan],
  [`WorkspaceBuilder`][api-workspacebuilder], and
  [`WorkspaceBuilderError`][api-builder-error]
- [Workspaces][ref-concept]: building a layout from the object API or a file
- [Workspace configuration][ref-config]: the keys a file may use
- [Swift Package Index][spi-workspace]

[tmuxp]: https://tmuxp.git-pull.com/
[rs]: https://github.com/libtmux/libtmux-rs
[ts]: https://github.com/libtmux/libtmux-ts
[java]: https://github.com/libtmux/libtmux-java
[cs]: https://github.com/libtmux/libtmux-csharp
[Yams]: https://github.com/jpsim/Yams
[api-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/workspace/
[api-workspacebuilder]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder/
[api-windowplan]: https://libtmux.org/en/swift/latest/workspace/reference/windowplan/
[api-paneplan]: https://libtmux.org/en/swift/latest/workspace/reference/paneplan/
[api-builder-error]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuildererror/
[ref-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/
[ref-concept]: https://libtmux.org/en/swift/latest/concepts/workspaces/
[ref-config]: https://libtmux.org/en/swift/latest/workspace/configuration/
[ref-cli-load]: https://libtmux.org/en/swift/latest/workspace/cli/load/
[ref-cli-freeze]: https://libtmux.org/en/swift/latest/workspace/cli/freeze/
[api-decode-yaml]: <https://libtmux.org/en/swift/latest/workspace/reference/workspace-decode(yaml-)/>
[dir-cli]: https://github.com/libtmux/libtmux-swift/tree/master/Sources/TmuxWorkspaceCLI
[cli-readme]: ../TmuxWorkspaceCLI/README.md
[spi-workspace]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/tmuxworkspace
