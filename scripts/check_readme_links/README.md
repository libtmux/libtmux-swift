# check_readme_links

Fails when a README link points at something that no longer exists. It reads
every `README.md` and the pages under `docs/`, and checks against the tree, with
no network:

- a link into this repository, and its `#fragment`, names a path and a heading
  that exist;
- a libtmux.org API page names a public symbol the sources declare, and a tool
  page names a tool in `ToolOperation`;
- a reference-style link has a definition;
- the root README links every product directory from a heading;
- no prose block in a product README runs past the length limit.

Whether a page answers 200 once published is the documentation workflow's
question. CI runs this check on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_readme_links/check_readme_links.py
```

## Tests

```console
$ uv run --project scripts --group dev pytest scripts/check_readme_links
```
