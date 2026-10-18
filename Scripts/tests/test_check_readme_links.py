"""Tests for the README link gate."""

from __future__ import annotations

import runpy
from pathlib import Path

CHECK = runpy.run_path(Path(__file__).parents[1] / "check_readme_links.py")

check = CHECK["check"]
ROOT = CHECK["ROOT"]
SITE = CHECK["SITE"]
TREE_URL = "https://github.com/libtmux/libtmux-swift/tree/master"

REQUIRED = {"reference/": ["server"]}

GOOD = f"""\
# Project

## Products

### [`LibTmux`][dir-libtmux]: the library

A [`Server`][api-server] lists sessions. Start with [Products](#products), or
call [`list_sessions`].

[dir-libtmux]: {TREE_URL}/Sources/LibTmux
[api-server]: {SITE}reference/server/
[`list_sessions`]: {SITE}mcp/tools/list_sessions/
"""


def repository(tmp_path: Path, readme: str = GOOD) -> Path:
    """Build the smallest tree the gate can read, with `readme` at its root."""
    library = tmp_path / "Sources/LibTmux"
    library.mkdir(parents=True)
    (library / "Server.swift").write_text("public struct Server {}\n")
    (library / "README.md").write_text(GOOD)
    tools = tmp_path / "Sources/LibTmuxMCP"
    tools.mkdir(parents=True)
    (tools / "ToolOperation.swift").write_text(
        'public enum ToolOperation {\n    case listSessions = "list_sessions"\n}\n',
    )
    (tmp_path / "README.md").write_text(readme)
    return tmp_path


def problems(tmp_path: Path, readme: str) -> list[str]:
    """Check a tree whose root README is `readme`."""
    return check(repository(tmp_path, readme), REQUIRED)


def test_a_good_tree_passes(tmp_path: Path) -> None:
    """The control every failure below is measured against."""
    assert problems(tmp_path, GOOD) == []


def test_the_repository_passes() -> None:
    """The READMEs shipped here hold to their own gate."""
    assert check(ROOT) == []


def test_a_directory_link_to_nothing_is_reported(tmp_path: Path) -> None:
    """A product directory that moved leaves its heading pointing nowhere."""
    broken = GOOD.replace("Sources/LibTmux", "Sources/LibTmuxx")

    found = problems(tmp_path, broken)

    assert any("Sources/LibTmuxx names no path" in line for line in found)
    assert any("no heading links" in line for line in found)


def test_an_api_page_for_a_missing_symbol_is_reported(tmp_path: Path) -> None:
    """A renamed type leaves its page link naming a symbol that is gone."""
    broken = GOOD.replace("reference/server/", "reference/servers/")

    found = problems(tmp_path, broken)

    assert any("servers/ names no public symbol" in line for line in found)


def test_a_member_page_is_held_to_its_type(tmp_path: Path) -> None:
    """A member page leads with the symbol that owns it."""
    member = GOOD + f"[`x`]: <{SITE}reference/server-sessions()/>\n"
    orphan = GOOD + f"[`y`]: <{SITE}reference/servers-sessions()/>\n"

    assert problems(tmp_path / "a", member) == []
    assert any(
        "names no public symbol" in line for line in problems(tmp_path / "b", orphan)
    )


def test_a_tool_page_for_a_missing_tool_is_reported(tmp_path: Path) -> None:
    """A renamed tool leaves its page link naming a tool that is gone."""
    broken = GOOD.replace("list_sessions/", "list_session/")

    found = problems(tmp_path, broken)

    assert any("names no tool in ToolOperation" in line for line in found)


def test_a_reference_with_no_definition_is_reported(tmp_path: Path) -> None:
    """An undefined label renders as bracketed text, not a link."""
    broken = GOOD.replace("[api-server]: ", "[api-servers]: ")

    found = problems(tmp_path, broken)

    assert any("[api-server] has no definition" in line for line in found)


def test_a_fragment_that_names_no_heading_is_reported(tmp_path: Path) -> None:
    """Renaming a heading breaks every link to its anchor."""
    broken = GOOD.replace("(#products)", "(#product)")

    found = problems(tmp_path, broken)

    assert any("#product names no heading" in line for line in found)


def test_a_missing_required_api_link_is_reported(tmp_path: Path) -> None:
    """The root README has to link the types a reader meets first."""
    broken = GOOD.replace("[`Server`][api-server]", "`Server`")

    found = problems(tmp_path, broken)

    assert any(f"never links {SITE}reference/server/" in line for line in found)


def test_a_link_inside_a_code_fence_is_not_read(tmp_path: Path) -> None:
    """Fenced text is an example, not a link."""
    fenced = GOOD + "\n```\n[x](./nowhere.md)\n```\n"

    assert problems(tmp_path, fenced) == []
