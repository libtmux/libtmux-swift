<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/workspace.svg" type="image/svg+xml">
    <img src="../../assets/workspace.png" width="128" height="128" alt="libtmux for Swift workspace">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# [`TmuxWorkspace`][mod-tmuxworkspace]

Builds a whole tmux session from a [tmuxp][] workspace — written in Swift, read
from JSON, or read from YAML.

</div>

```swift
.product(name: "TmuxWorkspace", package: "libtmux-swift")
```

**Contents** — [Quick start](#quick-start) · [Build](#build-a-session) ·
[YAML](#yaml-is-behind-a-trait) · [What tmuxp it covers](#which-of-tmuxp-this-covers) ·
[From a shell](#from-a-shell) · [Reference](#reference)

## Quick start

The module is [`TmuxWorkspace`][mod-tmuxworkspace], and the thing that does the
building is [`WorkspaceBuilder`][api-workspacebuilder]. Import the module and
describe a [`Workspace`][api-workspace]:

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

[`WindowPlan`][api-windowplan] and [`PanePlan`][api-paneplan] describe each
window and its panes. Build it on a [`Server`][api-server]:

```swift
let session = try await WorkspaceBuilder.build(workspace, on: server)
```

`WorkspaceTests` builds this value on a fixture server and asserts tmux ends up
with the `work` session, its `editor` and `logs` windows, and two panes in
`editor`.

Swift has no namespaces worth the name, so the module carries the prefix that
says which `Workspace` this is, and the type keeps the verb. The rest of the
family names it the same way:

- [`tmux-workspace`][rs] in Rust, [`@libtmux/workspace`][ts] in TypeScript
- [`libtmux-workspace`][java] in Java, [`LibTmux.Workspace`][cs] in C#

## Build a session

### [`WorkspaceBuilder.build(_:on:)`][api-workspacebuilder-build-on]: a whole session in one call

The build creates the session, its windows, and their panes in order. What to
know:

- **A name in use is refused.** Two callers building the same workspace should
  not silently share one session.
- **A failure rolls back.** A later failure removes the exact session this
  build created; a rollback failure reports both errors.

[`WorkspaceBuilderError`][api-workspacebuildererror] names each way a build can
fail.

### [`Server.validateLayouts(_:)`][api-server-validatelayouts]: layouts are checked first

Every configured layout goes through
[`validateLayouts`][api-server-validatelayouts] before session changes. It uses
each window's desired pane count and shares the native core and MCP grammar:

- **Missing or empty layouts** leave tmux's layout unchanged.
- **Abbreviations.** Named layouts follow the running daemon.
- **Saved layouts** require a checksum and a nonempty tree with enough pane
  cells. Geometry and pruning remain tmux's responsibility.

## YAML is behind a trait

### [`Workspace.decode(yaml:)`][api-workspace-decode-yaml]: read a tmuxp file

A workspace described in Swift or read from JSON needs no parser, so none is
pulled in by default, and [`Workspace.decode(json:)`][api-workspace-decode-json]
always exists.

[`decode(yaml:)`][api-workspace-decode-yaml], and the [Yams][] dependency behind
it, appears only when the `YAMLWorkspaces` trait is enabled:

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
[their notice][r-tests-tmuxworkspacetests-fixtures-notice-md].

## From a shell

### [`tmux-workspace`][mod-tmux-workspace]: the same files from a terminal

[`load`][ref-cli-load] builds a workspace file on a socket named `project` and
leaves the session detached. [`freeze`][ref-cli-freeze] writes a running session
back out:

```console
$ tmux-workspace load \
    -L project \
    -d \
    project.yaml
```

`tmux-workspace` is a separate reader of the format, and every session it
creates goes through [`WorkspaceBuilder`][api-workspacebuilder]. Its
[README][cli-readme] has a command example for each subcommand.

## Reference

- [API pages][ref-ws-reference]: [`Workspace`][api-workspace],
  [`WindowPlan`][api-windowplan], [`PanePlan`][api-paneplan],
  [`WorkspaceBuilder`][api-workspacebuilder], and
  [`WorkspaceBuilderError`][api-workspacebuildererror]
- [Workspaces][ref-concept-workspaces]: building a layout from the object API
  or a file
- [Workspace configuration][ref-ws-config]: the keys a file may use
- [Swift Package Index][spi-workspace]

[tmuxp]: https://tmuxp.git-pull.com/
[rs]: https://github.com/libtmux/libtmux-rs
[ts]: https://github.com/libtmux/libtmux-ts
[java]: https://github.com/libtmux/libtmux-java
[cs]: https://github.com/libtmux/libtmux-csharp
[Yams]: https://github.com/jpsim/Yams
[cli-readme]: ../TmuxWorkspaceCLI/README.md
[spi-workspace]: https://swiftpackageindex.com/libtmux/libtmux-swift/documentation/tmuxworkspace
[api-paneplan]: https://libtmux.org/en/swift/latest/workspace/reference/paneplan/
[api-server-validatelayouts]: <https://libtmux.org/en/swift/latest/reference/server-validatelayouts(_-)/>
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[api-windowplan]: https://libtmux.org/en/swift/latest/workspace/reference/windowplan/
[api-workspace-decode-json]: <https://libtmux.org/en/swift/latest/workspace/reference/workspace-decode(json-)/>
[api-workspace-decode-yaml]: <https://libtmux.org/en/swift/latest/workspace/reference/workspace-decode(yaml-)/>
[api-workspace]: https://libtmux.org/en/swift/latest/workspace/reference/workspace/
[api-workspacebuilder-build-on]: <https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder-build(_-on-)/>
[api-workspacebuilder]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuilder/
[api-workspacebuildererror]: https://libtmux.org/en/swift/latest/workspace/reference/workspacebuildererror/
[mod-tmux-workspace]: https://libtmux.org/en/swift/latest/workspace/cli/
[mod-tmuxworkspace]: https://libtmux.org/en/swift/latest/workspace/reference/
[r-tests-tmuxworkspacetests-fixtures-notice-md]: ../../Tests/TmuxWorkspaceTests/Fixtures/NOTICE.md
[ref-cli-freeze]: https://libtmux.org/en/swift/latest/workspace/cli/freeze/
[ref-cli-load]: https://libtmux.org/en/swift/latest/workspace/cli/load/
[ref-concept-workspaces]: https://libtmux.org/en/swift/latest/concepts/workspaces/
[ref-ws-config]: https://libtmux.org/en/swift/latest/workspace/configuration/
[ref-ws-reference]: https://libtmux.org/en/swift/latest/workspace/reference/
