"""Capture macOS test process stacks before a stalled command exhausts CI."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import signal
import subprocess
import time
from pathlib import Path


def snapshot(
    directory: Path, process: subprocess.Popen[bytes], deadline: float
) -> None:
    """Record the command's descendants, open files, and sampled stacks."""
    directory.mkdir(parents=True, exist_ok=True)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return
    try:
        listing = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,stat=,etime=,command="],
            text=True,
            timeout=min(3, remaining),
        )
    except subprocess.TimeoutExpired:
        return
    (directory / "processes.txt").write_text(listing)
    rows = [line.split(None, 4) for line in listing.splitlines()]
    descendants = {process.pid}
    while True:
        found = {
            int(row[0]) for row in rows if len(row) == 5 and int(row[1]) in descendants
        }
        if found <= descendants:
            break
        descendants.update(found)
    for pid in sorted(descendants)[:8]:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or process.poll() is not None:
            return
        with (
            (directory / f"files-{pid}.txt").open("w") as output,
            contextlib.suppress(subprocess.TimeoutExpired),
        ):
            subprocess.run(
                ["lsof", "-nP", "-p", str(pid)],
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=min(3, remaining),
                check=False,
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0 or process.poll() is not None:
            return
        with (
            (directory / f"sample-{pid}.log").open("w") as output,
            contextlib.suppress(subprocess.TimeoutExpired),
        ):
            subprocess.run(
                [
                    "sample",
                    str(pid),
                    "1",
                    "1",
                    "-file",
                    str(directory / f"sample-{pid}.txt"),
                ],
                stdout=output,
                stderr=subprocess.STDOUT,
                timeout=min(3, remaining),
                check=False,
            )


def main() -> int:
    """Run one command, retaining bounded diagnostic evidence on macOS."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    args.output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    deadline = started + 300
    snapshots = 0
    timed_out = False
    with (args.output / "command.log").open("w") as output:
        process = subprocess.Popen(
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        try:
            while True:
                if process.poll() is not None:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    status = process.wait(timeout=min(30, remaining))
                    break
                except subprocess.TimeoutExpired:
                    snapshots += 1
                    snapshot(args.output / f"snapshot-{snapshots}", process, deadline)
        finally:
            if process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
    status = 124 if timed_out else process.returncode
    (args.output / "result.json").write_text(
        json.dumps(
            {
                "command": command,
                "status": status,
                "seconds": round(time.monotonic() - started, 3),
                "snapshots": snapshots,
            },
            indent=2,
        )
        + "\n"
    )
    print((args.output / "command.log").read_text(), end="", flush=True)
    print(f"diagnostic command status={status}, snapshots={snapshots}", flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
