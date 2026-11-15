# check_continuations

Fails when a continuation under `Sources/` can be left parked after its task is
cancelled. `Task.cancel()` sets a flag and resumes nothing, so a caller parked
in `withCheckedContinuation` stays parked for the life of the process, and a
Swift Testing `.timeLimit` cannot end it: the limit cancels the case and then
waits for it to return.

The script requires `withTaskCancellationHandler` to open just above each
continuation. Where the caller releases the park instead, such as
`OrderedOutbound`, the exception is listed in the script beside the code that
resumes it. It cannot follow a handler installed further away.

CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_continuations/check_continuations.py
```

## Tests

```console
$ uv run --group dev pytest scripts/check_continuations
```
