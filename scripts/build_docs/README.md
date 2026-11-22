# build_docs

Builds the DocC catalogs of the three documented targets, `LibTmux`,
`TmuxWorkspace` and `LibTmuxMCP`, and fails when DocC reports a warning. A
DocC warning is a broken link or a missing symbol that no reader sees until the
page is wrong.

It runs `swift package --force-resolved-versions generate-documentation` for
each target in turn, passes the output through as it is written, and appends it
to `docs.log`, which it empties first. A build that fails stops the run with its
own status. When every build succeeds, any line that says `warning:` fails the
run with that line and the three after it.

The repository checks of the `test` job in `ci.yml` run it.

```console
$ uv run scripts/build_docs/build_docs.py
```

Build one target and keep the log elsewhere:

```console
$ uv run scripts/build_docs/build_docs.py \
    --log /tmp/docs.log \
    LibTmux
```

## Tests

```console
$ uv run --project scripts --group dev pytest scripts/build_docs
```
