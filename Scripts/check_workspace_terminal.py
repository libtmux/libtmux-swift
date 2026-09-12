from __future__ import annotations

import json
import os
import pty
import select
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
base = Path("/tmp/libtmux-swift-dev")
base.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="editor-", dir=base) as directory:
    root = Path(directory)
    workspace = root / "edit.json"
    workspace.write_text("{}")
    editor = root / "editor"
    editor.write_text(
        '#!/bin/sh\ntest -t 0 && test -t 1 || exit 11\nprintf "READY\\n"\nread value\nprintf "%s" "$value" > "$MARKER"\n'
    )
    editor.chmod(0o700)
    env = dict(os.environ, EDITOR=str(editor), MARKER=str(root / "marker"))
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(binary, [binary, "edit", str(workspace)], env)
    content = bytearray()
    status = None
    sent = False
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    content += os.read(fd, 65536)
                except OSError:
                    pass
            if b"READY" in content and not sent:
                os.write(fd, b"edited\n")
                sent = True
            ended, state = os.waitpid(pid, os.WNOHANG)
            if ended:
                status = os.waitstatus_to_exitcode(state)
                break
        assert status == 0, (status, bytes(content))
        assert (root / "marker").read_text() == "edited"
        machine = subprocess.run(
            [binary, "edit", str(workspace), "--ndjson"],
            env=dict(env, EDITOR="/bin/sh -c 'printf \"\\033[31mchild\\n\"'"),
            capture_output=True,
            timeout=5,
        )
        assert machine.returncode == 0, machine.stderr
        record = json.loads(machine.stdout)
        assert record["stdout"] == "\x1b[31mchild\n"
        assert b"\x1b" not in machine.stdout
        print(json.dumps({"human_pty_editor": "pass", "machine_control_bytes": "pass"}))
    finally:
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)
