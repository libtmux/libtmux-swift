"""Own a child process attached to a pty, and wait on its output.

check_workspace_attach.py and check_workspace_terminal.py both drive a
process through a controlling terminal and need the same three things: fork
it under a pty, wait for a fixture condition in its output or exit, and reap
it whether or not it exited on its own.
"""

from __future__ import annotations

import os
import pty
import select
import signal
import time
from contextlib import suppress


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
