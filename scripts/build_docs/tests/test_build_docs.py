"""Tests for the DocC build that fails on a warning."""

import sys
from pathlib import Path

import build_docs
import pytest


def fake(output: str, status: int = 0) -> "build_docs.Callable[[str], list[str]]":
    """Return a command factory whose build prints `output` and exits `status`."""

    def command(target: str) -> list[str]:
        script = f"import sys; print({output!r} + ' ' + {target!r}); sys.exit({status})"
        return [sys.executable, "-c", script]

    return command


def test_the_command_names_the_target_and_the_resolved_versions() -> None:
    """The build uses the committed lock, for the one target it is asked for."""
    command = build_docs.swift_command("LibTmux")

    assert command[:4] == [
        "swift",
        "package",
        "--force-resolved-versions",
        "generate-documentation",
    ]
    assert command[-2:] == ["--target", "LibTmux"]


def test_a_clean_build_passes_and_logs_every_target(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Each target's output reaches the console and the log, in order."""
    log = tmp_path / "docs.log"
    log.write_text("stale\n", encoding="utf-8")

    status = build_docs.build(["A", "B"], log, fake("built"))

    assert status == 0
    assert log.read_text(encoding="utf-8") == "built A\nbuilt B\n"
    assert capsys.readouterr().out == "built A\nbuilt B\n"


def test_a_warning_fails_with_its_context(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The failure names the warning, so the log need not be opened."""
    status = build_docs.build(
        ["A"], tmp_path / "docs.log", fake("warning: unresolved link")
    )

    assert status == 1
    assert "::error::DocC reported warnings" in capsys.readouterr().out


def test_a_failing_build_stops_with_its_own_status(tmp_path: Path) -> None:
    """A target that fails to build is not followed by the rest."""
    log = tmp_path / "docs.log"

    status = build_docs.build(["A", "B"], log, fake("broken", status=3))

    assert status == 3
    assert log.read_text(encoding="utf-8") == "broken A\n"


def test_the_report_keeps_three_lines_after_each_warning() -> None:
    """Warnings far apart are two groups, and close ones are one."""
    lines = ["a", "warning: one", "b", "c", "d", "e", "f", "warning: two", "g"]

    assert build_docs.warning_report(lines) == [
        "warning: one",
        "b",
        "c",
        "d",
        "--",
        "warning: two",
        "g",
    ]
    assert build_docs.warning_report(["warning: x", "warning: y", "z"]) == [
        "warning: x",
        "warning: y",
        "z",
    ]
    assert build_docs.warning_report(["fine", "also fine"]) == []
