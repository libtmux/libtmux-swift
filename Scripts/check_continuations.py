#!/usr/bin/env python3
"""Require every suspended continuation in `Sources/` to answer cancellation.

A continuation nobody resumes is not a slow call, it is a call that never
returns. Cancellation does not reach it on its own: `Task.cancel()` sets a flag
and resumes nothing, so a caller parked in `withCheckedContinuation` stays
parked for as long as the process lives.

That failure hides, because the usual ways of bounding a wait cannot end it.
Swift Testing's `.timeLimit` cancels the case and then waits for it to return,
so a parked continuation turns a slow test into a run that cannot finish: one
CI lane spent six hours there and was killed with no failure to read. A
deadline inside the library has the same shape. The gate exists because the
symptom points at whatever was scheduled next rather than at the park.

    python3 Scripts/check_continuations.py

What it can and cannot see. It requires `withTaskCancellationHandler` to open
within a few lines above the continuation, which is how every guarded call in
this repository is written. It cannot follow a handler installed further away,
and it cannot see one installed by the *caller* — releasing the park from the
call site is legitimate, and `OrderedOutbound` does exactly that. Those are
listed below with the code that releases them, so each is a decision on the
record rather than a shape that happens to pass.

`Tests/` is not scanned. A test that parks fails itself; this is about the
library, where the caller is someone else's program.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

CONTINUATION = re.compile(r"\bwith(?:Checked|Unsafe)(?:Throwing)?Continuation\b")
HANDLER = re.compile(r"\bwithTaskCancellationHandler\b")
DECLARATION = re.compile(r"^\s*(?:@\w+\s+)*(?:\w+\s+)*(?:func|var)\s+(\w+)")

# How far above a continuation its handler may open. Every guarded call in this
# repository opens one on the line immediately above; three lines allows for an
# argument list without allowing a handler from an unrelated scope to count.
HANDLER_REACH = 3

# Continuations released by their caller rather than by a handler of their own.
# Each names the code that resumes it, because that is the thing a reviewer has
# to check when either side changes.
ALLOWED = {
    (
        "Sources/LibTmuxMCP/OrderedOutbound.swift",
        "enqueue",
    ): "OrderedOutbound.cancel() resumes it, and Serve.serveUntilWriteFails\n"
    "calls that from its own onCancel",
    (
        "Sources/LibTmuxMCP/OrderedOutbound.swift",
        "writeAndWait",
    ): "same as enqueue: cancel() resumes every pending submission",
    (
        "Sources/LibTmuxMCP/OrderedOutbound.swift",
        "next",
    ): "same as enqueue: cancel() resumes the parked receiver with nil",
    (
        "Sources/TmuxWorkspace/WorkspaceBuilder.swift",
        "value",
    ): "RollbackRaceGate is bounded by a detached deadline task that always\n"
    "fires, so the wait ends at `timeout` whether or not anything is cancelled",
}


def tracked_swift_sources() -> list[str]:
    """List the Swift files under `Sources/` that git knows about.

    Tracking is the filter so an untracked scratch file is not a failure and a
    committed one is.
    """
    listed = subprocess.run(
        ["git", "ls-files", "-z", "Sources/*.swift", "Sources/**/*.swift"],
        cwd=ROOT,
        capture_output=True,
        check=True,
        text=True,
    )
    return sorted({name for name in listed.stdout.split("\0") if name})


def enclosing_name(lines: list[str], index: int) -> str:
    """Name the `func` or `var` a line sits in, searching upward.

    The name is what the allowlist is keyed on. Keying on a line number would
    make every edit above a continuation look like a new finding.
    """
    for line in reversed(lines[: index + 1]):
        found = DECLARATION.match(line)
        if found:
            return found.group(1)
    return "<file scope>"


def unguarded(path: str) -> list[tuple[int, str]]:
    """Report each continuation in `path` with no handler above it."""
    lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
    findings = []
    for index, line in enumerate(lines):
        if not CONTINUATION.search(line):
            continue
        window = lines[max(0, index - HANDLER_REACH) : index + 1]
        if any(HANDLER.search(above) for above in window):
            continue
        name = enclosing_name(lines, index)
        if (path, name) in ALLOWED:
            continue
        findings.append((index + 1, name))
    return findings


def main() -> int:
    """Report every unguarded continuation, and exit non-zero if any remain."""
    findings = [
        (path, line, name)
        for path in tracked_swift_sources()
        for line, name in unguarded(path)
    ]
    if findings:
        for path, line, name in findings:
            print(
                f"{path}:{line}: `{name}` suspends a continuation with no "
                f"withTaskCancellationHandler within {HANDLER_REACH} lines. "
                f"Cancelling it would resume nothing, and the caller would "
                f"never return. Add a handler that resumes the parked "
                f"continuation, or record here why the caller releases it.",
            )
        return 1

    scanned = len(tracked_swift_sources())
    print(
        f"{scanned} Swift sources checked; "
        f"every suspended continuation answers cancellation "
        f"({len(ALLOWED)} released by their caller)",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
