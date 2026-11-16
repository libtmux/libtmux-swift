# ci_plan

Plans which tmux releases CI runs, and fails when the pages and workflows that
mention them disagree with one manifest.

[`tmux-matrix.json`](tmux-matrix.json) is the only list of tmux versions. It
names the released versions, the pinned preview commit, the releases the library
refuses, the client for each daemon and the Swift toolchain.

Adding a release there is the whole change to CI.

## Plan the matrix

The `plan` job in `ci.yml` runs the planner and feeds the legs to the `test` and
`refusal` jobs:

- A push or pull request gets the oldest and newest release.
- A tag and `scope: full` get the whole table, the pinned preview and the
  refusal cells.

The same command prints a plan without a runner:

```console
$ uv run scripts/ci_plan/ci_plan.py matrix --event push
```

A dispatch names its own refs:

```console
$ uv run scripts/ci_plan/ci_plan.py matrix \
    --event workflow_dispatch \
    --scope custom \
    --tmux-ref 3.6b,master
```

The `required` job calls `ci_plan.py verify` to compare each job's result with
what the plan expected.

## Check the pages and workflows

[`check_ci.py`](check_ci.py) fails when:

- a README, a DocC page or CONTRIBUTING states a tmux range the manifest does
  not, or `ci.yml` carries a version list of its own;
- an input is spliced into a script, a tmate step is unpinned, or a job is
  missing from `required`;
- a workflow no longer runs on a tag;
- a script calls `apt-get` directly, or a shared action is not pinned to a full
  commit;
- a job builds tmux without the shared `build-tmux` action.

```console
$ uv run scripts/ci_plan/check_ci.py
```

CI runs it on the repository-checks leg of the `test` job.

## Tests

Each rule has a case that breaks a copy of the tree and expects the guard to
say so.

```console
$ uv run --group dev pytest scripts/ci_plan
```
