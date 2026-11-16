"""A `swift` that records what the wrapper hands it.

It writes to the file named by `RECORD_TO`: its arguments one per line, the
mode of the directory `TMUX_TMPDIR` names, the name of every variable it was
handed, a checksum that tells two directories apart, and booleans for the
questions the tests ask of `TMUX_TMPDIR`. Never a value, so no failure can
print part of an environment. The booleans compare against `EXPECT_PARENT` and
`INHERITED_TMPDIR`, which the tests set. It exits with `RECORD_STATUS`.
"""

from __future__ import annotations

import os
import re
import stat
import sys
import zlib
from pathlib import Path


def under(directory: str, parent: str) -> bool:
    """Say whether `directory` is a `tmux-XXXXXX` entry of `parent`."""
    return re.fullmatch(re.escape(parent) + "/tmux-[^/]{6}", directory) is not None


def main() -> int:
    """Write the record and return the status the test asked for."""
    tmpdir = os.environ.get("TMUX_TMPDIR", "")
    sandbox = os.environ.get("LIBTMUX_TEST_SANDBOX", "")
    inherited = os.environ.get("INHERITED_TMPDIR", "")
    parent = os.environ.get("EXPECT_PARENT", "/nonexistent")
    lines = [f"arg={argument}" for argument in sys.argv[1:]]
    if tmpdir and Path(tmpdir).exists():
        lines.append(f"mode={stat.filemode(Path(tmpdir).stat().st_mode)}")
    lines += [f"name={name}" for name in os.environ]
    lines.append(f"directory_id={zlib.crc32(tmpdir.encode())}")
    flags = {
        "under_root": under(tmpdir, "/tmp/libtmux-swift-test"),
        "marker_matches": bool(sandbox) and tmpdir == sandbox,
        "under_parent": under(tmpdir, parent),
        "inherited": bool(inherited) and tmpdir == inherited,
        "exists": bool(tmpdir) and Path(tmpdir).is_dir(),
    }
    lines += [f"flag={name}" for name, held in flags.items() if held]
    Path(os.environ["RECORD_TO"]).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return int(os.environ.get("RECORD_STATUS", "0"))


if __name__ == "__main__":
    sys.exit(main())
