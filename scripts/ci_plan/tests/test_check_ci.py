"""Tests for the CI drift guards.

The first test runs the guards on this repository. Every other test breaks one
thing in a copy of it and expects the guard for that thing to say so, because a
guard that cannot fail is not guarding anything.
"""

import json
import re
import shutil
from pathlib import Path

import check_ci as CHECK
import pytest

ROOT = Path(__file__).resolve().parents[3]
COPIED = (
    *CHECK.RANGE_PAGES,
    *CHECK.FLOOR_PAGES,
    CHECK.CONTRIBUTING,
    "scripts/ci_plan/tmux-matrix.json",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/workflows/docs.yml",
)
SHA = "35b54afac29c97fb54faba5b513f8fbd1882f113"
CI = ".github/workflows/ci.yml"


class Tree:
    """A copy of the files the guards read, to break one at a time."""

    def __init__(self, root: Path) -> None:
        """Copy the files into `root`."""
        self.root = root
        for name in COPIED:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / name, target)

    def edit(self, name: str, old: str, new: str, count: int = 1) -> None:
        """Replace `old` with `new` in a copied file, which must contain it."""
        path = self.root / name
        text = path.read_text()
        assert text.count(old) == count, f"{old!r} in {name}"
        path.write_text(text.replace(old, new))

    def append(self, name: str, text: str) -> None:
        """Add `text` to the end of a copied file."""
        path = self.root / name
        path.write_text(path.read_text() + text)

    def problems(self) -> list[str]:
        """Return what the guards say about the copy."""
        return CHECK.check(self.root)

    def flags(self, fragment: str) -> bool:
        """Return whether some problem mentions `fragment`."""
        return any(fragment in problem for problem in self.problems())


@pytest.fixture
def tree(tmp_path: Path) -> Tree:
    """Return a copy of the repository files the guards read."""
    return Tree(tmp_path)


def test_the_repository_agrees_with_its_manifest(tree: Tree) -> None:
    """The pages and workflows in this checkout pass every guard."""
    assert CHECK.check(ROOT) == []
    assert tree.problems() == []


def test_a_new_release_in_the_manifest_reaches_the_pages(tree: Tree) -> None:
    """Adding 3.9 without editing the docs names what is out of date."""
    path = tree.root / "scripts/ci_plan/tmux-matrix.json"
    manifest = json.loads(path.read_text())
    manifest["released"].append("3.9")
    path.write_text(json.dumps(manifest))
    problems = tree.problems()
    for page in CHECK.RANGE_PAGES:
        assert any(page in problem and "3.9" in problem for problem in problems), page
    assert any("lists tmux" in problem for problem in problems)


def test_a_page_with_another_range_is_flagged(tree: Tree) -> None:
    """A DocC page that still says 3.7 is the newest is caught."""
    tree.edit(
        "Sources/LibTmux/LibTmux.docc/PlatformSupport.md",
        "3.3a through 3.8, and master",
        "3.3a through 3.7b, and master",
    )
    assert tree.flags("PlatformSupport.md says tmux 3.3a through 3.7b")


def test_a_page_without_the_range_is_flagged(tree: Tree) -> None:
    """A DocC page must state the range at all."""
    tree.edit(
        "Sources/LibTmux/LibTmux.docc/PlatformSupport.md",
        "3.3a through 3.8, and master",
        "3.3a and newer",
    )
    assert tree.flags("PlatformSupport.md does not say tmux 3.3a through 3.8")


@pytest.mark.parametrize("page", CHECK.FLOOR_PAGES)
def test_a_readme_without_the_floor_is_flagged(tree: Tree, page: str) -> None:
    """The floor is the one claim a README must make about tmux."""
    path = tree.root / page
    path.write_text(path.read_text().replace("tmux 3.3a or newer", "a recent tmux"))
    assert tree.flags(f"{page} does not say tmux 3.3a or newer")


@pytest.mark.parametrize("page", CHECK.FLOOR_PAGES)
def test_a_readme_with_another_range_is_flagged(tree: Tree, page: str) -> None:
    """A range a README does state has to match the manifest."""
    tree.append(page, "\nIt runs on tmux 3.3a through 3.7b, and master.\n")
    assert tree.flags(f"{page} says tmux 3.3a through 3.7b")


def test_a_stale_table_row_is_flagged(tree: Tree) -> None:
    """The table in CONTRIBUTING is read from the manifest too."""
    tree.edit(
        ".github/CONTRIBUTING.md",
        "3.7, 3.7a, 3.7b, 3.8, master |",
        "3.7, 3.7b, 3.8, master |",
    )
    assert tree.flags("lists tmux")


def test_a_page_without_the_edges_is_flagged(tree: Tree) -> None:
    """The page must say what a push tests."""
    tree.edit(".github/CONTRIBUTING.md", "3.3a and 3.8", "3.3a and 3.7")
    assert tree.flags("CONTRIBUTING.md does not say a push tests the edges")


def test_a_page_without_a_refusal_cell_is_flagged(tree: Tree) -> None:
    """Every refusal cell is named."""
    tree.edit(".github/CONTRIBUTING.md", "3.1c", "3.1d", 2)
    assert tree.flags("does not name the refusal cell 3.1c")


def test_contributing_must_show_the_dispatch_command(tree: Tree) -> None:
    """The section needs the exact command."""
    tree.edit(
        ".github/CONTRIBUTING.md", "gh workflow run ci.yml", "gh workflow run x.yml", 3
    )
    assert tree.flags("gh workflow run ci.yml")


def test_a_version_list_in_the_workflow_is_flagged(tree: Tree) -> None:
    """A hard-coded second list would drift from the manifest."""
    tree.edit(CI, "  refusal:\n", "  refusal:\n    env:\n      OLD: '3.4'\n")
    assert tree.flags("ci.yml names tmux 3.4")


def test_the_master_pin_belongs_to_the_manifest(tree: Tree) -> None:
    """A second copy of the pin would let the two disagree."""
    commit = "e1b55d504cab5c11e8e7d432b1b52dd94cc6d1f0"
    tree.edit(CI, "  refusal:\n", f"  refusal:\n    env:\n      PIN: {commit}\n")
    assert tree.flags("the manifest owns that pin")


@pytest.mark.parametrize(
    "spliced", ["${{ inputs.tmux-ref }}", "${{ matrix.tmux }}", "${{ matrix.ref }}"]
)
def test_an_input_spliced_into_a_script_is_flagged(tree: Tree, spliced: str) -> None:
    """Inputs and the values derived from them reach scripts through env only."""
    tree.edit(
        CI,
        "          uv run scripts/ci_plan/ci_plan.py verify",
        f"          echo {spliced}\n          uv run scripts/ci_plan/ci_plan.py verify",
    )
    assert tree.flags("splices an input into a script")


def test_a_workflow_that_skips_tags_is_flagged(tree: Tree) -> None:
    """Without a tag trigger a release is never tested."""
    tree.edit(CI, '    tags: ["*"]\n', "")
    assert tree.flags("does not run on a tag")


def test_a_bare_off_in_the_tmate_input_is_flagged(tree: Tree) -> None:
    """A bare off is false to GitHub, which breaks every default dispatch."""
    tree.edit(CI, "options: ['off',", "options: [off,")
    assert tree.flags("must quote 'off'")


def test_a_bare_off_default_is_flagged(tree: Tree) -> None:
    """The default has to be the same string as the option it names."""
    tree.edit(CI, "default: 'off'", "default: off")
    assert tree.flags("must quote 'off'")


def test_an_unpinned_tmate_is_flagged(tree: Tree) -> None:
    """The action is pinned by commit."""
    tree.edit(CI, f"action-tmate@{SHA} # v3.24", "action-tmate@v3 # v3", 2)
    assert tree.flags("not a full commit")


def test_a_tmate_open_to_everyone_is_flagged(tree: Tree) -> None:
    """Access is limited to the dispatching account."""
    tree.edit(CI, "limit-access-to-actor: true", "limit-access-to-actor: false", 2)
    assert tree.flags("does not limit access")


def test_a_tmate_without_a_timeout_is_flagged(tree: Tree) -> None:
    """A session cannot hold a runner forever."""
    tree.edit(
        CI,
        "        timeout-minutes: 30\n        with:\n          limit",
        "        with:\n          limit",
        2,
    )
    assert tree.flags("no timeout-minutes")


def test_a_tmate_outside_a_dispatch_is_flagged(tree: Tree) -> None:
    """A push can never open a session."""
    tree.edit(
        CI,
        "if: github.event_name == 'workflow_dispatch' && matrix.tmate == 'before",
        "if: matrix.tmate == 'before",
    )
    assert tree.flags("outside a workflow_dispatch")


def test_a_third_tmate_step_is_flagged(tree: Tree) -> None:
    """A session outside the test job is not allowed."""
    tree.append(
        CI,
        f"\n  extra:\n    runs-on: ubuntu-latest\n    steps:\n"
        f"      - uses: mxschmitt/action-tmate@{SHA}\n",
    )
    assert tree.flags("outside the test job")


@pytest.mark.parametrize("name", ["release.yml", "docs.yml"])
def test_tmate_in_another_workflow_is_flagged(tree: Tree, name: str) -> None:
    """Release and docs jobs never open a session."""
    tree.append(
        f".github/workflows/{name}", f"      - uses: mxschmitt/action-tmate@{SHA}\n"
    )
    assert tree.flags(f"{name} runs action-tmate")


def test_a_job_missing_from_the_aggregate_is_flagged(tree: Tree) -> None:
    """A new job that nobody gated would pass unnoticed."""
    tree.edit(CI, "      - refusal\n      - test\n", "      - test\n")
    assert tree.flags("required does not need refusal")


def test_a_stale_name_in_the_aggregate_is_flagged(tree: Tree) -> None:
    """A renamed job left in `needs` would fail every run."""
    tree.edit(
        CI,
        "      - refusal\n      - test\n",
        "      - refusal\n      - tests\n      - test\n",
    )
    assert tree.flags("required needs tests, which is not a job")


def test_a_shared_concurrency_group_is_flagged(tree: Tree) -> None:
    """Dispatch runs must not cancel one another."""
    tree.edit(
        CI,
        "${{ github.event_name == 'workflow_dispatch' && format('-{0}', "
        "github.run_id) || '' }}",
        "",
    )
    assert tree.flags("concurrency group")


@pytest.mark.parametrize("name", ["test", "refusal"])
def test_a_matrix_that_ignores_the_plan_is_flagged(tree: Tree, name: str) -> None:
    """Both matrices are the plan's output."""
    tree.edit(
        CI,
        f"matrix: ${{{{ fromJSON(needs.plan.outputs.{name}) }}}}",
        "matrix:\n        tmux: [x]",
    )
    assert tree.flags(f"the {name} job does not take its matrix from the plan")


FIX = "use the shared apt-get action of libtmux/.github"


def apt_workflow(run: str) -> str:
    """Return a one-step workflow whose script is `run`."""
    return (
        "name: Synthetic\n"
        "on: push\n"
        "jobs:\n"
        "  build:\n"
        "    runs-on: ubuntu-24.04\n"
        "    steps:\n"
        "      - name: Install libevent\n"
        "        run: |\n"
        f"          {run}\n"
    )


def test_a_raw_apt_get_in_a_script_is_flagged() -> None:
    """The message names the file, the job and the step, and the fix."""
    assert CHECK.check_apt(apt_workflow("sudo apt-get update"), "x.yml") == [
        f"x.yml:9 job build, step 'Install libevent' calls apt-get directly; {FIX}"
    ]


@pytest.mark.parametrize(
    ("run", "tool"),
    [
        ("apt-get update", "apt-get"),
        ("sudo -E apt-get install --yes libevent-dev", "apt-get"),
        ("DEBIAN_FRONTEND=noninteractive sudo apt-get install -y x", "apt-get"),
        ("sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y x", "apt-get"),
        ("make && sudo apt-get update", "apt-get"),
        ("sudo apt install --yes libevent-dev", "apt"),
    ],
)
def test_every_spelling_of_a_raw_call_is_flagged(run: str, tool: str) -> None:
    """With or without sudo, options and variables, apt-get and apt are caught."""
    problems = CHECK.check_apt(apt_workflow(run), "x.yml")
    assert len(problems) == 1
    assert f"calls {tool} directly; {FIX}" in problems[0]


@pytest.mark.parametrize(
    "run",
    [
        "# sudo apt-get update",
        "apt-cache policy libevent-dev",
        "echo apt-get is wrapped",
        "./tools/apt-get.sh update",
    ],
)
def test_comments_and_other_apt_tools_are_not_flagged(run: str) -> None:
    """A comment, another apt tool and a path that ends in apt-get.sh all pass."""
    assert CHECK.check_apt(apt_workflow(run), "x.yml") == []


def test_a_step_name_is_not_a_script() -> None:
    """Only `run` scripts are scanned, so a name or a comment may say apt-get."""
    text = apt_workflow("echo ready").replace("Install libevent", "sudo apt-get update")
    assert CHECK.check_apt(text, "x.yml") == []


def test_a_raw_apt_get_in_ci_is_flagged(tree: Tree) -> None:
    """A step that calls apt-get in ci.yml fails the check."""
    tree.append(
        CI,
        "\n  extra:\n    runs-on: ubuntu-24.04\n    steps:\n"
        "      - name: Install\n        run: sudo apt-get update\n",
    )
    flagged = [p for p in tree.problems() if "calls apt-get directly" in p]
    assert len(flagged) == 1
    assert flagged[0].startswith(f"{CI}:")
    assert flagged[0].endswith(FIX)


def test_a_raw_apt_get_in_a_composite_action_is_flagged(tree: Tree) -> None:
    """An action's steps are scanned too; a repository without one passes."""
    action = tree.root / ".github/actions/deps/action.yml"
    action.parent.mkdir(parents=True)
    action.write_text(
        "name: deps\n"
        "runs:\n"
        "  using: composite\n"
        "  steps:\n"
        "    - name: Install\n"
        "      shell: bash\n"
        "      run: sudo apt-get install --yes libevent-dev\n"
    )
    assert tree.flags(
        ".github/actions/deps/action.yml:7 step 'Install' calls apt-get directly"
    )


def test_the_shared_actions_are_pinned_in_this_repository(tree: Tree) -> None:
    """Every `libtmux/.github` action in ci.yml names a full commit."""
    text = (tree.root / CI).read_text()
    assert "libtmux/.github/actions/build-tmux@" in text
    assert CHECK.check_shared_actions(text, CI) == []


@pytest.mark.parametrize("ref", ["main", "v1", "30f81842b1e6", "g" * 40])
def test_a_shared_action_that_is_not_a_full_commit_is_flagged(ref: str) -> None:
    """A branch, a tag or an abbreviated commit can move under the workflow."""
    text = (
        "steps:\n"
        f"  - uses: libtmux/.github/actions/apt-get@{ref}\n"
        "    with:\n"
        "      args: install --yes tmux\n"
    )
    assert CHECK.check_shared_actions(text, "x.yml") == [
        f"x.yml uses libtmux/.github/actions/apt-get at {ref}, not a full commit"
    ]


def test_a_comment_that_names_an_unpinned_action_is_not_flagged() -> None:
    """Only a `uses:` line is a use."""
    text = "# uses: libtmux/.github/actions/apt-get@main\n"
    assert CHECK.check_shared_actions(text, "x.yml") == []


def test_an_unpinned_shared_action_in_ci_is_flagged(tree: Tree) -> None:
    """Moving the build-tmux pin to a branch fails the check."""
    path = tree.root / CI
    path.write_text(
        re.sub(
            r"(libtmux/\.github/actions/build-tmux@)[0-9a-f]{40}",
            r"\1main",
            path.read_text(),
            count=1,
        )
    )
    assert tree.flags("libtmux/.github/actions/build-tmux at main, not a full commit")


@pytest.mark.parametrize("name", ["test", "refusal"])
def test_a_job_that_builds_tmux_itself_is_flagged(tree: Tree, name: str) -> None:
    """Both jobs take their tmux from the shared action."""
    path = tree.root / CI
    parts = re.split(r"(?m)^(  [a-z]+:\s*)$", path.read_text())
    rebuilt = []
    for index, part in enumerate(parts):
        if index > 1 and parts[index - 1].strip() == f"{name}:":
            part = part.replace("build-tmux@", "build-tmux-local@")
        rebuilt.append(part)
    path.write_text("".join(rebuilt))
    assert tree.flags(f"the {name} job does not build tmux with the shared")
