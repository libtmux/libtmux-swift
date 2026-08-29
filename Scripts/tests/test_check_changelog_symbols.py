"""Tests for the changelog symbol gate."""

from __future__ import annotations

import runpy
from pathlib import Path

GATE = runpy.run_path(Path(__file__).parents[1] / "check_changelog_symbols.py")


def declarations(source: str, tmp_path: Path) -> dict[str, set[str]]:
    """Scan one Swift file's worth of source."""
    (tmp_path / "Sample.swift").write_text(source, encoding="utf-8")
    return GATE["declarations"](tmp_path)


def test_a_method_is_owned_by_its_type(tmp_path: Path) -> None:
    """The owner is what a wrong attribution gets wrong, so record it."""
    members = declarations(
        "public struct Result {\n    public let count: Int\n}\n"
        "public enum Finder {\n    public static func find() {}\n}\n",
        tmp_path,
    )

    assert "find" in members["Finder"]
    assert "find" not in members["Result"]


def test_a_nested_type_belongs_to_the_type_around_it(tmp_path: Path) -> None:
    """`Outcome` is reached as `Wait.Outcome`, not on its own."""
    members = declarations(
        "public struct Wait {\n    public enum Outcome {\n"
        "        case done\n    }\n}\n",
        tmp_path,
    )

    assert "Outcome" in members["Wait"]
    assert "done" in members["Outcome"]


def test_an_extension_adds_to_the_type_it_extends(tmp_path: Path) -> None:
    """Most of this package's API arrives through extensions."""
    members = declarations(
        "public struct Server {}\n"
        "extension Server {\n    public func sessions() {}\n}\n",
        tmp_path,
    )

    assert "sessions" in members["Server"]
