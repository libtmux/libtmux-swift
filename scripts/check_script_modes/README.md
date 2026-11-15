# check_script_modes

Fails when a tracked file that starts with a shebang is not executable in git.
Ruff reports the same fault as `EXE001` on the runner and not reliably on a
developer machine, so the gate reads the mode git recorded, which is what a
checkout produces. A symlink is skipped.

CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_script_modes/check_script_modes.py
```

Fix a failure with `chmod +x <path> && git add <path>`.

## Tests

```console
$ uv run --group dev pytest scripts/check_script_modes
```
