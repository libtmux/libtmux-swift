#!/usr/bin/env python3
"""Require every version this package claims to be the one it is.

`LibTmuxVersion.current` is the source. A reader is told to depend on an exact
version, because every tag until 0.1.0 is a prerelease and SwiftPM will not
resolve one from a range — so each `exact:` pin in the documentation is a claim
about which tag exists, and a stale one sends a reader to a version that does
not.

Only pins naming this repository are that claim. A nested package pinning a
third-party dependency is held at its own upstream version, and passes through.

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
URL = re.compile(r'url:\s*"([^"]+)"')
PACKAGE = re.compile(r"\.package\(")

# The repository a documentation pin is a claim about. A manifest pinning a
# third-party dependency exactly makes a different claim -- which upstream
# release that dependency is held at -- and this gate is not the one that
# checks it. A pin outside any `.package(` block is still checked, because a
# loose `exact:` in prose is telling a reader which tag to depend on.
OWN_PACKAGE = "libtmux/libtmux-swift"


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


def own_pins(text: str) -> list[tuple[int, str]]:
    """List every `exact:` pin in `text` that is a claim about this package.

    A pin's subject is the `url:` of the `.package(` block enclosing it, so a
    nested manifest holding a third-party dependency at its own upstream
    version is not reported. A pin with no enclosing block is reported: a loose
    `exact:` in prose is still telling a reader which tag to depend on.
    """
    found: list[tuple[int, str]] = []
    subject: str | None = None

    for number, line in enumerate(text.splitlines(), 1):
        if PACKAGE.search(line):
            subject = None
        url = URL.search(line)
        if url is not None:
            subject = url.group(1)
        for pinned in PIN.findall(line):
            if subject is not None and OWN_PACKAGE not in subject:
                continue
            found.append((number, pinned))

    return found


def main() -> int:
    """Report any pin that names a version this package is not."""
    version = declared_version()
    failures: list[str] = []
    pins = 0

    for relative in tracked("*.md", "*.swift"):
        if relative.startswith("dev/Spikes/"):
            continue
        for number, pinned in own_pins((ROOT / relative).read_text()):
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
