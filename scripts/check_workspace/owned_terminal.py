"""Own a child process attached to a pty, and wait on its output.

check_workspace_attach.py and check_workspace_terminal.py both drive a
process through a controlling terminal and need the same three things: fork
it under a pty, wait for a fixture condition in its output or exit, and reap
it whether or not it exited on its own. The checks that start a tmux server
also stop it with `stop_server`.
"""

import os
import pty
import select
import signal
import socket
import subprocess
import time
from collections.abc import Callable, Mapping
from contextlib import suppress


class Terminal:
    """Own and reap one process with a controlling terminal."""

    def __init__(self, arguments: list[str], environment: Mapping[str, str]) -> None:
        """Fork `arguments` under a pty with `environment`."""
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(arguments[0], arguments, environment)
        self.status: int | None = None
        self.content = bytearray()

    def pump(self) -> None:
        """Read available output and observe process exit."""
        if select.select([self.fd], [], [], 0.01)[0]:
            with suppress(OSError):
                self.content += os.read(self.fd, 65536)
                self.content = self.content[-65536:]
        if self.status is None:
            ended, status = os.waitpid(self.pid, os.WNOHANG)
            if ended:
                self.status = os.waitstatus_to_exitcode(status)

    def until(self, predicate: Callable[[], bool]) -> None:
        """Wait for a fixture condition with bounded terminal output."""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.pump()
            if predicate():
                return
            assert self.status is None, (self.status, bytes(self.content))
        raise AssertionError(bytes(self.content))

    def send(self, value: bytes) -> None:
        """Write terminal input."""
        os.write(self.fd, value)

    def close(self) -> None:
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


def listening(path: str) -> bool:
    """Say whether anything accepts a connection on the socket `path`.

    A raw connect, because a tmux client waits on a server that has stopped
    answering.
    """
    probe = socket.socket(socket.AF_UNIX)
    probe.settimeout(2)
    try:
        probe.connect(path)
    except TimeoutError:
        return True
    except OSError:
        return False
    finally:
        probe.close()
    return True


def stop_server(
    tmux: str, path: str, environment: Mapping[str, str], seconds: float = 3
) -> bool:
    """Stop the server on the socket `path`, and say whether it stopped.

    `kill-server` returns before the server has left, so this waits up to
    `seconds` for the socket to stop accepting connections before the
    directory under it goes.
    """
    subprocess.run(
        [tmux, "-S", path, "kill-server"],
        env=environment,
        capture_output=True,
        check=False,
        timeout=3,
    )
    deadline = time.monotonic() + seconds
    while listening(path):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)
    return True
