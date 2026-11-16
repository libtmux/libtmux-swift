# check_resolved_pins

Fails when `Package.resolved` no longer pins Yams. The file tracks a superset
that includes Yams even when the `YAMLWorkspaces` trait is off, and a trait-off
`swift test` resolves without it and rewrites the file to drop that pin.
Checking the committed file is what catches the drift, because a run that
already has the pin never restores it.

It reads `Package.resolved` in the current directory, or the file named by its
one argument, and exits 1 when no pin has the identity `yams` and 2 when the
file is missing or is not JSON. The `test` job in `ci.yml` runs it, then
checks with `git diff` that no step rewrote either lock.

```console
$ uv run scripts/check_resolved_pins/check_resolved_pins.py
```

## Tests

```console
$ uv run --group dev pytest scripts/check_resolved_pins
```
