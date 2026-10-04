#!/usr/bin/env python3
r"""Repeat the real-tmux suites and count, per test, how often each one fails.

A flake is a rate, so one green run says little. This runs each lane's suite
`repeat` times under the hang guard and writes how many runs each test failed
or was still running when the guard killed the run.

    python3 Scripts/stress_tests.py --out DIR \\
        --lane examples:3.7b:/path/to/tmux:examples:15 \\
        --lane package:3.2a:/path/to/tmux:package:5

A lane is `name:tmux-label:tmux-binary:suite:repeat`, where suite is
`examples` or `package`. The result is `DIR/failures.csv`, a Markdown table
(also appended to `$GITHUB_STEP_SUMMARY` when set), and one log per run beside
the guard's samples. The exit status is 1 when any run failed.
"""

from __future__ import annotations

import argparse
import csv
import os
import pathlib
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field

ROOT = pathlib.Path(__file__).resolve().parent.parent
GUARD = ROOT / "Scripts" / "run_with_hang_guard.py"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
STARTED = re.compile(r"^◇ Test (?!run started)(.+) started\.$")
PASSED = re.compile(r"^✔ Test (.+) passed after ")
FAILED = re.compile(r"^✘ Test (.+) (?:failed after|recorded an issue)")
SKIPPED = re.compile(r"^(?:➜|↪|◇) Test (.+) (?:skipped|was skipped)")
# What a run may take before the guard samples and kills it.
LIMIT_SECONDS = {"examples": 600, "package": 1500}
# No `--no-parallel` for the examples: it is how the macOS lane runs them.
SUITES = {
    "examples": [
        "swift",
        "test",
        "--package-path",
        "Examples",
        "--force-resolved-versions",
    ],
    "package": [
        "swift",
        "test",
        "--traits",
        "YAMLWorkspaces",
        "--force-resolved-versions",
        "--no-parallel",
    ],
}


@dataclass
class Count:
    """How often one test ran, failed, and was caught mid-run by the guard."""

    runs: int = 0
    failed: int = 0
    hung: int = 0


@dataclass
class Lane:
    """One suite on one tmux build, repeated."""

    name: str
    tmux_label: str
    tmux: str
    suite: str
    repeat: int
    counts: dict[str, Count] = field(default_factory=lambda: defaultdict(Count))
    run_failures: int = 0


def score(text: str, killed: bool, counts: dict[str, Count]) -> None:
    """Add one run's per-test outcome to `counts`."""
    running: set[str] = set()
    for raw in text.splitlines():
        line = ANSI.sub("", raw).strip()
        if match := STARTED.match(line):
            running.add(match.group(1))
            counts[match.group(1)].runs += 1
        elif match := PASSED.match(line):
            running.discard(match.group(1))
        elif match := FAILED.match(line):
            if match.group(1) in running:
                counts[match.group(1)].failed += 1
                running.discard(match.group(1))
        elif match := SKIPPED.match(line):
            running.discard(match.group(1))
    if killed:
        for name in running:
            counts[name].hung += 1


def run_lane(lane: Lane, out: pathlib.Path) -> None:
    """Run the lane's suite `repeat` times, keeping each log."""
    environment = dict(os.environ, LIBTMUX_TMUX_BIN=lane.tmux, NO_COLOR="1")
    root = pathlib.Path(os.environ.get("TMUX_TMPDIR", "/tmp/libtmux-swift-test/named"))
    environment["TMUX_TMPDIR"] = str(root)
    root.mkdir(parents=True, exist_ok=True)
    for index in range(1, lane.repeat + 1):
        directory = out / f"{lane.name}-{lane.tmux_label}-{index:02d}"
        directory.mkdir(parents=True, exist_ok=True)
        command = [
            sys.executable,
            str(GUARD),
            "--seconds",
            str(LIMIT_SECONDS[lane.suite]),
            "--out",
            str(directory),
            "--",
            *SUITES[lane.suite],
        ]
        done = subprocess.run(command, cwd=ROOT, env=environment, check=False)
        text = (directory / "output.log").read_text(errors="replace")
        score(text, done.returncode == 124, lane.counts)
        if done.returncode != 0:
            lane.run_failures += 1
        print(
            f"::notice::{lane.name} tmux {lane.tmux_label} run {index}: "
            f"exit {done.returncode}"
        )


def parse_lane(spec: str) -> Lane:
    """Parse `name:tmux-label:tmux-binary:suite:repeat`."""
    name, label, tmux, suite, repeat = spec.split(":")
    if suite not in SUITES:
        message = f"unknown suite {suite!r}"
        raise argparse.ArgumentTypeError(message)
    return Lane(name, label, tmux, suite, int(repeat))


def main() -> int:
    """Run every lane and write the report."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--lane", type=parse_lane, action="append", required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    lanes: list[Lane] = args.lane
    for lane in lanes:
        run_lane(lane, args.out)

    with (args.out / "failures.csv").open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["lane", "tmux", "suite", "test", "runs", "failed", "hung"])
        for lane in lanes:
            for test, count in sorted(lane.counts.items()):
                writer.writerow(
                    [
                        lane.name,
                        lane.tmux_label,
                        lane.suite,
                        test,
                        count.runs,
                        count.failed,
                        count.hung,
                    ]
                )

    lines = [
        "| lane | tmux | suite | runs | runs not green | tests failed or hung |",
        "|---|---|---|---|---|---|",
    ]
    detail = [
        "",
        "| lane | tmux | test | runs | failed | hung |",
        "|---|---|---|---|---|---|",
    ]
    for lane in lanes:
        bad = {t: c for t, c in lane.counts.items() if c.failed or c.hung}
        lines.append(
            f"| {lane.name} | {lane.tmux_label} | {lane.suite} | {lane.repeat} "
            f"| {lane.run_failures} | {len(bad)} |"
        )
        detail.extend(
            f"| {lane.name} | {lane.tmux_label} | {t} | {c.runs} "
            f"| {c.failed} | {c.hung} |"
            for t, c in sorted(bad.items())
        )
    table = "\n".join([*lines, *detail]) + "\n"
    (args.out / "summary.md").write_text(table)
    print(table)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with pathlib.Path(summary).open("a") as handle:
            handle.write(table)
    return 1 if any(lane.run_failures for lane in lanes) else 0


if __name__ == "__main__":
    sys.exit(main())
