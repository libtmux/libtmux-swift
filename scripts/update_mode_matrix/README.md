# update_mode_matrix

Writes the benchmark's own tables into the documents. The mode matrix in the
root README, `Modes.md`, `Streaming.md` and `Waiting.md` sits between
`<!-- ...:start -->` and `<!-- ...:end -->` markers. The script runs
`swift run --package-path Benchmarks libtmux-bench --markdown` once and splices
each page's tables from that one run, so the documented process and round-trip
counts are the ones the code produces. Timings are not written: they move with
the machine.

CI runs `--check` on the leg that has the tmux the tables were measured on, and
fails when a page has gone stale. A maintainer runs it without `--check` to
refresh them. `$SWIFT` names the swift command when a toolchain manager fronts
it.

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
$ uv run --group dev pytest scripts/update_mode_matrix
```
