# tmux-workspace

`tmux-workspace` provides native Swift commands for discovering, searching,
converting, importing, editing, loading and capturing tmux workspaces. This
implementation is partial. The library's existing workspace APIs remain
available separately.

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

`import teamocil` and `import tmuxinator` translate a required source file or
name. Bare names use `~/.teamocil` or `TMUXINATOR_CONFIG` (defaulting to
`~/.tmuxinator`). Import preserves the translated command, directory and layout
structure and warns about untranslated fields. It rejects ERB templates.
`--save-to`, `--workspace-format` and `--force` control optional file output.
Without a destination, import previews the translated document. The importer
combines tmuxinator `pre` and `pre_window` as inherited pane commands; it does
not reconstruct tmuxinator's Ruby lifecycle.

`edit` resolves a workspace and runs `EDITOR` (default `vi`) with its path.
Quoted executable paths and arguments are supported without an implicit shell.
The command preserves the editor's exit status. Human terminal calls inherit
the terminal; machine calls capture child stdout/stderr in the result and limit
each stream to one MiB. Cancellation terminates a captured child's process
group. Interactive job control and descendant cleanup need broader validation.

`debug-info` reports the package, platform, selected tmux executable/version,
workspace directories and selected environment fields. An unavailable tmux
binary appears in the result without failing diagnostics. Home masking applies
to named path/environment fields; it is not a general output redactor.

`load -d` creates sessions on an explicit `-S` or `-L` endpoint, or the
inherited `TMUX` socket. Outside tmux, this checkpoint requires an endpoint.
It supports session/window/pane directories, layouts, pane command shorthand,
inherited commands, history suppression and sequential `enter` settings.
Session `environment` reaches the first pane at creation. Session `options`
and inherited `window_options` apply before pane commands, with each window's
`options` overriding inherited values. `before_script` runs direct argv after
session creation, using the expanded session directory or invocation directory
when omitted. It runs before options; its failure removes the created session.
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
successful sessions. NDJSON conversion, capture and import results include a
versioned envelope and nested `workspace` document. Diagnostics use stderr.
Machine output bypasses color.

Human listing uses semantic name/path colors. `--color auto|always|never`,
`NO_COLOR` and `FORCE_COLOR` control it. Text from workspace names and paths
has terminal control characters escaped.

## Remaining work

Python shell commands; append and terminal
attachment; plugins and further execution settings; progress
presentation; complete capture; generated manuals; release installation and
matched benchmarks remain outside this checkpoint. The complete tmuxp command
surface is not yet available. YAML is unavailable when its build trait is off.
