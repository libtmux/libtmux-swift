# changelogs

Holds every product to a changelog of its own and builds the release notes from
them. `check` fails when a product has lost its `CHANGELOG.md`, its name
heading, its `## [Unreleased]` section, a release the root file lists, or its
exclusion from its target in `Package.swift`. `notes <version>` prints the
section for a version from the root changelog, then each product's under its
name, and refuses a version any file has no section for.

CI runs `check` on the repository-checks leg of the `test` job. The `release`
workflow runs `notes` before it creates a release, so a tag that the changelogs
do not describe fails there rather than publishing.

```console
$ uv run scripts/changelogs/changelogs.py check
```

```console
$ uv run scripts/changelogs/changelogs.py notes 0.1.1
```

## Tests

```console
$ uv run --group dev pytest scripts/changelogs
```
