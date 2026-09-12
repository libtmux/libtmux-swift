# tmux-workspace

`tmux-workspace` provides native Swift commands for discovering, searching,
converting, loading and capturing tmux workspaces. This implementation is
partial. The library's existing workspace APIs remain available separately.

## Build

Enable YAML when building the executable:

```console
$ swift build \
    --jobs 2 \
    --traits YAMLWorkspaces \
    --force-resolved-versions \
    --product tmux-workspace
```

Inspect the native command reference:

```console
$ .build/debug/tmux-workspace --help
```

Generate shell completion from the parser:

```console
$ .build/debug/tmux-workspace --generate-completion-script zsh
```

## Commands

`ls` discovers global workspaces and local `.tmuxp.yaml`, `.tmuxp.yml` and
`.tmuxp.json` files. `TMUXP_CONFIGDIR` overrides the global directories;
otherwise they are `$XDG_CONFIG_HOME/tmuxp` (defaulting to `~/.config/tmuxp`)
and `~/.tmuxp`. Bare names resolve globally. Paths and names with an extension
resolve relative to the invocation directory.

`search` supports field prefixes, repeated field restrictions, literal or
native ICU regular expressions, case and word matching, inversion and OR
matching. It does not launch Python. `convert` preserves document mapping
values, including extension fields. Human conversion previews the opposite
format; `-y` writes it beside the input and refuses an existing destination.

`load -d` creates sessions on an explicit `-S` or `-L` endpoint, or the
inherited `TMUX` socket. Outside tmux, this checkpoint requires an endpoint.
It supports session/window/pane directories, layouts, pane command shorthand,
inherited commands, history suppression and sequential `enter` settings.
Unsupported execution keys fail before creation. Existing exact session names
are reused. A failed build removes only the session that build created and
reports earlier successful workspaces as partial results.

`freeze SESSION` captures current pane commands and directories, window names
and layouts. It writes a document to stdout unless `--save-to` selects a file;
an existing file requires `--force`. Captures warn that original command
arguments and scripts, environment, options, focus and indexes are omitted.

## Output

Every implemented command accepts `--json` and `--ndjson` before or after the
command name. NDJSON wins when both are present. Listing and search stream
records; load streams sequenced events ending in one completed event while
the output stream remains writable. JSON load failures include retained
successful sessions. Diagnostics use stderr. Machine output bypasses color.

Human listing uses semantic name/path colors. `--color auto|always|never`,
`NO_COLOR` and `FORCE_COLOR` control it. Text from workspace names and paths
has terminal control characters escaped.

## Remaining work

Import, editor, diagnostics and Python shell commands; append and terminal
attachment; scripts, plugins and extended execution settings; progress
presentation; complete capture; generated manuals; release installation and
matched benchmarks remain outside this checkpoint. The complete tmuxp command
surface is not yet available. YAML is unavailable when its build trait is off.
