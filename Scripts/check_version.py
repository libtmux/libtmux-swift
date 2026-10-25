#!/usr/bin/env python3
"""Require every version this package claims to be the one it is.

`LibTmuxVersion.current` is the source. A reader is told to depend on a
release, so each version the documentation names is a claim about which tag
exists, and a stale one sends a reader to a version that does not:

- An `exact:` pin names `LibTmuxVersion.current` itself.
- A `from:` bound names a final release, never a prerelease, and one that is
  not newer than the release `LibTmuxVersion.current` is or is heading to. A
  bound is a floor, so it stays valid as later releases ship: `from: "0.1.0"`
  passes at `0.1.0-alpha.8` and at `0.1.7`, and `from: "0.2.0"` fails at both.

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
FLOOR = re.compile(r'\bfrom:\s*"([^"]+)"')
RELEASE = re.compile(r"(\d+)\.(\d+)\.(\d+)")
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


def own_floors(text: str) -> list[tuple[int, str]]:
    """List every `from:` bound in `text` that is a claim about this package.

    Subjects are found as `own_pins` finds them, so a third-party dependency's
    bound passes through. A `from:` with no enclosing block is not reported:
    only a `.package(` block is a dependency declaration.
    """
    found: list[tuple[int, str]] = []
    subject: str | None = None

    for number, line in enumerate(text.splitlines(), 1):
        if PACKAGE.search(line):
            subject = None
        url = URL.search(line)
        if url is not None:
            subject = url.group(1)
        if subject is not None and OWN_PACKAGE in subject:
            found.extend((number, bound) for bound in FLOOR.findall(line))

    return found


def floor_problem(bound: str, version: str) -> str | None:
    """Say why `from: bound` is not a valid floor at `version`, or None."""
    floor = RELEASE.fullmatch(bound)
    if floor is None:
        return "is not a final release"
    heading = RELEASE.match(version)
    if heading is None:
        return f"cannot be compared with {version}"
    if tuple(map(int, floor.groups())) > tuple(map(int, heading.groups())):
        return f"is newer than {version}"
    return None


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
        for number, bound in own_floors((ROOT / relative).read_text()):
            pins += 1
            problem = floor_problem(bound, version)
            if problem is not None:
                failures.append(f"{relative}:{number}: from {bound} {problem}")

    if failures:
        print(f"{len(failures)} claim(s) disagree with {version}:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            f"\nEvery `exact:` pin names the version in "
            f"{SOURCE.relative_to(ROOT)}, and every `from:` bound is a final "
            f"release no newer than it.",
            file=sys.stderr,
        )
        return 1

    print(f"{pins} claims checked against {version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
