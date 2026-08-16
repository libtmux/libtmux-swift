#!/usr/bin/env python3
"""Require every socket this repository addresses by literal to name this port.

`AGENTS.md` states the rule in prose: a socket lives under
`/tmp/libtmux-swift-test/` or `/tmp/libtmux-swift-dev/`, never anywhere else,
because `/tmp` is shared with the other libtmux ports and a sweep by prefix in
either direction reaps the other's servers. Prose is not a gate — `libtmux-ts`
enforces the same invariant with a script, and this is the Swift half of it.

    python3 Scripts/check_socket_namespace.py

What it can and cannot see. It matches `Server(socketPath:)` and
`Server(socketName:)` given a *literal*, which is where a stray socket root gets
written down. It cannot tell a server that was addressed from one that was
started: nothing reaches the filesystem until a command runs against it, and
that is a runtime fact. So a handful of cases legitimately name a path outside
the roots and never create it — they are listed below rather than detected, the
way `check_examples.py` lists its manifest excerpts, so the next one has to be a
decision somebody made rather than a pattern somebody's file happened to match.

`dev/Spikes/` is excluded: it is scratch work that CI does not build.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The two roots AGENTS.md sanctions.
SANCTIONED = ("/tmp/libtmux-swift-test", "/tmp/libtmux-swift-dev")

# Addressed but never started, or a path the reader owns rather than one this
# repository creates. Each is a decision, not a heuristic.
ALLOWED = {
    # The documented quick start shows a reader the socket *they* would use.
    ("Examples/Sources/QuickStart/main.swift", "/tmp/work.sock"),
    # "an empty list is a no-op that never invokes tmux" — nothing is spawned.
    ("Tests/LibTmuxTests/CommandListTests.swift", "/tmp/lt-empty"),
    # Identity and equality over endpoints; no server is ever started.
    ("Tests/LibTmuxTests/ServerTests.swift", "/tmp/libtmux-value"),
}

CREATION = re.compile(r'Server\(\s*socket(?:Path|Name):\s*"([^"]*)"')


def tracked_swift_files() -> list[str]:
    """List every Swift file git knows about.

    An untracked scratch file is therefore not a failure, and a committed one
    is.
    """
    listed = subprocess.run(
        ["git", "ls-files", "*.swift"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in listed.splitlines() if line]


def main() -> int:
    """Report any addressed socket that neither names this port nor is allowed."""
    failures: list[str] = []
    checked = 0

    for relative in tracked_swift_files():
        if relative.startswith("dev/Spikes/"):
            continue
        checked += 1
        path = ROOT / relative
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            for literal in CREATION.findall(line):
                if literal.startswith(SANCTIONED):
                    continue
                if (relative, literal) in ALLOWED:
                    continue
                failures.append(f"{relative}:{number}: {literal}")

    if failures:
        print(
            f"{len(failures)} socket(s) addressed outside this port's roots:",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nEvery socket belongs under /tmp/libtmux-swift-test/ (suites) or"
            "\n/tmp/libtmux-swift-dev/ (by hand). If this one is addressed but"
            "\nnever started, add it to ALLOWED with the reason. See AGENTS.md.",
            file=sys.stderr,
        )
        return 1

    print(f"{checked} Swift files checked; every socket names this port")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
