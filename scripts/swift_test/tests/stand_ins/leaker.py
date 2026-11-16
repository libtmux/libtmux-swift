"""A `swift` that does what a case does when it leaks a tmux server.

The server starts on tmux's default socket, which is under the wrapper's
`TMUX_TMPDIR` because the wrapper removed `TMUX`, or on a socket the stand-in
names itself with `-S`. `MODE` picks what it does about the server. The tmux
to start is `TMUX_UNDER_TEST`, and the id of the server it starts goes to
`PID_FILE`. It exits with `RECORD_STATUS`.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path

TMUX = os.environ.get("TMUX_UNDER_TEST", "tmux")
TMPDIR = Path(os.environ.get("TMUX_TMPDIR", ""))


def start(*extra: str) -> None:
    """Start a server that sleeps for an hour, and record its process id."""
    with Path(os.environ["PID_FILE"]).open("w", encoding="utf-8") as pid_file:
        subprocess.run(
            [
                TMUX,
                "-f",
                "/dev/null",
                *extra,
                "new-session",
                "-d",
                "-s",
                "leak",
                "-P",
                "-F",
                "#{pid}",
                "sleep",
                "3600",
            ],
            stdout=pid_file,
            check=True,
        )


def bind(path: Path) -> None:
    """Leave a socket file that nothing listens on."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with socket.socket(socket.AF_UNIX) as stale:
        stale.bind(str(path))


def stop() -> None:
    """Stop the server through its own client and wait for it to exit."""
    subprocess.run([TMUX, "kill-server"], check=True)
    pid = int(Path(os.environ["PID_FILE"]).read_text(encoding="utf-8"))
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.01)


def main() -> int:
    """Act out `MODE` and return the status the test asked for."""
    mode = os.environ["MODE"]
    if mode == "leak":
        start()
    elif mode == "custom":
        start("-S", str(TMPDIR / "custom.sock"))
    elif mode == "nested":
        (TMPDIR / "deep" / "er").mkdir(parents=True)
        start("-S", str(TMPDIR / "deep" / "er" / "custom.sock"))
    elif mode == "clean":
        start()
        stop()
    elif mode == "stale":
        bind(TMPDIR / f"tmux-{os.getuid()}" / "stale")
        bind(TMPDIR / "deep" / "er" / "stale.sock")
    elif mode == "link":
        start("-S", os.environ["OUTSIDE"])
        (TMPDIR / "link.sock").symlink_to(os.environ["OUTSIDE"])
    return int(os.environ.get("RECORD_STATUS", "0"))


if __name__ == "__main__":
    sys.exit(main())
