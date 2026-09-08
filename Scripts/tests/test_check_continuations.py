"""Tests for the continuation cancellation gate."""

from __future__ import annotations

import runpy
from pathlib import Path

GATE = runpy.run_path(Path(__file__).parents[1] / "check_continuations.py")

GUARDED = """actor Doorbell {
    func wait() async -> Wake {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        } onCancel: {
            Task { await self.release() }
        }
    }
}
"""

UNGUARDED = """actor Doorbell {
    func wait() async -> Wake {
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
"""


def findings(source: str, tmp_path: Path, monkeypatch) -> list[tuple[int, str]]:
    """Scan one Swift file's worth of source, rooted at a temporary tree.

    `runpy.run_path` hands back a copy of the module namespace, so the root the
    function actually reads is the one in its own globals.
    """
    (tmp_path / "Sample.swift").write_text(source, encoding="utf-8")
    monkeypatch.setitem(GATE["unguarded"].__globals__, "ROOT", tmp_path)
    return GATE["unguarded"]("Sample.swift")


def test_a_handler_above_the_continuation_passes(tmp_path, monkeypatch) -> None:
    """The shape every guarded call in this repository is written in."""
    assert findings(GUARDED, tmp_path, monkeypatch) == []


def test_a_bare_continuation_is_reported(tmp_path, monkeypatch) -> None:
    """The defect: cancelling this resumes nothing and the caller never returns."""
    assert findings(UNGUARDED, tmp_path, monkeypatch) == [(3, "wait")]


def test_a_distant_handler_does_not_count(tmp_path, monkeypatch) -> None:
    """A handler far above may guard a sibling call rather than this one.

    Reporting it is the safe direction: the answer is to move the handler or to
    record the caller that releases the park, and both are readable decisions.
    """
    source = UNGUARDED.replace(
        "    func wait() async -> Wake {\n",
        "    func wait() async -> Wake {\n"
        "        await withTaskCancellationHandler { await other() }\n"
        "        // four\n        // lines\n        // of\n        // distance\n",
    )

    assert findings(source, tmp_path, monkeypatch) == [(8, "wait")]


def test_the_finding_names_the_function_not_the_line(tmp_path, monkeypatch) -> None:
    """The allowlist keys on the name, so edits above a park are not findings."""
    padded = "// a comment\n" * 5 + UNGUARDED

    assert findings(padded, tmp_path, monkeypatch)[0][1] == "wait"
