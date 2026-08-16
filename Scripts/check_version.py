#!/usr/bin/env python3
"""Require every version this package claims to be the one it is.

`LibTmuxVersion.current` is the source. A reader is told to depend on an exact
version, because every tag until 0.1.0 is a prerelease and SwiftPM will not
resolve one from a range — so each `exact:` pin in the documentation is a claim
about which tag exists, and a stale one sends a reader to a version that does
not.

    python3 Scripts/check_version.py

The tag itself is checked at release time rather than here: this runs on a
working tree that has no tag yet, and the workflow that cuts the release is
where a mismatch has to stop something.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Sources/LibTmux/LibTmuxVersion.swift"

DECLARED = re.compile(r'static let current = "([^"]+)"')
PIN = re.compile(r'exact:\s*"([^"]+)"')


def declared_version() -> str:
    """Read the version every other claim is measured against."""
    match = DECLARED.search(SOURCE.read_text())
    if match is None:
        message = f"no `static let current` in {SOURCE.relative_to(ROOT)}"
        raise SystemExit(message)
    return match.group(1)


def tracked(*patterns: str) -> list[str]:
    """List the files git knows about, so an untracked draft is not a failure."""
    listed = subprocess.run(
        ["git", "ls-files", *patterns],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in listed.splitlines() if line]


def main() -> int:
    """Report any pin that names a version this package is not."""
    version = declared_version()
    failures: list[str] = []
    pins = 0

    for relative in tracked("*.md", "*.swift"):
        if relative.startswith("dev/Spikes/"):
            continue
        for number, line in enumerate((ROOT / relative).read_text().splitlines(), 1):
            for pinned in PIN.findall(line):
                pins += 1
                if pinned != version:
                    failures.append(f"{relative}:{number}: pins {pinned}")

    if failures:
        print(f"{len(failures)} pin(s) disagree with {version}:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            f"\nEvery `exact:` pin names the version in "
            f"{SOURCE.relative_to(ROOT)}.",
            file=sys.stderr,
        )
        return 1

    print(f"{pins} pins checked; each names {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
