# check_examples

Fails when a `swift` fence in the root README, a product README or the DocC
catalogue is not also a file under `Examples/Sources/`, so a documented example
is compiled code.

It reports which examples a test under `Examples/Tests/` calls, and
`--min-executed` keeps that count from sliding.

It reads the tree and does not invoke Swift: the `Examples` package builds and
runs them. CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_examples/check_examples.py --min-executed 40
```

[`Examples/README.md`](../../Examples/README.md) says how a fence is matched to
an example and what the check cannot see.

## Tests

```console
$ uv run --project scripts --group dev pytest scripts/check_examples
```
