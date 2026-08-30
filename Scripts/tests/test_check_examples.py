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
