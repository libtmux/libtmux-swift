# check_changelog_symbols

Fails when a changelog entry names a member of a type this package declares
and that member no longer exists. A reference counts when it reads
`Owner.member` and `Owner` is a declared type, so a renamed method fails here.

It reads the root `CHANGELOG.md` and the one beside each product's sources. CI
runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_changelog_symbols/check_changelog_symbols.py
```

`--changelog` checks one file.

## Tests

```console
$ uv run --group dev pytest scripts/check_changelog_symbols
```
