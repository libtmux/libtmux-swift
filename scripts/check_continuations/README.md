# check_continuations

Fails when a continuation under `Sources/` can be left parked after its task is
cancelled. `Task.cancel()` resumes nothing, so a parked caller stays parked for
the life of the process, and Swift Testing's `.timeLimit` cannot end it.

The script requires `withTaskCancellationHandler` to open within a few lines
above each continuation, and cannot follow a handler installed further away.

Where the caller releases the park, as `OrderedOutbound` does, the exception is
listed in the script beside the code that resumes it.

CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_continuations/check_continuations.py
```

## Tests

```console
$ uv run --project scripts --group dev pytest scripts/check_continuations
```
