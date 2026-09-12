"""Verify native workspace attachment and explicit terminal choices."""

from __future__ import annotations

import json
import os
import pty
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import suppress
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
tmux = str(Path(sys.argv[2]).resolve())
base = Path("/tmp/libtmux-swift-dev")
base.mkdir(exist_ok=True)


class Terminal:
    """Own and reap one process with a controlling terminal."""

    def __init__(self, arguments, environment):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(arguments[0], arguments, environment)
        self.status = None
        self.content = bytearray()

    def pump(self):
        """Read available output and observe process exit."""
        if select.select([self.fd], [], [], 0.01)[0]:
            with suppress(OSError):
                self.content += os.read(self.fd, 65536)
                self.content = self.content[-65536:]
        if self.status is None:
            ended, status = os.waitpid(self.pid, os.WNOHANG)
            if ended:
                self.status = os.waitstatus_to_exitcode(status)

    def until(self, predicate):
        """Wait for a fixture condition with bounded terminal output."""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.pump()
            if predicate():
                return
            assert self.status is None, (self.status, bytes(self.content))
        raise AssertionError(bytes(self.content))

    def send(self, value):
        """Write terminal input."""
        os.write(self.fd, value)

    def close(self):
        """Terminate and reap the owned child before closing its terminal."""
        if self.status is None:
            with suppress(ProcessLookupError):
                os.kill(self.pid, signal.SIGTERM)
            deadline = time.monotonic() + 1
            while self.status is None and time.monotonic() < deadline:
                self.pump()
            if self.status is None:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
        os.close(self.fd)


def check(choice):
    """Exercise one load choice against an owned terminal and server."""
    with tempfile.TemporaryDirectory(prefix="attach-", dir=base) as directory:
        root = Path(directory)
        socket = str(root / "tmux")
        environment = dict(
            os.environ,
            TERM="xterm-256color",
            HOME=str(root),
            SHELL="/bin/sh",
            ENV="/dev/null",
            BASH_ENV="/dev/null",
            ZDOTDIR=str(root),
            LIBTMUX_TMUX_BIN=tmux,
            TMUX_TMPDIR=str(root),
        )
        environment.pop("TMUX", None)
        environment.pop("TMUX_PANE", None)
        terminals = []

        def command(*arguments, endpoint=socket):
            """Run tmux against an explicit fixture endpoint."""
            result = subprocess.run(
                [tmux, "-f", "/dev/null", "-S", endpoint, *arguments],
                env=environment,
                capture_output=True,
                text=True,
                check=True,
                timeout=3,
            )
            return result.stdout.strip()

        def clients():
            """Read client names, process IDs and sessions."""
            return [
                line.split("\t")
                for line in command(
                    "list-clients",
                    "-F",
                    "#{client_name}\t#{client_pid}\t#{session_name}",
                ).splitlines()
            ]

        def sessions():
            """Read the fixture session names."""
            return command("list-sessions", "-F", "#{session_name}").splitlines()

        def terminal(arguments):
            """Track an owned terminal for cleanup."""
            result = Terminal(arguments, environment)
            terminals.append(result)
            return result

        foreign = str(root / "foreign")
        try:
            pane = command(
                "new-session", "-d", "-s", "keeper", "-P", "-F", "#{pane_id}", "/bin/sh"
            )
            files = []
            for name in ["first", "final"]:
                file = root / (name + ".json")
                file.write_text(
                    json.dumps({"session_name": name, "windows": [{"panes": [None]}]})
                )
                files.append(str(file))
            if choice.startswith("outside-"):
                if choice == "outside-detach":
                    environment["TMUX"] = ""
                elif choice == "outside-malformed":
                    environment["TMUX"] = "invalid"
                owner = terminal(
                    [
                        binary,
                        "load",
                        *files,
                        "-S",
                        socket,
                        "-f",
                        "/dev/null",
                        "--no-progress",
                    ]
                )
                if choice == "outside-malformed":
                    owner.until(lambda: owner.status is not None)
                    assert owner.status == 1 and sessions() == ["keeper"]
                    assert clients() == []
                    return
                owner.until(lambda: any(row[2] == "final" for row in clients()))
                assert sessions() == ["final", "first", "keeper"]
                if choice == "outside-detach":
                    owner.send(b"\x02d")
                else:
                    os.kill(
                        owner.pid,
                        signal.SIGINT if choice == "outside-int" else signal.SIGTERM,
                    )
                owner.until(lambda: owner.status is not None)
                assert owner.status == (0 if choice == "outside-detach" else 130)
                assert clients() == []
                assert sessions() == ["final", "first", "keeper"]
            else:
                viewer = terminal(
                    [tmux, "-S", socket, "attach-session", "-t", "=keeper"]
                )
                viewer.until(lambda: len(clients()) == 1)
                first_client = clients()[0][0]
                if choice.startswith("ambiguous"):
                    other = terminal(
                        [tmux, "-S", socket, "attach-session", "-t", "=keeper"]
                    )
                    other.until(lambda: len(clients()) == 2)
                endpoint = socket
                if choice == "foreign":
                    command(
                        "new-session", "-d", "-s", "foreign-keeper", endpoint=foreign
                    )
                    endpoint = foreign
                marker = root / "exit-code"
                arguments = [binary, "load", files[1], "-S", endpoint, "--no-progress"]
                if choice in ["yes", "ambiguous-yes"]:
                    arguments.append("-y")
                if choice == "spoofed-pane":
                    other_pane = command(
                        "new-window", "-d", "-t", "=keeper:", "-P", "-F", "#{pane_id}"
                    )
                    arguments = ["env", "TMUX_PANE=" + other_pane, *arguments]
                line = (
                    shlex.join(arguments)
                    + "; printf '%s\\n' \"$?\" > "
                    + shlex.quote(str(marker))
                )
                command("send-keys", "-t", pane, "-l", line)
                command("send-keys", "-t", pane, "Enter")
                if choice not in ["yes", "ambiguous-yes", "foreign", "spoofed-pane"]:
                    viewer.until(lambda: b"[y]" in viewer.content)
                    answer = {
                        "detached": b"n\n",
                        "append": b"a\n",
                        "eof": b"\x04",
                        "quit": b"q\n",
                        "interrupt": b"\x03",
                    }.get(choice, b"y\n")
                    if choice == "stale-client":
                        command("new-session", "-d", "-s", "elsewhere")
                        command("switch-client", "-c", first_client, "-t", "=elsewhere")
                        command("send-keys", "-t", pane, "y", "Enter")
                    else:
                        viewer.send(answer)
                    if choice == "ambiguous":
                        viewer.until(lambda: b"Choose client" in viewer.content)
                        selected = min(row[0] for row in clients())
                        viewer.send(b"99\n")
                        viewer.until(lambda: b"99" in viewer.content)
                        assert sessions() == ["keeper"]
                        viewer.send(b"1\n")
                    else:
                        selected = first_client
                else:
                    selected = first_client
                viewer.until(
                    lambda: marker.exists() and marker.read_text().endswith("\n")
                )
                status = int(marker.read_text())
                if choice in ["foreign", "ambiguous-yes", "spoofed-pane"]:
                    assert status != 0
                    assert sessions() == ["keeper"]
                    assert all(row[2] == "keeper" for row in clients())
                    if choice == "foreign":
                        assert (
                            command(
                                "list-sessions",
                                "-F",
                                "#{session_name}",
                                endpoint=foreign,
                            )
                            == "foreign-keeper"
                        )
                elif choice in ["eof", "quit", "interrupt"]:
                    assert status == 130 and sessions() == ["keeper"]
                    assert clients()[0][2] == "keeper"
                elif choice == "stale-client":
                    assert status != 0 and sessions() == [
                        "elsewhere",
                        "final",
                        "keeper",
                    ]
                    assert clients()[0][2] == "elsewhere"
                elif choice == "append":
                    assert status == 0 and sessions() == ["keeper"]
                    assert (
                        command(
                            "display-message",
                            "-p",
                            "-t",
                            "=keeper:",
                            "#{session_windows}",
                        )
                        == "2"
                    )
                    assert clients()[0][2] == "keeper"
                else:
                    assert status == 0 and sessions() == ["final", "keeper"]
                    for name, _, session in clients():
                        assert session == (
                            "final"
                            if choice != "detached" and name == selected
                            else "keeper"
                        )
        finally:
            for endpoint in [socket, foreign]:
                subprocess.run(
                    [tmux, "-S", endpoint, "kill-server"],
                    env=environment,
                    capture_output=True,
                    check=False,
                    timeout=3,
                )
            for owner in terminals:
                owner.close()


checks = []
for choice in [
    "outside-detach",
    "outside-int",
    "outside-term",
    "outside-malformed",
    "detached",
    "append",
    "switch",
    "yes",
    "eof",
    "quit",
    "interrupt",
    "ambiguous",
    "ambiguous-yes",
    "foreign",
    "spoofed-pane",
    "stale-client",
]:
    check(choice)
    checks.append(choice)

print(
    json.dumps(
        {
            "tmux": subprocess.check_output([tmux, "-V"], text=True).strip(),
            "passed": checks,
        }
    )
)
