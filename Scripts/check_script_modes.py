#!/usr/bin/env python3
"""Require every tracked file with a shebang to be executable in git.

A shebang on a file nothing can run is a script that only works when someone
remembers to say `python3` in front of it. Ruff reports this as EXE001 on the
runner but not reliably on a developer machine, so this gate exists rather than
deferring to it.

It reads the mode git *recorded*, which is what a checkout produces and
therefore what CI lints, rather than the mode this working tree happens to have.
The two differ whenever `core.fileMode` is off or a file arrives through a
patch.

    python3 Scripts/check_script_modes.py
"""

from __future__ import annotations

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

EXECUTABLE = "100755"


def tracked() -> list[tuple[str, str]]:
    """Return every tracked file as its recorded mode and path."""
    listed = subprocess.run(
        ["git", "ls-files", "-s"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    entries: list[tuple[str, str]] = []
    for line in listed.splitlines():
        if not line:
            continue
        # `<mode> <object> <stage>\t<path>`
        meta, _, path = line.partition("\t")
        entries.append((meta.split()[0], path))
    return entries


def main() -> int:
    """Report any shebanged file git records as non-executable."""
    failures: list[str] = []
    checked = 0

    for mode, path in tracked():
        # A symlink's own bytes are its target, not a script.
        if mode == "120000":
            continue
        full = ROOT / path
        try:
            first = full.read_bytes()[:2]
        except OSError:
            continue
        if first != b"#!":
            continue
        checked += 1
        if mode != EXECUTABLE:
            failures.append(f"{path}: recorded {mode}, wanted {EXECUTABLE}")

    if failures:
        print(
            f"{len(failures)} shebanged file(s) git records as non-executable:",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print("\nFix with: chmod +x <path> && git add <path>", file=sys.stderr)
        return 1

    print(f"{checked} shebanged files checked; each is executable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
