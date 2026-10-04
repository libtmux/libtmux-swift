"""Tests for the suite time-limit gate."""

from __future__ import annotations

import runpy
from pathlib import Path

CHECK = runpy.run_path(Path(__file__).parents[1] / "check_time_limits.py")

SHORT_LIMITS = CHECK["short_limits"]


def test_a_one_minute_limit_is_refused() -> None:
    """The limit that failed unrelated cases under load is what the gate names."""
    source = '@Suite("x", .timeLimit(.minutes(1)))\n'

    assert SHORT_LIMITS(source) == [(1, 60)]


def test_a_five_minute_backstop_and_a_ten_minute_one_pass() -> None:
    """The control: the documented backstop is not reported."""
    source = (
        '@Suite("a", .timeLimit(.minutes(5)))\n@Suite("b", .timeLimit(.minutes(10)))\n'
    )

    assert SHORT_LIMITS(source) == []
