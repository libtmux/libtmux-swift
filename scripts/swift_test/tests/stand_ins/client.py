"""A tmux client that cannot stop a server, chosen by `CLIENT_MODE`.

- `noop` does nothing and says it worked.
- `mismatch` answers as tmux does when it cannot speak to the daemon.
- `slow` returns at once and stops the server a second later, with
  `TMUX_UNDER_TEST`, on the socket after `-S`.
"""

from __future__ import annotations

import os
import sys
import time


def stop_later(socket_path: str) -> None:
    """Fork a process that stops the server on `socket_path` after a second."""
    if os.fork() != 0:
        return
    os.setsid()
    null = os.open(os.devnull, os.O_RDWR)
    for descriptor in (0, 1, 2):
        os.dup2(null, descriptor)
    time.sleep(1)
    tmux = os.environ["TMUX_UNDER_TEST"]
    os.execv(tmux, [tmux, "-f", "/dev/null", "-S", socket_path, "kill-server"])


def main() -> int:
    """Behave as `CLIENT_MODE` says and return the status tmux would."""
    mode = os.environ["CLIENT_MODE"]
    if mode == "mismatch":
        print("protocol version mismatch (client 9, server 8)", file=sys.stderr)
        return 1
    if mode == "slow":
        stop_later(sys.argv[4])
    return 0


if __name__ == "__main__":
    sys.exit(main())
