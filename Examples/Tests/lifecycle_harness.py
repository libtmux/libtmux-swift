"""Execute ordinary programs unchanged with per-child tmux defaults."""

from __future__ import annotations

import argparse
import json
import os
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary_directory", type=Path)
    args = parser.parse_args()
    signal.pthread_sigmask(signal.SIG_SETMASK, set())
    before = dict(os.environ)
    tmux = os.environ.get("LIBTMUX_TMUX_BIN") or "/usr/bin/tmux"
    root = Path(
        tempfile.mkdtemp(prefix="lifecycle-examples-", dir="/tmp/libtmux-swift-test")
    )
    sockets = root / f"tmux-{os.getuid()}"
    sockets.mkdir(mode=0o700)
    socket = sockets / "default"
    env = {
        k: v
        for k, v in os.environ.items()
        if k not in {"TMUX", "TMUX_PANE", "LIBTMUX_SOCKET_PATH", "LIBTMUX_SOCKET_NAME"}
    }
    env["TMUX_TMPDIR"] = str(root)
    # The binaries select tmux through PATH; the harness selects the matrix
    # binary and empty startup configuration outside the example source.
    bin_dir = root / "bin"
    bin_dir.mkdir()
    shim = bin_dir / "tmux"
    shim.write_text("#!/bin/sh\nexec " + shlex.quote(tmux) + ' -f /dev/null "$@"\n')
    shim.chmod(0o700)
    env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
    env["LIBTMUX_SOCKET_NAME"] = "default"
    handles: dict[int, int] = {}

    def command(path: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [tmux, "-f", "/dev/null", "-S", str(path), *arguments],
            env=env,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )

    success = False
    try:
        started = command(
            socket, "new-session", "-d", "-s", "harness-keeper", "sleep 300"
        )
        if started.returncode:
            raise AssertionError(started.stderr)
        pid = int(command(socket, "display-message", "-p", "#{pid}").stdout)
        handles[pid] = os.pidfd_open(pid)
        for name, expected in [
            ("OwnedHierarchy", "Owned hierarchy cleaned up"),
            ("AdoptExisting", "Adopted session cleaned up"),
            ("FindResources", "First created: true; second created: false"),
            ("DiscoverRunning", str(socket)),
            ("OwnDisposableServer", "Owned daemon exited"),
            ("FixtureLifecycle", "Fixture daemon exited and its root was removed"),
        ]:
            result = subprocess.run(
                [str(args.binary_directory / name)],
                env=env,
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
            if result.returncode != 0 or expected not in result.stdout:
                raise AssertionError(
                    f"{name}: {result.returncode}: {result.stdout}: {result.stderr}"
                )
            current = command(socket, "list-sessions", "-F", "#{session_name}")
            if current.stdout.splitlines() != ["harness-keeper"]:
                raise AssertionError(f"{name} retained resources: {current.stdout}")
            print(
                json.dumps(
                    {
                        "program": name,
                        "exit": result.returncode,
                        "stdout": result.stdout,
                        "keeper_survived": True,
                    }
                )
            )
        success = True
    finally:
        # Capture only live daemons in this call's private directory, including
        # a failed whole-server example. A failed probe retains the root.
        cleanup_ok = True
        for path in sockets.iterdir():
            probe = command(path, "display-message", "-p", "#{pid}")
            if probe.returncode == 0:
                pid = int(probe.stdout)
                if pid not in handles:
                    handles[pid] = os.pidfd_open(pid)
                killed = command(path, "kill-server")
                cleanup_ok &= killed.returncode == 0
            elif (
                "no server running" not in probe.stderr
                and "No such file" not in probe.stderr
            ):
                cleanup_ok = False
        for fd in handles.values():
            cleanup_ok &= bool(select.select([fd], [], [], 5)[0])
            os.close(fd)
        if cleanup_ok:
            shutil.rmtree(root)
        if dict(os.environ) != before:
            raise AssertionError("harness changed the host environment")
        if not cleanup_ok:
            raise AssertionError(
                f"cleanup did not confirm daemon exit; retained {root}"
            )
        print(
            json.dumps(
                {
                    "root_removed": True,
                    "observed_daemon_exit": True,
                    "host_environment_unchanged": True,
                    "programs_passed": success,
                }
            )
        )


if __name__ == "__main__":
    main()
