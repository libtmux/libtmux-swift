# check_workspace

Drives a built `tmux-workspace` executable the way a person does, on a private
tmux, and fails when it misbehaves. A unit test cannot reach these behaviours:
they need a controlling terminal, a real signal and a real server.

| Script | What it verifies |
| --- | --- |
| `check_workspace_terminal.py` | `edit` hands the terminal to `$EDITOR` and takes it back on exit, SIGINT and SIGTERM, keeps control bytes out of machine output, and stops the editor on interruption |
| `check_workspace_progress.py` | `load` progress rendering, stream separation, `--json` and `--ndjson` framing, and cancellation |
| `check_workspace_attach.py` | `load` attach, switch, append and detach choices, with one or several clients attached |

`owned_terminal.py` is the helper the terminal and attach checks share: it forks
a process under a pty, waits for output and reaps it.

CI copies the executable out of `.build` and runs each check on every leg of the
`test` job, passing the executable and the tmux under test. Each check makes its
sockets under `/tmp/libtmux-swift-dev/` and removes them. A maintainer runs them
after a trait-on build:

```console
$ uv run scripts/check_workspace/check_workspace_terminal.py \
    .build/debug/tmux-workspace
```

```console
$ uv run scripts/check_workspace/check_workspace_progress.py \
    .build/debug/tmux-workspace \
    "$LIBTMUX_TMUX_BIN"
```

```console
$ uv run scripts/check_workspace/check_workspace_attach.py \
    .build/debug/tmux-workspace \
    "$LIBTMUX_TMUX_BIN"
```

`check_workspace_attach.py` takes choice names after the tmux to run a subset.

## Tests

The tests run each check against an executable that exits at once and require it
to fail, and cover the terminal helper and the version ordering. The passing
cases are CI's run against the executable it built.

```console
$ uv run --group dev pytest scripts/check_workspace
```
