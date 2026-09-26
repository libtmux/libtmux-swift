"""Verify terminal editing, machine framing and native interruption."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile
import termios
import time
from contextlib import suppress
from pathlib import Path

from owned_terminal import Terminal

binary = str(Path(sys.argv[1]).resolve())
base = Path("/tmp/libtmux-swift-dev")
base.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="editor-", dir=base) as directory:
    root = Path(directory)
    workspace = root / "edit.json"
    workspace.write_text("{}")
    editor = root / "editor"
    env = dict(os.environ, EDITOR=str(editor), MARKER=str(root / "marker"))
    for number in [None, signal.SIGINT, signal.SIGTERM]:
        editor.write_text(
            '#!/bin/sh\nprintf "%s\\n" $$ > "$CHILD_MARKER"\n'
            'read gate\nstty -echo -icanon\nprintf "READY\\n"\n'
            + (
                'read value\nprintf "%s" "$value" > "$MARKER"\n'
                if number is None
                else "exec sleep 30\n"
            )
        )
        editor.chmod(0o700)
        child_marker = root / "terminal-child"
        terminal = Terminal(
            [binary, "edit", str(workspace)],
            dict(env, CHILD_MARKER=str(child_marker)),
        )
        attributes = termios.tcgetattr(terminal.fd)
        terminal.send(b"\n")
        child = None
        try:
            terminal.until(lambda terminal=terminal: b"READY" in terminal.content)
            child = int(child_marker.read_text())
            assert termios.tcgetattr(terminal.fd) != attributes, (
                "editor did not enter raw mode"
            )
            if number is None:
                terminal.send(b"edited\n")
            else:
                os.kill(terminal.pid, number)
            terminal.until(lambda terminal=terminal: terminal.status is not None)
            assert terminal.status == (0 if number is None else 130), (
                number,
                terminal.status,
                bytes(terminal.content),
            )
            assert termios.tcgetattr(terminal.fd) == attributes, (
                "terminal settings were not restored"
            )
            if number is None:
                assert (root / "marker").read_text() == "edited"
            if child is not None:
                try:
                    os.kill(child, 0)
                except ProcessLookupError:
                    child = None
                else:
                    message = "terminal editor survived exit"
                    raise AssertionError(message)
        finally:
            termios.tcsetattr(terminal.fd, termios.TCSANOW, attributes)
            terminal.close()
            if child is not None:
                with suppress(ProcessLookupError):
                    os.kill(child, signal.SIGKILL)
    machine = subprocess.run(
        [binary, "edit", str(workspace), "--ndjson"],
        env=dict(env, EDITOR="/bin/sh -c 'printf \"\\033[31mchild\\n\"'"),
        capture_output=True,
        timeout=5,
        check=False,
    )
    assert machine.returncode == 0, machine.stderr
    record = json.loads(machine.stdout)
    assert record["stdout"] == "\x1b[31mchild\n"
    assert b"\x1b" not in machine.stdout
    for number in [signal.SIGINT, signal.SIGTERM]:
        child_marker = root / f"child-{number}"
        editor.write_text('#!/bin/sh\nprintf "%s\\n" $$ > "$MARKER"\nexec sleep 30\n')
        process = subprocess.Popen(
            [binary, "edit", str(workspace), "--json"],
            env=dict(env, MARKER=str(child_marker)),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        child = None
        try:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if child_marker.exists():
                    marker = child_marker.read_text()
                    if marker.endswith("\n"):
                        child = int(marker)
                        break
                assert process.poll() is None, process.communicate()
                time.sleep(0.01)
            assert child is not None, "editor did not start"
            started = time.monotonic()
            process.send_signal(number)
            out, err = process.communicate(timeout=3)
            assert process.returncode == 130, (number, process.returncode, out, err)
            assert time.monotonic() - started < 1
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                child = None
            else:
                message = "editor child survived interruption"
                raise AssertionError(message)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if child is not None:
                with suppress(ProcessLookupError):
                    os.kill(child, signal.SIGKILL)
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
