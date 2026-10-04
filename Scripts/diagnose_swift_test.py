"""Observe a Swift test command without changing its result or deadline."""

from __future__ import annotations

import json
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

SAMPLE_AT = (60, 300, 900)
MAX_SAMPLES = 8
MAX_SAMPLE_BYTES = 1024 * 1024


def process_table() -> dict[int, dict]:
    """Read process ancestry and start identities on Linux and Darwin."""
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,lstart=,command="], text=True, timeout=5
    )
    rows = {}
    for line in output.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8:
            rows[int(fields[0])] = {
                "pid": int(fields[0]),
                "parent": int(fields[1]),
                "started": " ".join(fields[2:7]),
                "command": fields[7],
            }
    return rows


def subtree(rows: dict[int, dict], root: dict) -> list[dict]:
    """Select only the current descendants of the original live process."""
    current = rows.get(root["pid"])
    if current is None or current["started"] != root["started"]:
        return []
    selected = [current]
    seen = {current["pid"]}
    for parent in selected:
        for row in rows.values():
            if row["parent"] == parent["pid"] and row["pid"] not in seen:
                selected.append(row)
                seen.add(row["pid"])
    return selected


class Observer:
    """Retain case events and bounded snapshots of one launched command."""

    def __init__(self, directory: Path, child: subprocess.Popen) -> None:
        self.directory = directory
        self.child = child
        self.root: dict | None = None
        self.offset = 0
        self.started = time.monotonic()
        self.failures = 0

    def record(self, kind: str, **fields: object) -> None:
        """Append a timestamped diagnostic record and flush it to CI output."""
        record = {"event": kind, "elapsed": time.monotonic() - self.started, **fields}
        line = json.dumps(record, sort_keys=True)
        with (self.directory / "observer.jsonl").open("a") as output:
            output.write(line + "\n")
        print(f"[swift-test-observer] {line}", flush=True)

    def events(self) -> None:
        """Expose case events even while SwiftPM buffers its child output."""
        path = self.directory / "events.jsonl"
        if not path.exists():
            return
        with path.open("rb") as stream:
            stream.seek(self.offset)
            data = stream.read(65536)
            self.offset += len(data)
        if data:
            print(data.decode("utf-8", errors="replace"), end="", flush=True)

    def sample(self, process: dict, round_number: int) -> None:
        """Sample only an identity still in the launched command's subtree."""
        if self.child.poll() is not None or self.root is None:
            return
        live = subtree(process_table(), self.root)
        if not any(
            row["pid"] == process["pid"] and row["started"] == process["started"]
            for row in live
        ):
            self.record(
                "sample-skipped", process=process, reason="identity no longer owned"
            )
            return
        if self.child.poll() is not None:
            return
        path = self.directory / f"sample-{round_number}-{process['pid']}.txt"
        try:
            result = subprocess.run(
                ["/usr/bin/sample", str(process["pid"]), "2", "1", "-file", str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
        finally:
            if path.exists() and path.stat().st_size > MAX_SAMPLE_BYTES:
                with path.open("r+b") as output:
                    output.truncate(MAX_SAMPLE_BYTES)
                self.record(
                    "sample-truncated", path=str(path), retainedBytes=MAX_SAMPLE_BYTES
                )
        captured = path.stat().st_size if path.exists() else 0
        self.record(
            "sample-finished",
            process=process,
            path=str(path),
            status=result.returncode,
            retainedBytes=captured,
        )
        if path.exists():
            print(path.read_text(errors="replace"), flush=True)
        if result.returncode != 0 or not captured:
            self.failures += 1

    def observe(self, stopped: threading.Event) -> None:
        """Collect diagnostics without changing the command's result."""
        next_snapshot = 0
        pending = list(SAMPLE_AT)
        while not stopped.is_set():
            try:
                self.events()
                elapsed = time.monotonic() - self.started
                if elapsed >= next_snapshot:
                    next_snapshot = elapsed + 30
                    rows = process_table()
                    if self.root is None and self.child.poll() is None:
                        self.root = rows.get(self.child.pid)
                    owned = subtree(rows, self.root) if self.root else []
                    self.record("processes", processes=owned)
                    if pending and elapsed >= pending[0]:
                        round_number = pending.pop(0)
                        self.record(
                            "sample-round",
                            at=round_number,
                            selected=owned[:MAX_SAMPLES],
                        )
                        for process in owned[:MAX_SAMPLES]:
                            if stopped.is_set():
                                break
                            self.sample(process, round_number)
            except (OSError, subprocess.SubprocessError) as error:
                self.failures += 1
                print(f"[swift-test-observer] diagnostic failure: {error}", flush=True)
            stopped.wait(0.25)


def main() -> int:
    """Run the unchanged command, preserving its exit status on observer failure."""
    usage = "usage: diagnose_swift_test.py DIRECTORY -- COMMAND [ARG ...]"
    if len(sys.argv) < 4:
        raise SystemExit(usage)
    directory = Path(sys.argv[1])
    command = sys.argv[3:]
    if sys.argv[2] != "--" or not command:
        raise SystemExit(usage)
    directory.mkdir(parents=True, exist_ok=True)
    child = subprocess.Popen(command)
    observer = Observer(directory, child)
    stopped = threading.Event()

    def forward(signum: int, _frame: object) -> None:
        if child.poll() is None:
            child.send_signal(signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    try:
        observer.record("launch", pid=child.pid, command=command)
    except OSError as error:
        observer.failures += 1
        print(f"[swift-test-observer] launch diagnostic failure: {error}", flush=True)
    worker = threading.Thread(target=observer.observe, args=(stopped,))
    worker.start()
    try:
        status = child.wait()
    finally:
        stopped.set()
        worker.join()
    try:
        observer.events()
        observer.record(
            "exit",
            status=status,
            diagnosticFailures=observer.failures,
            eventBytes=observer.offset,
            rootObserved=observer.root is not None,
        )
    except OSError as error:
        print(f"[swift-test-observer] final diagnostic failure: {error}", flush=True)
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    sys.exit(main())
