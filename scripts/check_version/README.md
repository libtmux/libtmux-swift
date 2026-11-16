# check_version

Fails when a version the package claims is not the one it is.
`LibTmuxVersion.current` is the source.

- An `exact:` pin in a README, a DocC page or a manifest must name it.
- A `from:` bound must name a final release that is not newer than it.
- A nested package that pins a third-party dependency passes through.

CI runs it on the repository-checks leg of the `test` job, and a release commit
has to pass it before the tag, because `release.yml` refuses a tag that
disagrees with `LibTmuxVersion.current`.

```console
$ uv run scripts/check_version/check_version.py
```

## Tests

```console
$ uv run --group dev pytest scripts/check_version
```
