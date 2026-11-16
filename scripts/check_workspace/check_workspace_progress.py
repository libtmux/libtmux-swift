#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Verify native progress, stream separation and cancellation on private tmux.

The arguments are the staged `tmux-workspace` executable (`<cli>`) and the tmux
to run it against:

    uv run scripts/check_workspace/check_workspace_progress.py <cli> <tmux>

Each check runs against a private temporary directory under
`/tmp/libtmux-swift-dev/` and prints one JSON line when it passes.
"""

from __future__ import annotations

import errno
import fcntl
import json
import os
import pty
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from collections.abc import Mapping, Sequence
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path

from owned_terminal import stop_server

FIXTURE = Path(__file__).with_name("fixture_program.py")
KEEPER = ["new-session", "-d", "-s", "keeper"]


def terminal_call(
    binary: str,
    args: Sequence[str],
    env: Mapping[str, str],
    *,
    size: tuple[int, int] = (24, 80),
    interrupt: Path | None = None,
) -> tuple[int, bytes, bytes]:
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


@dataclass
class Fixture:
    """What every progress check shares: the executable, tmux and a private root."""

    binary: str
    tmux: str
    root: Path
    env: dict[str, str]

    @property
    def socket(self) -> str:
        """Return the socket of the private server."""
        return str(self.root / "s")

    def load(self, workspace: Path) -> list[str]:
        """Return the `load` arguments every check starts from."""
        return ["load", str(workspace), "-d", "-S", self.socket]

    def call(
        self,
        workspace: Path,
        *arguments: str,
        env: Mapping[str, str] | None = None,
        size: tuple[int, int] = (24, 80),
        interrupt: Path | None = None,
    ) -> tuple[int, bytes, bytes]:
        """Run `load` on a terminal with the extra `arguments`."""
        return terminal_call(
            self.binary,
            [*self.load(workspace), *arguments],
            self.env if env is None else env,
            size=size,
            interrupt=interrupt,
        )


def write_workspace(path: Path, program: str, *files: Path) -> Path:
    """Write a workspace whose `before_script` runs the fixture `program`."""
    command = shlex.join([sys.executable, str(FIXTURE), program, *map(str, files)])
    path.write_text(
        json.dumps(
            {
                "session_name": "progress",
                "before_script": command,
                "windows": [
                    {"window_name": "one", "panes": [None, None]},
                    {"window_name": "two", "panes": [None]},
                ],
            }
        )
    )
    return path


def require_output(code: int, out: bytes, err: bytes) -> None:
    """Require a clean load whose stdout starts with the script's output."""
    assert code == 0 and out.startswith(b"OUT\x1b[31m"), (code, out, err)


def check_presets(fixture: Fixture, workspace: Path) -> int:
    """Render every preset: progress on stderr, the script's output on stdout."""
    presets = ["default", "minimal", "window", "pane", "verbose"]
    for preset in presets:
        code, out, err = fixture.call(
            workspace, "-s", preset, "--progress-format", preset
        )
        require_output(code, out, err)
        assert b"Loading workspace" in err and err.endswith(b"\x1b[0J"), err
        assert b"\x1b[1;36m" in err and b"ERR" in err
    return len(presets)


def check_sizes(fixture: Fixture, workspace: Path) -> int:
    """Render on a terminal without a size and on a small one."""
    sizes = [(0, 0), (6, 20)]
    for size in sizes:
        code, out, err = fixture.call(
            workspace, "-s", f"size{size[0]}", "--progress-lines", "-1", size=size
        )
        assert code == 0 and b"Loading" in err and err.endswith(b"\x1b[0J"), (
            code,
            out,
            err,
        )
    return len(sizes)


def check_disabled(fixture: Fixture, workspace: Path) -> int:
    """Print no progress under `--no-progress`, `TMUXP_PROGRESS=0` or `TERM=dumb`."""
    cases = [
        (["--no-progress"], {}),
        ([], {"TMUXP_PROGRESS": "0"}),
        ([], {"TERM": "dumb"}),
    ]
    for index, (flags, extra) in enumerate(cases):
        code, out, err = fixture.call(
            workspace, "-s", f"disabled{index}", *flags, env=dict(fixture.env, **extra)
        )
        assert code == 0 and out.startswith(b"OUT\x1b[31m") and err == b"ERR\r\n", (
            code,
            out,
            err,
        )
    return len(cases)


def check_hidden(fixture: Fixture, workspace: Path) -> int:
    """Keep the script's stdout and colour out of stderr at zero progress lines."""
    code, _, err = fixture.call(
        workspace, "-s", "hidden", "--progress-lines", "0", "--color", "never"
    )
    assert (
        code == 0 and b"OUT" not in err and b"\x1b[1;36m" not in err and b"ERR" in err
    )
    return 1


def check_machine_output(fixture: Fixture, workspace: Path) -> int:
    """Frame `--json` as one document and `--ndjson` as events, with no escapes."""
    for mode in ["--json", "--ndjson"]:
        result = subprocess.run(
            [
                fixture.binary,
                *fixture.load(workspace),
                "-s",
                mode[2:],
                mode,
                "--color",
                "always",
            ],
            env=fixture.env,
            capture_output=True,
            timeout=3,
            check=False,
        )
        assert result.returncode == 0 and b"\x1b" not in result.stdout + result.stderr
        if mode == "--ndjson":
            records = [json.loads(line) for line in result.stdout.splitlines()]
            assert sum(row["event"] == "pane-completed" for row in records) == 3
            ends = sum(row["event"] in ["completed", "failed"] for row in records)
            assert ends == 1
            assert records[-1]["event"] == "completed"
        else:
            assert json.loads(result.stdout)["status"] == "ok"
    return 2


def check_cancellation(fixture: Fixture, workspace: Path) -> int:
    """Interrupt a load whose script is running, and require a prompt exit.

    The check requires the script to be stopped and the session to stay.
    """
    pid_file = fixture.root / "child"
    cancelled = write_workspace(fixture.root / "cancel.json", "idle", pid_file)
    code, out, err = fixture.call(cancelled, "-s", "cancelled", interrupt=pid_file)
    cleared, separator, diagnostic = err.rpartition(b"\x1b[0J")
    assert (
        code == 130
        and cleared
        and separator
        and diagnostic.startswith(b"Error: ")
        and diagnostic.endswith(b"\r\n")
        and diagnostic.count(b"\n") == 1
    ), (code, out, err)
    sessions = subprocess.check_output(
        [fixture.tmux, "-S", fixture.socket, "list-sessions", "-F", "#{session_name}"],
        env=fixture.env,
    ).splitlines()
    # An interruption is not rolled back: the same signal that stopped
    # the build could just as well stop the cleanup that would follow
    # it, so the session it created stays in place.
    assert b"keeper" in sessions and b"cancelled" in sessions
    try:
        os.kill(int(pid_file.read_text()), 0)
    except ProcessLookupError:
        pid_file.unlink()
    else:
        message = "bootstrap child survived cancellation"
        raise AssertionError(message)
    return 1


def main(argv: Sequence[str] | None = None) -> int:
    """Run every progress check against the executable and tmux named in `argv`."""
    arguments = sys.argv[1:] if argv is None else list(argv)
    binary = str(Path(arguments[0]).resolve())
    tmux = str(Path(arguments[1]).resolve())
    base = Path("/tmp/libtmux-swift-dev")
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="progress-", dir=base) as directory:
        root = Path(directory)
        env = dict(os.environ, LIBTMUX_TMUX_BIN=tmux, TERM="xterm", HOME=directory)
        for name in [
            "TMUX",
            "TMUX_PANE",
            *(n for n in env if n.startswith("LIBTMUX_SOCKET")),
            "TMUXP_PROGRESS",
            "TMUXP_PROGRESS_LINES",
            "TMUXP_PROGRESS_FORMAT",
            "NO_COLOR",
        ]:
            env.pop(name, None)
        fixture = Fixture(binary, tmux, root, env)
        workspace = write_workspace(root / "workspace.json", "report")
        subprocess.run(
            [tmux, "-f", "/dev/null", "-S", fixture.socket, *KEEPER],
            env=env,
            check=True,
        )
        checked = 0
        pid_file = root / "child"
        try:
            for check in [
                check_presets,
                check_sizes,
                check_disabled,
                check_hidden,
                check_machine_output,
                check_cancellation,
            ]:
                checked += check(fixture, workspace)
            print(
                json.dumps(
                    {
                        "checks": checked,
                        "tmux": subprocess.check_output(
                            [tmux, "-V"], text=True
                        ).strip(),
                        "status": "pass",
                    }
                )
            )
        finally:
            stop_server(tmux, fixture.socket, env)
            if pid_file.exists():
                with suppress(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), signal.SIGKILL)
    return 0


if __name__ == "__main__":
    sys.exit(main())
