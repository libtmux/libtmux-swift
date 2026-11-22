# update_mode_matrix

Writes the benchmark's own tables into the documents: the mode matrix in the
root README, `Modes.md`, `Streaming.md` and `Waiting.md`, between
`<!-- ...:start -->` and `<!-- ...:end -->` markers.

The script runs `swift run --package-path Benchmarks libtmux-bench --markdown`
once and splices each page's tables from that run. Timings are not written,
because they move with the machine.

CI runs `--check` on the leg that has the tmux the tables were measured on, and
fails when a page has gone stale. A maintainer runs it without `--check` to
refresh them.

`$SWIFT` names the swift command when a toolchain manager fronts it.

```console
$ uv run scripts/update_mode_matrix/update_mode_matrix.py
```

```console
$ uv run scripts/update_mode_matrix/update_mode_matrix.py --check
```

## Tests

The tests replace the benchmark with a fixed output, so they start no tmux and
build no Swift.

```console
$ uv run --project scripts --group dev pytest scripts/update_mode_matrix
```
