#!/usr/bin/env python3
"""Run a command and, if it outlives a deadline, record what it was doing.

`swift test` buffers its output when stdout is a pipe, so a case that parks a
thread leaves a CI log that stops at `Build complete!` and nothing else until
the job's own timeout cancels it. That says a case hung and not which one. This
wrapper gives the child a pty, so Swift Testing's `started` lines reach the log
as they happen, and past the deadline it samples the process tree, every tmux
server under the test socket root, and the child's threads before killing the
process group.

    python3 Scripts/run_with_hang_guard.py --seconds 900 --out DIR -- swift test

Exit status is the child's, or 124 when the deadline killed it.
"""

from __future__ import annotations

import argparse
import contextlib
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import sys
import time

SOCKET_ROOT = pathlib.Path("/tmp/libtmux-swift-test")
EXIT_TIMED_OUT = 124


def capture(out: pathlib.Path, name: str, argv: list[str], timeout: float = 60) -> None:
    """Write one diagnostic command's combined output to `out/name`."""
    if shutil.which(argv[0]) is None:
        return
    try:
        done = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        text = done.stdout + done.stderr
    except (OSError, subprocess.SubprocessError) as error:
        text = f"{argv}: {error}\n"
    (out / name).write_text(text)


def sockets() -> list[pathlib.Path]:
    """Return every unix socket under the test root."""
    found: list[pathlib.Path] = []
    if SOCKET_ROOT.is_dir():
        for path in SOCKET_ROOT.rglob("*"):
            with contextlib.suppress(OSError):
                if path.is_socket():
                    found.append(path)
    return found


def diagnose(out: pathlib.Path, pid: int) -> None:
    """Record the process tree, tmux state, and thread stacks of a hung run."""
    out.mkdir(parents=True, exist_ok=True)
    capture(
        out,
        "ps.txt",
        ["ps", "-axo", "pid,ppid,pgid,stat,etime,pcpu,command"],
    )
    for index, socket in enumerate(sockets()):
        capture(
            out,
            f"tmux-{index}.txt",
            [
                os.environ.get("LIBTMUX_TMUX_BIN", "tmux"),
                "-S",
                str(socket),
                "list-panes",
                "-a",
                "-F",
                (
                    "#{session_name} #{window_name} #{pane_id} dead=#{pane_dead} "
                    "cmd=#{pane_current_command} pid=#{pane_pid}"
                ),
            ],
            timeout=10,
        )
    # Every process whose command mentions the test harness, not just the
    # direct child: SwiftPM runs the tests in `swiftpm-testing`/the xctest
    # runner, which is a grandchild.
    listing = subprocess.run(
        ["ps", "-axo", "pid,command"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    for line in listing.splitlines()[1:]:
        fields = line.split(None, 1)
        if len(fields) < 2 or not fields[0].isdigit():
            continue
        target, command = fields
        if (
            "swiftpm-testing" in command
            or "PackageTests" in command
            or target == str(pid)
        ):
            capture(out, f"sample-{target}.txt", ["sample", target, "5"], timeout=30)
            capture(out, f"lsof-{target}.txt", ["lsof", "-p", target])
    capture(out, "date.txt", ["date", "-u"])


def main() -> int:
    """Run the command under the guard."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, required=True)
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("no command given")

    master, slave = pty.openpty()
    child = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    deadline = time.monotonic() + args.seconds
    log = args.out / "output.log"
    args.out.mkdir(parents=True, exist_ok=True)
    timed_out = False
    with log.open("wb") as sink:
        while True:
            if child.poll() is not None:
                break
            if time.monotonic() >= deadline:
                timed_out = True
                break
            ready, _, _ = select.select([master], [], [], 1.0)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    chunk = b""
                if chunk:
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    sink.write(chunk)
                    sink.flush()
        # Drain what the child wrote before it exited.
        while not timed_out:
            ready, _, _ = select.select([master], [], [], 0.2)
            if not ready:
                break
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            sys.stdout.buffer.write(chunk)
            sink.write(chunk)
    if timed_out:
        print(
            f"hang guard: no exit after {args.seconds:.0f}s, sampling",
            flush=True,
        )
        diagnose(args.out, child.pid)
        with contextlib.suppress(ProcessLookupError):
            os.killpg(child.pid, signal.SIGKILL)
        child.wait()
        return EXIT_TIMED_OUT
    return child.returncode


if __name__ == "__main__":
    sys.exit(main())
