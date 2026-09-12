"""Verify native progress, stream separation and cancellation on private tmux."""

from __future__ import annotations

import errno
import fcntl
import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from contextlib import suppress
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
tmux = str(Path(sys.argv[2]).resolve())
base = Path("/tmp/libtmux-swift-dev")
base.mkdir(exist_ok=True)


def terminal_call(args, env, *, size=(24, 80), interrupt=None):
    """Capture a command with terminal stderr and optional marker-based SIGINT."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", *size, 0, 0))
    process = subprocess.Popen(
        [binary, *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=slave,
        env=env,
        start_new_session=True,
    )
    os.close(slave)
    assert process.stdout is not None
    outputs = {master: bytearray(), process.stdout.fileno(): bytearray()}
    reading = set(outputs)
    signalled = None
    deadline = time.monotonic() + 5
    try:
        while reading and time.monotonic() < deadline:
            for fd in select.select(list(reading), [], [], 0.02)[0]:
                try:
                    data = os.read(fd, 65_536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    data = b""
                if data:
                    outputs[fd] += data
                else:
                    reading.remove(fd)
            if (
                interrupt
                and signalled is None
                and interrupt.exists()
                and b"Loading workspace" in outputs[master]
            ):
                signalled = time.monotonic()
                process.send_signal(signal.SIGINT)
        assert not reading, (process.poll(), outputs)
        code = process.wait(timeout=1)
        if interrupt:
            elapsed = None if signalled is None else time.monotonic() - signalled
            assert elapsed is not None and elapsed < 1, (elapsed, code, outputs)
        return code, bytes(outputs[process.stdout.fileno()]), bytes(outputs[master])
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        process.stdout.close()
        os.close(master)


with tempfile.TemporaryDirectory(prefix="progress-", dir=base) as directory:
    root = Path(directory)
    socket = str(root / "s")
    env = dict(os.environ, LIBTMUX_TMUX_BIN=tmux, TERM="xterm", HOME=directory)
    env.pop("TMUXP_PROGRESS", None)
    env.pop("TMUXP_PROGRESS_LINES", None)
    env.pop("TMUXP_PROGRESS_FORMAT", None)
    env.pop("NO_COLOR", None)
    script = root / "script"
    script.write_text("#!/bin/sh\nprintf 'OUT\\033[31m'\nprintf 'ERR\\n' >&2\n")
    script.chmod(0o700)
    workspace = root / "workspace.json"
    workspace.write_text(
        json.dumps(
            {
                "session_name": "progress",
                "before_script": str(script),
                "windows": [
                    {"window_name": "one", "panes": [None, None]},
                    {"window_name": "two", "panes": [None]},
                ],
            }
        )
    )
    subprocess.run(
        [tmux, "-f", "/dev/null", "-S", socket, "new-session", "-d", "-s", "keeper"],
        check=True,
    )
    checked = 0
    child_marker = root / "child"
    load = ["load", str(workspace), "-d", "-S", socket]
    try:
        for preset in ["default", "minimal", "window", "pane", "verbose"]:
            args = [*load, "-s", preset, "--progress-format", preset]
            code, out, err = terminal_call(args, env)
            assert code == 0 and out.startswith(b"OUT\x1b[31m"), (code, out, err)
            assert b"Loading workspace" in err and err.endswith(b"\x1b[0J"), err
            assert b"\x1b[1;36m" in err and b"ERR" in err
            checked += 1
        for size in [(0, 0), (6, 20)]:
            code, out, err = terminal_call(
                [
                    *load,
                    "-s",
                    f"size{size[0]}",
                    "--progress-lines",
                    "-1",
                ],
                env,
                size=size,
            )
            assert code == 0 and b"Loading" in err and err.endswith(b"\x1b[0J"), (
                code,
                out,
                err,
            )
            checked += 1
        for flags, extra in [
            (["--no-progress"], {}),
            ([], {"TMUXP_PROGRESS": "0"}),
            ([], {"TERM": "dumb"}),
        ]:
            code, out, err = terminal_call(
                [
                    *load,
                    "-s",
                    f"disabled{checked}",
                    *flags,
                ],
                dict(env, **extra),
            )
            assert code == 0 and out.startswith(b"OUT\x1b[31m") and err == b"ERR\r\n", (
                code,
                out,
                err,
            )
            checked += 1
        code, out, err = terminal_call(
            [
                *load,
                "-s",
                "hidden",
                "--progress-lines",
                "0",
                "--color",
                "never",
            ],
            env,
        )
        assert (
            code == 0
            and b"OUT" not in err
            and b"\x1b[1;36m" not in err
            and b"ERR" in err
        )
        checked += 1
        for mode in ["--json", "--ndjson"]:
            result = subprocess.run(
                [
                    binary,
                    *load,
                    "-s",
                    mode[2:],
                    mode,
                    "--color",
                    "always",
                ],
                env=env,
                capture_output=True,
                timeout=3,
                check=False,
            )
            assert (
                result.returncode == 0 and b"\x1b" not in result.stdout + result.stderr
            )
            records = (
                [json.loads(line) for line in result.stdout.splitlines()]
                if mode == "--ndjson"
                else [json.loads(result.stdout)]
            )
            if mode == "--ndjson":
                assert sum(row["event"] == "pane-completed" for row in records) == 3
                assert (
                    sum(row["event"] in ["completed", "failed"] for row in records) == 1
                )
                assert records[-1]["event"] == "completed"
            else:
                assert records[0]["status"] == "success"
            checked += 1
        script.write_text(
            f"#!/bin/sh\nprintf '%s' $$ > '{child_marker}'\nexec sleep 30\n"
        )
        code, out, err = terminal_call(
            [*load, "-s", "cancelled"],
            env,
            interrupt=child_marker,
        )
        assert code == 130 and err.endswith(b"\x1b[0J"), (code, out, err)
        sessions = subprocess.check_output(
            [tmux, "-S", socket, "list-sessions", "-F", "#{session_name}"]
        ).splitlines()
        assert b"keeper" in sessions and b"cancelled" not in sessions
        child = int(child_marker.read_text())
        try:
            os.kill(child, 0)
        except ProcessLookupError:
            child_marker.unlink()
        else:
            message = "bootstrap child survived cancellation"
            raise AssertionError(message)
        checked += 1
        print(
            json.dumps(
                {
                    "checks": checked,
                    "tmux": subprocess.check_output([tmux, "-V"], text=True).strip(),
                    "status": "pass",
                }
            )
        )
    finally:
        subprocess.run(
            [tmux, "-S", socket, "kill-server"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if child_marker.exists():
            with suppress(ProcessLookupError):
                os.kill(int(child_marker.read_text()), signal.SIGKILL)
