"""Tests for the generator that splices benchmark tables into the documents."""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

import pytest
import update_mode_matrix as matrix

BENCHMARK = """<!-- section: modes -->
| mode | processes |
| --- | --- |
| argv | 7 |

<!-- section: noticing -->
| route | round trips |
| --- | --- |
| poll | 3 |
"""

PAGE = """# Page

<!-- mode-matrix:start -->

old table

<!-- mode-matrix:end -->

after
"""


class Benchmark:
    """A stand-in for `swift run ... libtmux-bench --markdown`."""

    def __init__(self, stdout: str, returncode: int = 0) -> None:
        """Remember what the benchmark prints and how it exits."""
        self.stdout = stdout
        self.returncode = returncode
        self.stderr = "the counts varied between runs\n"


def fake_run(stdout: str, returncode: int = 0) -> Callable[..., Benchmark]:
    """Return a `subprocess.run` that answers as the benchmark would."""

    def run(*_arguments: object, **_options: object) -> Benchmark:
        return Benchmark(stdout, returncode)

    return run


@pytest.fixture
def page(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Point the generator at one page and one benchmark output."""
    target = tmp_path / "Page.md"
    target.write_text(PAGE, encoding="utf-8")
    monkeypatch.setattr(
        matrix, "TARGETS", {target: ("mode-matrix", ("modes", "noticing"))}
    )
    monkeypatch.setattr(subprocess, "run", fake_run(BENCHMARK))
    monkeypatch.setattr(sys, "argv", ["update_mode_matrix.py"])
    return target


def test_the_tables_are_read_by_section_name(monkeypatch: pytest.MonkeyPatch) -> None:
    """Each `<!-- section: name -->` starts a table, and blank lines are dropped."""
    monkeypatch.setattr(subprocess, "run", fake_run(BENCHMARK))

    assert matrix.measured() == {
        "modes": "| mode | processes |\n| --- | --- |\n| argv | 7 |",
        "noticing": "| route | round trips |\n| --- | --- |\n| poll | 3 |",
    }


def test_a_benchmark_that_fails_stops_the_run(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The benchmark's own reason reaches the caller, not a bare traceback."""
    monkeypatch.setattr(subprocess, "run", fake_run("", returncode=2))

    with pytest.raises(SystemExit) as stopped:
        matrix.measured()

    assert stopped.value.code == 1
    assert "the counts varied between runs" in capsys.readouterr().err


def test_splicing_replaces_only_what_the_markers_enclose() -> None:
    """Text outside the markers is returned exactly as it was."""
    result = matrix.spliced(PAGE, "mode-matrix", "new table")

    assert result.startswith("# Page\n\n<!-- mode-matrix:start -->\n\nnew table\n\n")
    assert result.endswith("<!-- mode-matrix:end -->\n\nafter\n")
    assert "old table" not in result


def test_check_names_a_stale_page_and_leaves_it_alone(
    page: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """`--check` is the CI gate: stale means a failing exit and no rewrite."""
    monkeypatch.setattr(sys, "argv", ["update_mode_matrix.py", "--check"])

    assert matrix.main() == 1
    assert "stale in Page.md" in capsys.readouterr().err
    assert page.read_text(encoding="utf-8") == PAGE


def test_a_rewrite_makes_the_check_pass(
    page: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The documented loop: rewrite, then the same benchmark output checks clean."""
    assert matrix.main() == 0
    assert "| argv | 7 |" in page.read_text(encoding="utf-8")
    assert matrix.HEADER in page.read_text(encoding="utf-8")

    monkeypatch.setattr(sys, "argv", ["update_mode_matrix.py", "--check"])
    assert matrix.main() == 0


def test_a_page_without_its_markers_is_refused(
    page: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A page that lost a marker cannot be spliced, so nothing is guessed."""
    page.write_text("# Page\n", encoding="utf-8")

    assert matrix.main() == 1
    assert "no mode-matrix:start marker" in capsys.readouterr().err


def test_a_missing_table_is_reported(
    page: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A benchmark that stopped printing a table the page needs fails the run."""
    monkeypatch.setattr(subprocess, "run", fake_run("<!-- section: modes -->\n| a |\n"))

    assert matrix.main() == 1
    assert "no noticing table" in capsys.readouterr().err
