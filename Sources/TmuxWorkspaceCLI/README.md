<!-- libtmux-logo -->
<div align="center">
  <picture>
    <source srcset="../../assets/workspace.svg" type="image/svg+xml">
    <img src="../../assets/workspace.png" width="128" height="128" alt="libtmux for Swift workspace">
  </picture>
</div>
<!-- /libtmux-logo -->

<div align="center">

# tmux-workspace

Load, list, search, convert, import, edit, and capture tmux workspaces from a
shell.

</div>

[`load`][ref-cli-load] reads a tmuxp-style workspace file into a session,
[`freeze`][ref-cli-freeze] writes a running session back to a file, and
[`convert`][ref-cli-convert] and [`import`][ref-cli-import] change files between
formats. The command is partial: [What it leaves out](#what-it-leaves-out) lists
the gaps.

The library's workspace APIs, [`TmuxWorkspace`][mod-tmuxworkspace], remain
available separately.

Alpha software. The command surface can change in any release. Pin an exact
version.

**Contents** — [Quick start](#quick-start) · [Install](#install) ·
[Load](#load-a-workspace) · [Find](#find-a-workspace) ·
[Capture and convert](#capture-and-convert) ·
[Edit and inspect](#edit-and-inspect) · [Output](#read-the-output) ·
[MCP](#look-at-a-loaded-workspace-through-mcp) ·
[Leaves out](#what-it-leaves-out) · [Support](#support-and-status)

## Quick start

A workspace is a YAML file that names a session, its windows, and the panes in
each. It is the format [tmuxp][] reads. Save this as `example.yaml`:

```yaml
session_name: example
windows:
  - window_name: editor
    layout: even-horizontal
    panes:
      - vim
      - npm run watch
  - window_name: logs
    panes:
      - start_directory: /var/log
        shell_command: tail -f syslog
```

Inside tmux, [`tmux-workspace load`][ref-cli-load] builds the session on the
server you are in and switches to it:

```console
$ tmux-workspace load example.yaml
```

Outside tmux, name a socket with `-L` and leave the session detached with `-d`:

```console
$ tmux-workspace load \
    -L project \
    -d \
    example.yaml
```

It prints `example  created`, and `tmux -L project attach` joins the session.
Outside tmux, `load` refuses to run without `-S` or `-L`.

## Install

### `swift build`: build the command

Build with the `YAMLWorkspaces` trait, which pulls in [Yams][] to read YAML.
Without it, YAML files are unavailable:

```console
$ swift build \
    --jobs 2 \
    --traits YAMLWorkspaces \
    --force-resolved-versions \
    --product tmux-workspace
```

`--help` lists the subcommands:

```console
$ .build/debug/tmux-workspace --help
```

### `install`: put it on your PATH

Build an optimized executable, then install it in a directory on `PATH`:

```console
$ swift build \
    --configuration release \
    --jobs 2 \
    --traits YAMLWorkspaces \
    --force-resolved-versions \
    --product tmux-workspace
```

```console
$ install -dm755 "$HOME/.local/bin"
```

```console
$ install -m755 .build/release/tmux-workspace "$HOME/.local/bin/tmux-workspace"
```

On Linux the installed binary needs the Swift runtime libraries from the
toolchain, so it runs only where that toolchain is installed.

### [`--generate-completion-script`][ref-cli-completion]: shell completion

The parser generates completion for bash, zsh, and fish:

```console
$ .build/debug/tmux-workspace --generate-completion-script zsh
```

## Load a workspace

### [`tmux-workspace load`][ref-cli-load]: build a session from a file

[`load`][ref-cli-load] takes workspace files or saved names. [`ls`][ref-cli-ls]
lists the saved names, and [`freeze`][ref-cli-freeze] writes a running session
back out. This builds `example.yaml` on the `project` socket and leaves it
detached:

```console
$ tmux-workspace load \
    -L project \
    -d \
    example.yaml
```

It prints `example  created`. Loading the same file again finds the session by
name and prints `example  reused`. For a script, `--json` prints one result and
never prompts:

```console
$ tmux-workspace load \
    --json \
    -L project \
    -d \
    example.yaml
```

The result holds `status`, `errors`, and a `results` entry per input with its
`session_name` and an `action` of `created` or `reused`. What to know:

- **Attach.** A human call with a foreground terminal attaches to the last
  workspace it loaded; `-d` skips that. Redirected and machine calls need `-d`
  or `--append`.
- **Reuse.** A session that lacks windows the file asks for exits 1 with
  `session_mismatch`, and nothing is built or changed.
- **Failure.** A failed build removes only the session that build created.
- **Layouts.** Names and checksums are checked before anything is created;
  tmux still decides geometry.
- **Differences from tmuxp.** A window with no `layout` is tiled, and the first
  pane is focused by default.

The full contract is in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-load]
and on the command's page.

### `load --append`: add windows to the session you are in

Inside tmux, `--append` adds the file's windows to the current pane's session
and creates no new session:

```console
$ tmux-workspace load \
    --append \
    example.yaml
```

- **Needs a pane.** It requires a valid `TMUX` and `TMUX_PANE`, and never starts
  a different server.
- **Index collisions.** An explicit `window_index` already in the session fails
  the load and creates nothing.
- **With `-d`.** `-d` takes precedence over `--append`.

More in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-load-append].

## Find a workspace

### [`tmux-workspace ls`][ref-cli-ls]: what is saved

[`ls`][ref-cli-ls] lists saved workspaces; [`search`][ref-cli-search] filters
them by what they hold:

```console
$ tmux-workspace ls
```

It prints one workspace per line: its name, then the path of its file. `--tree`
groups them by directory, and `--full` includes each source document in the
JSON result.

- **Where it looks.** Global workspaces come from the first existing directory
  among `TMUXP_CONFIGDIR`, `$XDG_CONFIG_HOME/tmuxp`, and `~/.tmuxp`. Local
  `.tmuxp.yaml`, `.tmuxp.yml`, and `.tmuxp.json` files count too.
- **Empty is authoritative.** An existing empty directory is used as is, and
  missing paths and regular files fall through.

More in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-ls].

### [`tmux-workspace search`][ref-cli-search]: find one by what it holds

A term can carry a field prefix. This finds workspaces with a window matching
`logs`:

```console
$ tmux-workspace search window:logs
```

It prints matches in the same form as [`ls`][ref-cli-ls].

- **Fields.** `name`, `session`, `path`, `window`, and `pane`, with repeated
  `--field` restrictions.
- **Matching.** Literal or native ICU regular expressions, with case, word,
  inversion, and OR options. It does not launch Python.

More in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-search].

## Capture and convert

### [`tmux-workspace freeze`][ref-cli-freeze]: save a running session

[`freeze`][ref-cli-freeze] reads a live session back into a workspace file. This
saves the `example` session built above:

```console
$ tmux-workspace freeze \
    -L project \
    --save-to captured.yaml \
    example
```

It warns what a capture cannot keep, then prints `Saved` and the path.

- **A destination.** `freeze` needs `--save-to` or a machine format; with
  neither it is a usage error.
- **Overwrite.** An existing destination needs `--force`.
- **Not kept.** Original command arguments, scripts, global settings, and
  environment removal markers.

More in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-freeze].

### [`tmux-workspace convert`][ref-cli-convert]: between YAML and JSON

[`convert`][ref-cli-convert] prints a workspace in the other format, JSON for a
YAML file:

```console
$ tmux-workspace convert example.yaml
```

`--save-to` writes the result instead, and prints `Saved` and the path:

```console
$ tmux-workspace convert \
    --save-to example.json \
    example.yaml
```

- **Format.** It defaults to the opposite of the input; `--workspace-format`
  chooses JSON or YAML.
- **Overwrite.** `--force` replaces an existing file, and `-y` writes beside
  the input.

More in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-convert].

### [`tmux-workspace import`][ref-cli-import]: from tmuxinator or teamocil

[`import`][ref-cli-import] translates a project from another manager.
[`import tmuxinator`][ref-cli-import-tmuxinator] and
[`import teamocil`][ref-cli-import-teamocil] each take a path or a name:

```console
$ tmux-workspace import teamocil dev
```

It prints the translated workspace as YAML. `--save-to` writes a file:

```console
$ tmux-workspace import tmuxinator \
    --save-to blog.yaml \
    blog
```

- **Names.** A bare name is looked up under `~/.teamocil`, or under
  `TMUXINATOR_CONFIG` and then `~/.tmuxinator`.
- **Refusals.** A field with no translation fails before anything is printed or
  replaced. Unexpanded ERB in a tmuxinator file fails the same way.

More in [`docs/workspace-cli.md`][r-docs-workspace-cli-md-import].

## Edit and inspect

### [`tmux-workspace edit`][ref-cli-edit]: open a workspace in your editor

[`edit`][ref-cli-edit] resolves a workspace and runs `EDITOR`, `vi` by default,
with its path:

```console
$ EDITOR=nvim tmux-workspace edit example
```

It exits with the editor's status. Quoted executable paths and arguments work
without an implicit shell.

### [`tmux-workspace debug-info`][ref-cli-debug-info]: what it is running on

```console
$ tmux-workspace debug-info
```

It prints the package version, platform, selected tmux and its version, the
workspace directories, and selected environment variables. A missing tmux shows
in the output without failing the command.

### [`tmux-workspace shell`][ref-cli-shell]: a Python shell through tmuxp

[`shell`][ref-cli-shell] hands Python-specific evaluation to tmuxp 1.74.0, using
the interpreter in `TMUX_WORKSPACE_PYTHON` (default `python3`). It checks the
tmuxp version before it runs. Machine calls require `-c`. More in
[`docs/workspace-cli.md`][r-docs-workspace-cli-md-shell].

## Read the output

### `--json` and `--ndjson`: results a script can read

Every command accepts `--json` or `--ndjson`, before or after the command name.
`--json` prints one object:

```console
$ tmux-workspace ls --json
```

It holds `workspaces`, and the directories searched under
`global_workspace_dirs`. `--ndjson` prints one record per line, and wins when
both are given.

- **Failures.** A machine failure carries a `code`, and a usage error exits 2.
- **Signals.** A run a signal stopped is `interrupted`, exit 130.
- **Declining a prompt.** Answering `n` or `q` is a plain exit 0.

The codes and formats are on the [exit codes][ref-cli-exit] and
[output formats][ref-cli-output] pages, with the rest in
[`docs/workspace-cli.md`][r-docs-workspace-cli-md-error-codes].

### `--log-file` and `--progress-format`: logs and progress

`load --log-file PATH` appends JSON records to a file, and `--log-level`
sets the minimum severity shown. Human loads show progress on stderr;
`--no-progress` turns it off. Details are in
[`docs/workspace-cli.md`][r-docs-workspace-cli-md-logging].

## Look at a loaded workspace through MCP

### [`libtmux-mcp`][ref-mcp]: read a session an agent loaded

A loaded workspace is an ordinary tmux session, so the MCP server can read it.
Build the server from the repository root:

```console
$ swift build \
    --configuration release \
    --jobs 2 \
    --force-resolved-versions \
    --product libtmux-mcp
```

Load with `-d` on a named socket, then give the client the same name:

```console
$ claude mcp add tmux \
    -e LIBTMUX_SOCKET=project \
    -e LIBTMUX_TOOLSETS=inspect \
    -- .build/release/libtmux-mcp
```

The client can then call [`list_sessions`], [`list_windows`] with the
session's name, and [`list_panes`]. Pass a pane's id as `paneId` to
[`capture_pane`] or [`wait_for_text`].

- **Socket paths.** For `-S`, set `LIBTMUX_SOCKET_PATH` to the same path; its
  parent directory must exist.
- **Discovery.** `tools/list` shows what the endpoint offers, and the
  [`tmux://capabilities`][ref-capabilities] resource reports the selected
  endpoint and the available tools.
- **Bounds.** Set `maxLines` on reads and `timeoutMs`, in milliseconds, on
  waits.
- **Fixed at startup.** The endpoint is selected once, when the server starts.
- **Another tmux.** Set `LIBTMUX_TMUX_BIN` for a tmux outside `PATH`.
- **Waits.** A pending text wait leaves other calls on the connection free.

The [inspect with MCP guide][ref-ws-inspect-mcp] walks through it, and the
[MCP overview][ref-mcp] covers the server.

## Check the install

### `check_workspace_terminal.py`: terminal handoff

This verifies terminal handoff against the installed executable:

```console
$ python3 Scripts/check_workspace_terminal.py "$HOME/.local/bin/tmux-workspace"
```

### `benchmark_workspace_cli.py`: compare with tmuxp

This compares startup, discovery, search, cold-server load, and YAML capture
with tmuxp 1.74.0 installed in the selected Python interpreter:

```console
$ python3 Scripts/benchmark_workspace_cli.py \
    "$HOME/.local/bin/tmux-workspace" \
    --tmux tmux \
    --python python3 \
    --samples 5 \
    --output workspace-cli-benchmark.json
```

- **What it measures.** Private sockets, with topology and directories checked
  outside the timed subprocess, and every sample kept with its median and
  spread.
- **What it leaves unmeasured.** Its three blank panes exercise pane creation
  only; command execution, interactive behavior, and full capture fidelity are
  not covered.

## What it leaves out

- **Plugins and some execution settings.** An unsupported execution key fails
  before anything is created; prefix a key with `x-` to have it ignored.
- **Complete capture.** [`freeze`][ref-cli-freeze] keeps commands, directories,
  layouts, indexes, focus, and local options. It drops original command
  arguments, scripts, and global settings.
- **Generated manuals and a portable build.** The installed binary needs the
  toolchain's Swift runtime on Linux.
- **The whole tmuxp command surface.** Only the commands above exist.
- **YAML without the trait.** A build without `YAMLWorkspaces` cannot read it.

## Support and status

- **Swift 6.2**, and tmux **3.3a through 3.8, and master**, on Linux, including
  WSL, and macOS. CI runs Ubuntu on every release in the range and macOS on 3.3a
  and 3.7b.
- **tmuxp 1.74.0** only for [`shell`][ref-cli-shell] and the benchmark.
- **Alpha.** Any release may change the command surface; pin an exact version.

## Reference

- [Command manual][ref-cli]: every subcommand, with [`edit`][ref-cli-edit],
  [`debug-info`][ref-cli-debug-info], [`shell`][ref-cli-shell], and
  [`shell completion`][ref-cli-completion]
- [Output formats][ref-cli-output] and [exit codes][ref-cli-exit]
- [Install and load a workspace][ref-ws-install] and
  [inspect a workspace through MCP][ref-ws-inspect-mcp]
- [Workspace configuration][ref-ws-config]: the file the commands read
- [`docs/workspace-cli.md`][r-docs-workspace-cli-md]: the full contract of each
  command

[tmuxp]: https://tmuxp.git-pull.com/
[Yams]: https://github.com/jpsim/Yams
[mod-tmuxworkspace]: https://libtmux.org/en/swift/latest/workspace/reference/
[r-docs-workspace-cli-md-convert]: ../../docs/workspace-cli.md#convert
[r-docs-workspace-cli-md-error-codes]: ../../docs/workspace-cli.md#error-codes
[r-docs-workspace-cli-md-freeze]: ../../docs/workspace-cli.md#freeze
[r-docs-workspace-cli-md-import]: ../../docs/workspace-cli.md#import
[r-docs-workspace-cli-md-load-append]: ../../docs/workspace-cli.md#load---append
[r-docs-workspace-cli-md-load]: ../../docs/workspace-cli.md#load
[r-docs-workspace-cli-md-logging]: ../../docs/workspace-cli.md#logging
[r-docs-workspace-cli-md-ls]: ../../docs/workspace-cli.md#ls
[r-docs-workspace-cli-md-search]: ../../docs/workspace-cli.md#search
[r-docs-workspace-cli-md-shell]: ../../docs/workspace-cli.md#shell
[r-docs-workspace-cli-md]: ../../docs/workspace-cli.md
[ref-capabilities]: https://libtmux.org/en/swift/latest/mcp/resources/capabilities/
[ref-cli-completion]: https://libtmux.org/en/swift/latest/workspace/cli/completion/
[ref-cli-convert]: https://libtmux.org/en/swift/latest/workspace/cli/convert/
[ref-cli-debug-info]: https://libtmux.org/en/swift/latest/workspace/cli/debug-info/
[ref-cli-edit]: https://libtmux.org/en/swift/latest/workspace/cli/edit/
[ref-cli-exit]: https://libtmux.org/en/swift/latest/workspace/reference/exit-codes/
[ref-cli-freeze]: https://libtmux.org/en/swift/latest/workspace/cli/freeze/
[ref-cli-import-teamocil]: https://libtmux.org/en/swift/latest/workspace/cli/import-teamocil/
[ref-cli-import-tmuxinator]: https://libtmux.org/en/swift/latest/workspace/cli/import-tmuxinator/
[ref-cli-import]: https://libtmux.org/en/swift/latest/workspace/cli/import/
[ref-cli-load]: https://libtmux.org/en/swift/latest/workspace/cli/load/
[ref-cli-ls]: https://libtmux.org/en/swift/latest/workspace/cli/ls/
[ref-cli-output]: https://libtmux.org/en/swift/latest/workspace/reference/output/
[ref-cli-search]: https://libtmux.org/en/swift/latest/workspace/cli/search/
[ref-cli-shell]: https://libtmux.org/en/swift/latest/workspace/cli/shell/
[ref-cli]: https://libtmux.org/en/swift/latest/workspace/cli/
[ref-mcp]: https://libtmux.org/en/swift/latest/mcp/
[ref-ws-config]: https://libtmux.org/en/swift/latest/workspace/configuration/
[ref-ws-inspect-mcp]: https://libtmux.org/en/swift/latest/workspace/guides/inspect-with-mcp/
[ref-ws-install]: https://libtmux.org/en/swift/latest/workspace/guides/installation/
[`capture_pane`]: https://libtmux.org/en/swift/latest/mcp/tools/capture_pane/
[`list_panes`]: https://libtmux.org/en/swift/latest/mcp/tools/list_panes/
[`list_sessions`]: https://libtmux.org/en/swift/latest/mcp/tools/list_sessions/
[`list_windows`]: https://libtmux.org/en/swift/latest/mcp/tools/list_windows/
[`wait_for_text`]: https://libtmux.org/en/swift/latest/mcp/tools/wait_for_text/
