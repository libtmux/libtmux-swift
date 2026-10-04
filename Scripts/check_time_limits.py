#!/usr/bin/env python3
"""Require every suite `.timeLimit` to be a backstop of at least five minutes.

`CONTRIBUTING.md` sizes the limit against the queue a test waits in, not
against the work it does: every tmux command spawns through swift-subprocess,
which forks on one worker thread for the whole test process, so a case that
is quick alone can report much longer inside the suite.
A short limit fails unrelated cases on every platform, and the
failure reads as a hang in whichever test the queue happened to reach.

    python3 Scripts/check_time_limits.py

It reads `.timeLimit(.minutes(N))` and `.timeLimit(.seconds(N))` under `Tests/`
and `Examples/Tests/`. A limit written some other way is not seen.
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

MINIMUM_SECONDS = 300
LIMIT = re.compile(r"\.timeLimit\(\s*\.(minutes|seconds)\((\d+)\)\s*\)")


def short_limits(source: str) -> list[tuple[int, int]]:
    """Return the line and length in seconds of every limit under the minimum."""
    found: list[tuple[int, int]] = []
    for number, line in enumerate(source.splitlines(), start=1):
        for unit, amount in LIMIT.findall(line):
            seconds = int(amount) * (60 if unit == "minutes" else 1)
            if seconds < MINIMUM_SECONDS:
                found.append((number, seconds))
    return found


def main() -> int:
    """Report each short limit and exit 1 if there are any."""
    failures = 0
    for directory in ("Tests", "Examples/Tests"):
        for path in sorted((ROOT / directory).rglob("*.swift")):
            for number, seconds in short_limits(path.read_text()):
                relative = path.relative_to(ROOT)
                print(f"{relative}:{number}: .timeLimit of {seconds}s is under 300s")
                failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
