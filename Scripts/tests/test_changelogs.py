"""Tests for the changelog gate and the release notes built from it."""

from __future__ import annotations

import re
import runpy
import shutil
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[2]
GATE = runpy.run_path(str(ROOT / "Scripts" / "changelogs.py"))
PRODUCTS = GATE["PRODUCTS"]
WORKSPACE = PRODUCTS["TmuxWorkspace"]
MCP = PRODUCTS["LibTmuxMCP"]


@pytest.fixture
def tree(tmp_path: Path) -> Path:
    """Copy what the gate reads, each changelog and the manifest, into a tree."""
    for name in [*PRODUCTS.values(), "Package.swift"]:
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / name, tmp_path / name)
    return tmp_path


def failures(root: Path) -> list[str]:
    """Return what the gate says about `root`."""
    return GATE["failures"](root)


def edit(path: Path, old: str, new: str) -> None:
    """Replace the first `old` in `path`, which has to hold it."""
    text = path.read_text(encoding="utf-8")
    assert old in text
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def test_the_repository_passes() -> None:
    """The break cases below prove nothing unless the unbroken tree is clean."""
    assert failures(ROOT) == []


def test_a_missing_changelog_is_reported_for_every_product(tree: Path) -> None:
    """Deleting any one changelog is named."""
    for name, path in PRODUCTS.items():
        (tree / path).unlink()
        assert f"{path}: {name} has no changelog" in failures(tree)
        shutil.copy(ROOT / path, tree / path)


@pytest.mark.parametrize("fence", ["```", "~~~", "````"])
def test_an_unreleased_heading_must_be_outside_a_fence(tree: Path, fence: str) -> None:
    """A heading inside a fence does not count, whatever the fence."""
    # A shorter or different fence inside must not close the outer one.
    inner = "~~~" if fence == "```" else "```"
    edit(
        tree / WORKSPACE,
        "## [Unreleased]\n",
        f"{fence}markdown\n{inner}\n## [Unreleased]\n{fence}\n",
    )

    assert f'{WORKSPACE}: has no "## [Unreleased]" section' in failures(tree)


def test_a_closing_fence_with_an_info_string_does_not_close(tree: Path) -> None:
    """Only a bare fence line ends a fence, as in CommonMark."""
    edit(
        tree / WORKSPACE,
        "## [Unreleased]\n",
        "```markdown\n```js\n## [Unreleased]\n```\n",
    )

    assert f'{WORKSPACE}: has no "## [Unreleased]" section' in failures(tree)


def test_a_changelog_without_an_unreleased_heading_is_reported(tree: Path) -> None:
    """A file with no Unreleased section is named."""
    edit(tree / MCP, "## [Unreleased]\n", "")

    assert f'{MCP}: has no "## [Unreleased]" section' in failures(tree)


def test_another_products_changelog_pasted_over_one_is_reported(tree: Path) -> None:
    """The library's file pasted over a product's is named as the wrong product."""
    shutil.copy(tree / PRODUCTS["LibTmux"], tree / WORKSPACE)

    expected = f"{WORKSPACE}: is the changelog of LibTmux, not TmuxWorkspace"
    assert expected in failures(tree)


def test_the_opening_sentence_must_come_first(tree: Path) -> None:
    """The sentence that names the product is the first thing after the title."""
    edit(tree / MCP, "# Changelog\n\n", "# Changelog\n\nSomething else first.\n\n")

    expected = f'{MCP}: does not open with "Notable changes to `LibTmuxMCP`."'
    assert expected in failures(tree)


def target_start(text: str, target: str) -> int:
    """Return where the manifest declares the target called `target`."""
    found = re.search(rf'\.target\(\s*name: "{target}"', text)
    assert found
    return found.start()


@pytest.mark.parametrize("target", ["TmuxWorkspace", "LibTmuxMCP"])
def test_a_target_that_does_not_exclude_its_changelog_is_reported(
    tree: Path, target: str
) -> None:
    """A target whose manifest entry stops naming its changelog is named."""
    manifest = tree / "Package.swift"
    text = manifest.read_text(encoding="utf-8")
    end = text.index("exclude:", target_start(text, target))
    broken = text[:end] + text[end:].replace('"CHANGELOG.md", ', "", 1)
    assert broken != text
    manifest.write_text(broken, encoding="utf-8")

    needle = f"target {target} does not exclude CHANGELOG.md"
    assert any(needle in line for line in failures(tree))


def test_a_commented_out_exclude_excludes_nothing(tree: Path) -> None:
    """A line of Swift comment is not a manifest entry."""
    manifest = tree / "Package.swift"
    text = manifest.read_text(encoding="utf-8")
    start = target_start(text, "TmuxWorkspace")
    end = text.index("exclude:", start)
    line_end = text.index("\n", end)
    # The real line is commented out, and a live one without the changelog follows.
    manifest.write_text(
        text[:end]
        + "// "
        + text[end:line_end]
        + '\n            exclude: ["README.md"]'
        + text[line_end:],
        encoding="utf-8",
    )

    needle = "target TmuxWorkspace does not exclude CHANGELOG.md"
    assert any(needle in line for line in failures(tree))


def test_a_product_that_lists_other_releases_is_reported(tree: Path) -> None:
    """The products share one version, so every file lists the same releases."""
    edit(tree / MCP, "## [0.1.0] - ", "## [0.1.0-draft] - ")

    assert any(
        "lists different releases than CHANGELOG.md" in line for line in failures(tree)
    )


def test_notes_put_each_products_section_under_its_name(tree: Path) -> None:
    """The root section comes first, then each product's under a heading."""
    text = GATE["notes"](tree, "0.1.1")

    assert text.startswith("### Added\n")
    assert "\n### TmuxWorkspace\n\n#### Changed\n" in text
    assert "\n### LibTmuxMCP\n\n#### Changed\n" in text
    assert "No entries for" not in text


def test_notes_skip_a_product_with_no_entries(tree: Path) -> None:
    """A release with nothing for a product leaves it out of the body."""
    text = GATE["notes"](tree, "0.1.0")

    assert "### TmuxWorkspace" not in text
    assert "### LibTmuxMCP" not in text
    assert "No entries for" not in text


def test_notes_keep_fenced_code(tree: Path) -> None:
    """A code block in an entry reaches the release body with its lines."""
    edit(
        tree / "CHANGELOG.md",
        "## [0.1.0] - 2026-10-25\n",
        "## [0.1.0] - 2026-10-25\n\n```swift\nlet x = 1\n```\n",
    )

    text = GATE["notes"](tree, "0.1.0")

    assert "```swift\nlet x = 1\n```" in text


def test_notes_demote_only_real_headings(tree: Path) -> None:
    """A heading-shaped line inside a fence of a product's section stays as is."""
    edit(
        tree / WORKSPACE,
        "### Changed\n",
        "### Changed\n\n```md\n### not a heading\n```\n",
    )

    text = GATE["notes"](tree, "0.1.1")

    assert "\n### not a heading\n" in text
    assert "#### not a heading" not in text
    assert "\n#### Changed\n" in text


def test_notes_refuse_a_version_no_changelog_describes(tree: Path) -> None:
    """A version no file has a section for is refused, not published empty."""
    with pytest.raises(ValueError, match=re.escape("has no section for 9.9.9")):
        GATE["notes"](tree, "9.9.9")


def test_notes_refuse_a_release_with_nothing_in_any_changelog(tree: Path) -> None:
    """A release that says nothing anywhere fails instead of publishing a blank."""
    for path in PRODUCTS.values():
        file = tree / path
        lines = file.read_text(encoding="utf-8").split("\n")
        start = next(i for i, line in enumerate(lines) if line.startswith("## [0.1.1]"))
        stop = next(
            i for i, line in enumerate(lines) if i > start and line.startswith("## [")
        )
        file.write_text("\n".join([*lines[: start + 1], "", *lines[stop:]]), "utf-8")

    with pytest.raises(ValueError, match=re.escape("no entries for 0.1.1")):
        GATE["notes"](tree, "0.1.1")


def test_notes_refuse_a_tree_that_fails_the_check(tree: Path) -> None:
    """The notes are never built from files the check would reject."""
    (tree / MCP).unlink()

    with pytest.raises(ValueError, match="every product needs a changelog"):
        GATE["notes"](tree, "0.1.1")
