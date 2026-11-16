#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Verify terminal editing, machine framing and native interruption.

The argument is the staged `tmux-workspace` executable (`<cli>`):

    uv run scripts/check_workspace/check_workspace_terminal.py <cli>

Each check runs against a private temporary directory under
`/tmp/libtmux-swift-dev/` and prints one JSON line when it passes.
"""

import json
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time
from collections.abc import Sequence
from contextlib import suppress
from pathlib import Path

from owned_terminal import Terminal

FIXTURE = Path(__file__).with_name("fixture_program.py")


def editor(mode: str, *files: Path) -> str:
    """Return the command line that runs a fixture program as `$EDITOR`."""
    return shlex.join([sys.executable, str(FIXTURE), mode, *map(str, files)])


def alive(pid: int) -> bool:
    """Say whether a process with this id exists."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def stop(pid: int) -> None:
    """Kill a process the check started, if it is still there."""
    with suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)


def check_terminal_editor(
    binary: str, workspace: Path, root: Path, number: int | None
) -> None:
    """Edit through a terminal, and end it by `number` or by saving.

    The editor takes the terminal in raw mode, so the check requires the
    workspace to put the settings back, and to stop the editor it started.
    """
    pid_file, value_file = root / "terminal-child", root / "marker"
    mode = "edit" if number is None else "hold"
    environment = dict(os.environ, EDITOR=editor(mode, pid_file, value_file))
    terminal = Terminal([binary, "edit", str(workspace)], environment)
    attributes = termios.tcgetattr(terminal.fd)
    terminal.send(b"\n")
    child = None
    try:
        terminal.until(lambda: b"READY" in terminal.content)
        child = int(pid_file.read_text())
        assert termios.tcgetattr(terminal.fd) != attributes, (
            "editor did not enter raw mode"
        )
        if number is None:
            terminal.send(b"edited\n")
        else:
            os.kill(terminal.pid, number)
        terminal.until(lambda: terminal.status is not None)
        assert terminal.status == (0 if number is None else 130), (
            number,
            terminal.status,
            bytes(terminal.content),
        )
        assert termios.tcgetattr(terminal.fd) == attributes, (
            "terminal settings were not restored"
        )
        if number is None:
            assert value_file.read_text() == "edited"
        assert not alive(child), "terminal editor survived exit"
    finally:
        termios.tcsetattr(terminal.fd, termios.TCSANOW, attributes)
        terminal.close()
        if child is not None:
            stop(child)


def check_control_bytes(binary: str, workspace: Path) -> None:
    """Keep the editor's control bytes out of `--ndjson` output."""
    machine = subprocess.run(
        [binary, "edit", str(workspace), "--ndjson"],
        env=dict(os.environ, EDITOR=editor("escape")),
        capture_output=True,
        timeout=5,
        check=False,
    )
    assert machine.returncode == 0, machine.stderr
    record = json.loads(machine.stdout)
    assert record["stdout"] == "\x1b[31mchild\n"
    assert b"\x1b" not in machine.stdout


def check_interrupt(binary: str, workspace: Path, root: Path, number: int) -> None:
    """Interrupt `edit --json` and require the editor to stop within a second."""
    pid_file = root / f"child-{number}"
    process = subprocess.Popen(
        [binary, "edit", str(workspace), "--json"],
        env=dict(os.environ, EDITOR=editor("idle", pid_file)),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    child = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if pid_file.exists() and pid_file.read_text().endswith("\n"):
                child = int(pid_file.read_text())
                break
            assert process.poll() is None, process.communicate()
            time.sleep(0.01)
        assert child is not None, "editor did not start"
        started = time.monotonic()
        process.send_signal(number)
        out, err = process.communicate(timeout=3)
        assert process.returncode == 130, (number, process.returncode, out, err)
        assert time.monotonic() - started < 1
        assert not alive(child), "editor child survived interruption"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        if child is not None:
            stop(child)


def main(argv: Sequence[str] | None = None) -> int:
    """Run every terminal check against the executable named in `argv`."""
    arguments = sys.argv[1:] if argv is None else list(argv)
    binary = str(Path(arguments[0]).resolve())
    base = Path("/tmp/libtmux-swift-dev")
    base.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="editor-", dir=base) as directory:
        root = Path(directory)
        workspace = root / "edit.json"
        workspace.write_text("{}")
        for number in [None, signal.SIGINT, signal.SIGTERM]:
            check_terminal_editor(binary, workspace, root, number)
        check_control_bytes(binary, workspace)
        for number in [signal.SIGINT, signal.SIGTERM]:
            check_interrupt(binary, workspace, root, number)
    print(
        json.dumps(
            {
                "human_pty_editor": "pass",
                "terminal_restoration": "normal exit, SIGINT, SIGTERM",
                "machine_control_bytes": "pass",
                "interrupt_signals": "pass",
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
