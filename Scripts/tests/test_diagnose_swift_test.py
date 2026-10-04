"""Keep diagnostic sampling scoped and independent of the command's result."""

from __future__ import annotations

import json
import runpy
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).parents[1] / "diagnose_swift_test.py"
DIAGNOSTICS = runpy.run_path(SCRIPT)


def process(pid: int, parent: int, started: str = "original") -> dict:
    """Describe a process with a stable start identity."""
    return {"pid": pid, "parent": parent, "started": started, "command": "test"}


def test_subtree_rejects_unrelated_and_reused_pids() -> None:
    """Never widen diagnostics beyond the original live test subtree."""
    root = process(10, 1)
    rows = {10: root, 11: process(11, 10), 12: process(12, 11), 99: process(99, 1)}
    assert [row["pid"] for row in DIAGNOSTICS["subtree"](rows, root)] == [10, 11, 12]
    rows[10] = process(10, 1, "replacement")
    assert DIAGNOSTICS["subtree"](rows, root) == []
    del rows[10]
    assert DIAGNOSTICS["subtree"](rows, root) == []


def test_sample_rechecks_live_ancestry(tmp_path: Path) -> None:
    """Reject unrelated, departed, or reused PIDs immediately before sampling."""
    observer = DIAGNOSTICS["Observer"](tmp_path, Mock(poll=Mock(return_value=None)))
    observer.root = process(10, 1)
    table = observer.sample.__globals__
    rows = {10: observer.root, 11: process(11, 10), 99: process(99, 1)}
    with (
        patch.dict(table, process_table=lambda: rows),
        patch.object(subprocess, "run") as run,
    ):
        run.return_value = subprocess.CompletedProcess([], 0)
        observer.sample(rows[99], 60)
        observer.sample(process(12, 10), 60)
        observer.sample(process(11, 10, "earlier"), 60)
        run.assert_not_called()
        observer.sample(rows[11], 60)
        assert run.call_args.args[0][:4] == ["/usr/bin/sample", "11", "2", "1"]
        assert run.call_args.kwargs["timeout"] == 5


def test_sample_failure_and_retained_output_are_bounded(tmp_path: Path) -> None:
    """Retain a failed sample distinctly and cap its retained bytes."""
    observer = DIAGNOSTICS["Observer"](tmp_path, Mock(poll=Mock(return_value=None)))
    observer.root = process(10, 1)
    table = observer.sample.__globals__

    def sample_result(
        argv: list[str], **_kwargs: object
    ) -> subprocess.CompletedProcess:
        Path(argv[-1]).write_bytes(b"x" * (DIAGNOSTICS["MAX_SAMPLE_BYTES"] + 10))
        return subprocess.CompletedProcess(argv, 1)

    with (
        patch.dict(table, process_table=lambda: {10: observer.root}),
        patch.object(subprocess, "run", side_effect=sample_result),
    ):
        observer.sample(observer.root, 60)
    assert (tmp_path / "sample-60-10.txt").stat().st_size == DIAGNOSTICS[
        "MAX_SAMPLE_BYTES"
    ]
    assert observer.failures == 1


def test_observer_failure_cannot_change_child_status(tmp_path: Path) -> None:
    """Actual commands keep success, failure and signal exits with a broken observer."""
    for status in (0, 7, -signal.SIGTERM):
        directory = tmp_path / str(status)
        directory.mkdir()
        (directory / "observer.jsonl").mkdir()
        expression = (
            f"import sys; print('child output'); sys.exit({status})"
            if status >= 0
            else "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(directory),
                "--",
                sys.executable,
                "-c",
                expression,
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        assert result.returncode == (status if status >= 0 else 128 - status)
        assert "diagnostic failure" in result.stdout
        if status >= 0:
            assert "child output" in result.stdout


def test_events_are_visible_before_command_exit(tmp_path: Path) -> None:
    """Read case events while the launched test command is still active."""
    observer = DIAGNOSTICS["Observer"](tmp_path, Mock(poll=Mock(return_value=None)))
    (tmp_path / "events.jsonl").write_text('{"kind":"testStarted"}\n')
    with patch("builtins.print") as output:
        observer.events()
        observer.events()
    output.assert_called_once_with('{"kind":"testStarted"}\n', end="", flush=True)


def test_sampling_rounds_and_process_count_are_bounded(tmp_path: Path) -> None:
    """Do not let a compiler's many workers make sampling unbounded."""
    observer = DIAGNOSTICS["Observer"](
        tmp_path, Mock(pid=10, poll=Mock(return_value=None))
    )
    observer.started -= 61
    stopped = threading.Event()
    rows = {pid: process(pid, 1 if pid == 10 else 10) for pid in range(10, 40)}
    table = observer.observe.__globals__
    sampled = []

    def sample(row: dict, _round: int) -> None:
        sampled.append(row["pid"])
        if len(sampled) == DIAGNOSTICS["MAX_SAMPLES"]:
            stopped.set()

    with (
        patch.dict(table, process_table=lambda: rows),
        patch.object(observer, "sample", sample),
    ):
        observer.observe(stopped)
    assert len(sampled) == DIAGNOSTICS["MAX_SAMPLES"]
    assert DIAGNOSTICS["SAMPLE_AT"] == (60, 300, 900)
    records = [
        json.loads(line)
        for line in (tmp_path / "observer.jsonl").read_text().splitlines()
    ]
    assert records[-1]["event"] == "sample-round"


def test_shutdown_drains_events_after_active_observer_finishes(tmp_path: Path) -> None:
    """Finish an in-flight observation before final reads or interpreter shutdown."""
    finished = threading.Event()

    class ActiveObserver(DIAGNOSTICS["Observer"]):
        def observe(self, stopped: threading.Event) -> None:
            stopped.wait()
            time.sleep(0.1)
            (self.directory / "events.jsonl").write_text('{"kind":"testEnded"}\n')
            finished.set()

        def events(self) -> None:
            assert finished.is_set(), "final drain raced the active observer"
            super().events()

    argv = [
        str(SCRIPT),
        str(tmp_path),
        "--",
        sys.executable,
        "-c",
        "raise SystemExit(7)",
    ]
    with (
        patch.dict(DIAGNOSTICS["main"].__globals__, Observer=ActiveObserver),
        patch.object(sys, "argv", argv),
        patch.object(signal, "signal"),
    ):
        assert DIAGNOSTICS["main"]() == 7
    records = [
        json.loads(line)
        for line in (tmp_path / "observer.jsonl").read_text().splitlines()
    ]
    assert records[-1]["eventBytes"] == len('{"kind":"testEnded"}\n')
