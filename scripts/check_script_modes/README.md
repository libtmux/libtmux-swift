# check_script_modes

Fails when a tracked file that starts with a shebang is not executable in git.
The gate reads the mode git recorded, which is what a checkout produces; ruff's
`EXE001` is not reliable on a developer machine. A symlink is skipped.

CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_script_modes/check_script_modes.py
```

Fix a failure with `chmod +x <path> && git add <path>`.

## Tests

```console
$ uv run --project scripts --group dev pytest scripts/check_script_modes
```
