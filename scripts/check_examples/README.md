# check_examples

Fails when a `swift` fence in the root README, a product README or the DocC
catalogue is not also a file under `Examples/Sources/`. A documented example is
then compiled code, and the check reports which of them a test under
`Examples/Tests/` calls, so the live suite runs them. `--min-executed` keeps
that count from sliding.

It reads the tree and does not invoke Swift: the `Examples` package builds and
runs them. CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_examples/check_examples.py --min-executed 40
```

[`Examples/README.md`](../../Examples/README.md) says how a fence is matched to
an example and what the check cannot see.

## Tests

```console
$ uv run --group dev pytest scripts/check_examples
```
