"""A `swift` that waits for the signal the wrapper is sent, and reports it.

It blocks SIGINT and SIGTERM, prints `started`, waits for one of them, prints
`signalled <number>`, takes a moment to finish, and records in `FINISHED` that
it did. A wrapper that exits before the child ends leaves no such file. With no
signal it prints `unsignalled` and exits 9 after `PATIENCE` seconds.
"""

import os
import signal
import sys
import time
from pathlib import Path

SIGNALS = {signal.SIGINT, signal.SIGTERM}


def main() -> int:
    """Wait for a signal, report it, and finish after a short delay."""
    signal.pthread_sigmask(signal.SIG_BLOCK, SIGNALS)
    print("started", flush=True)
    caught = signal.sigtimedwait(SIGNALS, float(os.environ.get("PATIENCE", "5")))
    if caught is None:
        print("unsignalled", flush=True)
        return 9
    print(f"signalled {caught.si_signo}", flush=True)
    time.sleep(0.2)
    Path(os.environ["FINISHED"]).write_text("done", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
