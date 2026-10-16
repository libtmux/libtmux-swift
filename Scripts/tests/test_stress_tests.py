"""Tests for the stress runner's reading of Swift Testing output."""

from __future__ import annotations

import runpy
from collections import defaultdict
from pathlib import Path

STRESS = runpy.run_path(Path(__file__).parents[1] / "stress_tests.py")

SCORE = STRESS["score"]
COUNT = STRESS["Count"]

LOG = """\
◇ Test "steady" started.
✔ Test "steady" passed after 0.1 seconds.
◇ Test "flaky" started.
✘ Test "flaky" recorded an issue at A.swift:1:1: bad
✘ Test "flaky" failed after 0.2 seconds with 1 issue.
◇ Test "parked" started.
"""


def test_failed_and_hung_tests_are_counted_and_a_passing_one_is_not() -> None:
    """A recorded issue counts once, and only a killed run leaves a hung test."""
    counts = defaultdict(COUNT)

    SCORE(LOG, True, counts)

    assert (counts['"flaky"'].failed, counts['"flaky"'].hung) == (1, 0)
    assert (counts['"parked"'].failed, counts['"parked"'].hung) == (0, 1)
    assert (counts['"steady"'].failed, counts['"steady"'].hung) == (0, 0)


def test_an_unfinished_test_in_a_run_that_exited_is_not_hung() -> None:
    """Hung means the guard killed the run, not that the log ends early."""
    counts = defaultdict(COUNT)

    SCORE(LOG, False, counts)

    assert counts['"parked"'].hung == 0
