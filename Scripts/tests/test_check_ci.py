"""Tests for the CI drift guards.

The first test runs the guards on this repository. Every other test breaks one
thing in a copy of it and expects the guard for that thing to say so, because a
guard that cannot fail is not guarding anything.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import sys
from pathlib import Path
from typing import Any

import pytest


def load(name: str, filename: str) -> Any:
    """Import a script from `Scripts/` under `name`."""
    path = Path(__file__).parents[1] / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


CHECK = load("check_ci", "check_ci.py")

ROOT = Path(__file__).resolve().parents[2]
COPIED = (
    *CHECK.RANGE_PAGES,
    CHECK.CONTRIBUTING,
    "Scripts/tmux-matrix.json",
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
    path = tree.root / "Scripts/tmux-matrix.json"
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
    """A page must state the range at all."""
    tree.edit(
        "Sources/TmuxWorkspaceCLI/README.md",
        "**3.3a through 3.8, and master**",
        "**3.3a and newer**",
    )
    assert tree.flags("TmuxWorkspaceCLI/README.md does not say tmux 3.3a through 3.8")


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
    tree.edit("README.md", "3.3a and 3.8", "3.3a and 3.7", 2)
    assert tree.flags("README.md does not say a push tests the edges")


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
        "          python3 Scripts/ci_plan.py verify",
        f"          echo {spliced}\n          python3 Scripts/ci_plan.py verify",
    )
    assert tree.flags("splices an input into a script")


def test_a_workflow_that_skips_tags_is_flagged(tree: Tree) -> None:
    """Without a tag trigger a release is never tested."""
    tree.edit(CI, '    tags: ["*"]\n', "")
    assert tree.flags("does not run on a tag")


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
