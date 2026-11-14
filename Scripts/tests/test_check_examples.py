"""Tests for documented example coverage."""

from __future__ import annotations

import runpy
from pathlib import Path

CHECK_EXAMPLES = runpy.run_path(Path(__file__).parents[1] / "check_examples.py")


def test_product_readmes_are_scanned() -> None:
    """Keep every product's reader-facing Swift inside the example gate."""
    readmes = set((CHECK_EXAMPLES["ROOT"] / "Sources").glob("*/README.md"))

    assert readmes
    assert readmes <= set(CHECK_EXAMPLES["DOCUMENTS"])


WRITTEN = {
    "Listing": [
        "public func listing(_ server: Server) async throws {",
        "    work()",
        "}",
    ],
    "Other": ["let value = 1"],
}
IMPORTS = {"Listing": {"import LibTmux"}, "Other": set()}


def homes(*lines: str) -> list[str]:
    """Return the examples the check finds for a block of these lines."""
    return CHECK_EXAMPLES["homes_of"](list(lines), WRITTEN, IMPORTS)


def test_a_block_may_open_with_the_imports_of_its_file() -> None:
    """A reader can paste a block that starts with the import it needs."""
    assert homes("import LibTmux", "", "work()") == ["Listing"]
    assert homes("import LibTmux", "work()") == ["Listing"]


def test_an_import_the_file_does_not_make_is_refused() -> None:
    """An import that no example makes cannot compile, so it is not accepted."""
    assert homes("import TmuxFixture", "", "work()") == []
    assert homes("import LibTmux", "import TmuxFixture", "", "work()") == []


def test_imports_do_not_vouch_for_code_that_is_not_there() -> None:
    """The lines after the imports still have to be in an example."""
    assert homes("import LibTmux", "", "somethingElse()") == []
    assert homes("import LibTmux") == []
