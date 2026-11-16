"""Tests for the check that `Package.resolved` keeps the Yams pin."""

import json
import subprocess
import sys
from pathlib import Path

import check_resolved_pins
import pytest

SCRIPT = Path(__file__).parents[1] / "check_resolved_pins.py"


def resolved(tmp_path: Path, document: object) -> Path:
    """Write `document` as a `Package.resolved` and return its path."""
    path = tmp_path / "Package.resolved"
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def test_a_file_with_the_pin_passes(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Yams among other pins is the committed state."""
    path = resolved(
        tmp_path, {"pins": [{"identity": "other"}, {"identity": "yams"}], "version": 3}
    )

    assert check_resolved_pins.main([str(path)]) == 0
    assert "pins yams" in capsys.readouterr().out


@pytest.mark.parametrize(
    "document",
    [
        {"pins": [{"identity": "other"}]},
        {"pins": []},
        {"pins": [{"identity": "Yams"}]},
        {"pins": "yams"},
        {},
        [],
    ],
)
def test_a_file_without_the_pin_fails(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], document: object
) -> None:
    """A trait-off resolve that dropped the pin is what this catches."""
    assert check_resolved_pins.main([str(resolved(tmp_path, document))]) == 1
    assert "no longer pins yams" in capsys.readouterr().err


def test_a_file_that_is_not_json_fails(tmp_path: Path) -> None:
    """A file that is not JSON cannot vouch for the pin."""
    path = tmp_path / "Package.resolved"
    path.write_text("{", encoding="utf-8")

    assert check_resolved_pins.main([str(path)]) == 2
    assert check_resolved_pins.main([str(tmp_path / "missing")]) == 2


def test_the_command_line_reads_the_file_in_the_working_directory(
    tmp_path: Path,
) -> None:
    """With no argument the script reads `Package.resolved` where it runs."""
    resolved(tmp_path, {"pins": [{"identity": "yams"}]})

    finished = subprocess.run(
        [sys.executable, str(SCRIPT)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )

    assert finished.returncode == 0, finished.stderr
