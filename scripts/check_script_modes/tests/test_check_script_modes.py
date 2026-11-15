"""Tests for the gate that holds shebanged files to the executable mode."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).parents[1] / "check_script_modes.py"

SHEBANG = "#!/bin/sh\necho hello\n"


def run_gate(
    tmp_path: Path, files: dict[str, str], executable: set[str]
) -> subprocess.CompletedProcess[str]:
    """Run the gate over a temporary repository that tracks `files`.

    The gate reads the mode git recorded, so each file is added to the index
    and the names in `executable` are recorded as 100755.
    """
    copied = tmp_path / "scripts" / "check_script_modes" / SCRIPT.name
    copied.parent.mkdir(parents=True)
    shutil.copy(SCRIPT, copied)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    for name, text in files.items():
        (tmp_path / name).write_text(text, encoding="utf-8")
        subprocess.run(["git", "add", name], cwd=tmp_path, check=True)
    for name in executable:
        subprocess.run(
            ["git", "update-index", "--chmod=+x", name], cwd=tmp_path, check=True
        )
    return subprocess.run(
        [sys.executable, str(copied)], capture_output=True, text=True, check=False
    )


def test_the_repository_passes() -> None:
    """Every shebanged file tracked here is recorded executable."""
    finished = subprocess.run(
        [sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False
    )

    assert finished.returncode == 0, finished.stderr
    assert "each is executable" in finished.stdout


def test_a_shebanged_file_recorded_as_plain_fails(tmp_path: Path) -> None:
    """The defect: a script CI invokes directly that git recorded as 100644."""
    finished = run_gate(tmp_path, {"run.sh": SHEBANG}, executable=set())

    assert finished.returncode == 1
    assert "run.sh: recorded 100644, wanted 100755" in finished.stderr


def test_the_same_file_recorded_executable_passes(tmp_path: Path) -> None:
    """Control: only the recorded mode differs from the failing case."""
    finished = run_gate(tmp_path, {"run.sh": SHEBANG}, executable={"run.sh"})

    assert finished.returncode == 0, finished.stderr
    assert "1 shebanged files checked" in finished.stdout


def test_a_file_without_a_shebang_is_not_a_script(tmp_path: Path) -> None:
    """A document that happens to be a plain file is none of this gate's business."""
    finished = run_gate(tmp_path, {"notes.txt": "hello\n"}, executable=set())

    assert finished.returncode == 0, finished.stderr
    assert "0 shebanged files checked" in finished.stdout


def test_a_symlink_is_skipped(tmp_path: Path) -> None:
    """A symlink's own bytes are its target path, not a shebang."""
    (tmp_path / "real.sh").write_text(SHEBANG, encoding="utf-8")
    (tmp_path / "link.sh").symlink_to("real.sh")
    copied = tmp_path / "scripts" / "check_script_modes" / SCRIPT.name
    copied.parent.mkdir(parents=True)
    shutil.copy(SCRIPT, copied)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "link.sh", "real.sh"], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "update-index", "--chmod=+x", "real.sh"], cwd=tmp_path, check=True
    )

    finished = subprocess.run(
        [sys.executable, str(copied)], capture_output=True, text=True, check=False
    )

    assert finished.returncode == 0, finished.stderr
