"""Programs the workspace checks run where a person would run an editor or a script.

The first argument picks one, and the rest are the files it records into. The
workspace appends its own file to an editor's command line, which is ignored.

- `edit <pid> <value>` writes its process id, waits for a line, puts the
  terminal in raw mode, prints `READY`, and writes the next line to `<value>`.
- `hold <pid>` does the same up to `READY` and then waits to be stopped.
- `idle <pid>` writes its process id and waits to be stopped.
- `escape` prints a colour escape sequence, which machine output must not pass on.
- `report` prints `OUT` and an escape sequence to stdout and `ERR` to stderr.
- `mark <value>` writes `ran` to `<value>`.
"""

from __future__ import annotations

import os
import signal
import sys
import termios
import time
from pathlib import Path

WAIT_SECONDS = 30


def record_pid(path: str) -> None:
    """Write the process id and a newline, so a reader knows the write ended."""
    Path(path).write_text(f"{os.getpid()}\n", encoding="utf-8")


def ready() -> None:
    """Wait for the first line, switch the terminal to raw mode, and say so."""
    sys.stdin.readline()
    attributes = termios.tcgetattr(0)
    attributes[3] &= ~(termios.ECHO | termios.ICANON)
    termios.tcsetattr(0, termios.TCSANOW, attributes)
    print("READY", flush=True)


def main(argv: list[str]) -> int:
    """Run the program named by `argv[0]`."""
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    mode, files = argv[0], argv[1:]
    if mode in {"edit", "hold"}:
        record_pid(files[0])
        ready()
        if mode == "edit":
            Path(files[1]).write_text(
                sys.stdin.readline().rstrip("\n"), encoding="utf-8"
            )
            return 0
    elif mode == "idle":
        record_pid(files[0])
    elif mode == "escape":
        print("\x1b[31mchild")
        return 0
    elif mode == "report":
        sys.stdout.write("OUT\x1b[31m")
        sys.stderr.write("ERR\n")
        return 0
    elif mode == "mark":
        Path(files[0]).write_text("ran", encoding="utf-8")
        return 0
    time.sleep(WAIT_SECONDS)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
