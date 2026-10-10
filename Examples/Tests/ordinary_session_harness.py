"""Run the unchanged ordinary Swift program on harness-owned endpoints."""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import tempfile
import time
from pathlib import Path

SHIM = r"""#!/usr/bin/python3
import json
import os
import subprocess
import sys

args = sys.argv[1:]
path = args[args.index("-S") + 1] if "-S" in args else None
record = {"args": args, "path": path,
          "environment": {key: os.environ.get(key) for key in
                          ["TMUX", "TMUX_PANE", "TMUX_TMPDIR", "SNAPSHOT_SENTINEL"]}}

def save():
    with open(os.environ["HARNESS_TRACE"], "a") as output:
        output.write(json.dumps(record) + "\n")

if "-C" in args:
    save()
    os.execv(os.environ["HARNESS_TMUX"], ["tmux", "-f", "/dev/null", *args])
text = " ".join(args)
if "new-window" in text and os.environ.get("HARNESS_FAIL_BODY") == "1":
    record["injected_body_failure"] = True
    save()
    print("deliberate ordinary body failure", file=sys.stderr)
    sys.exit(42)
if "kill-session" in text and os.environ.get("HARNESS_BREAK_CLEANUP") == "1":
    record["injected_cleanup_failure"] = True
    args = [argument.replace("kill-session", "has-session") for argument in args]
result = subprocess.run([os.environ["HARNESS_TMUX"], "-f", "/dev/null", *args],
                        capture_output=True)
if path and result.returncode == 0 and ("new-session" in text or "new-window" in text):
    query = subprocess.run([os.environ["HARNESS_TMUX"], "-S", path,
                            "display-message", "-p", "#{pid}"], capture_output=True, text=True)
    record["pid"] = int(query.stdout.strip())
    state = subprocess.run([os.environ["HARNESS_TMUX"], "-S", path,
                            "list-sessions", "-F", "#{session_name}:#{session_windows}"],
                           capture_output=True, text=True)
    record["state"] = state.stdout.splitlines()
record["exit"] = result.returncode
save()
sys.stdout.buffer.write(result.stdout)
sys.stderr.buffer.write(result.stderr)
sys.exit(result.returncode)
"""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def alive(pid: int) -> bool:
    stat = Path(f"/proc/{pid}/stat")
    try:
        state = stat.read_text()
    except FileNotFoundError:
        pass
    else:
        return state.rsplit(")", 1)[1].split()[0] != "Z"
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_stopped(pid: int) -> bool:
    deadline = time.monotonic() + 5
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.02)
    return not alive(pid)


def run_tmux(tmux: str, path: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [tmux, "-f", "/dev/null", "-S", str(path), *args],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )


def stop_owned(tmux: str, path: Path, pids: set[int]) -> None:
    run_tmux(tmux, path, "kill-server")
    for pid in pids:
        if not wait_stopped(pid):
            os.kill(pid, signal.SIGTERM)
            if not wait_stopped(pid):
                os.kill(pid, signal.SIGKILL)
                require(
                    wait_stopped(pid), f"owned daemon {pid} survived harness cleanup"
                )
                raise AssertionError(
                    f"owned daemon {pid} required SIGKILL during harness cleanup"
                )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--snapshot-probe", type=Path)
    parser.add_argument("--break-cleanup", action="store_true")
    options = parser.parse_args()
    # Foundation.Process can inherit its Swift worker thread's blocked signals.
    signal.pthread_sigmask(signal.SIG_SETMASK, set())
    tmux = os.environ.get("LIBTMUX_TMUX_BIN") or "/usr/bin/tmux"
    root = Path("/tmp/libtmux-swift-test")
    root.mkdir(exist_ok=True)
    before = dict(os.environ)
    with tempfile.TemporaryDirectory(prefix="ordinary-", dir=root) as temporary:
        base = Path(temporary)
        binary_dir = base / "bin"
        binary_dir.mkdir()
        shim = binary_dir / "tmux"
        shim.write_text(SHIM)
        shim.chmod(0o700)
        host_path = base / "host"
        require(
            run_tmux(
                tmux, host_path, "new-session", "-d", "-s", "host", "sleep 300"
            ).returncode
            == 0,
            "could not start the private host-preservation witness",
        )
        host_pid = int(
            run_tmux(tmux, host_path, "display-message", "-p", "#{pid}").stdout
        )
        try:
            cases = [("path", False), ("name", False), ("path", True)]
            if options.snapshot_probe:
                cases.append(("snapshot", False))
            for index, (selector, fail_body) in enumerate(cases):
                case = base / str(index)
                case.mkdir()
                name = "selected"
                endpoint = (
                    case / f"tmux-{os.getuid()}" / name
                    if selector in {"name", "snapshot"}
                    else case / "selected"
                )
                trace = case / "trace.jsonl"
                child = dict(before)
                child.update(
                    {
                        "PATH": f"{binary_dir}:/usr/bin:/bin",
                        "HARNESS_TMUX": tmux,
                        "HARNESS_TRACE": str(trace),
                        "HARNESS_FAIL_BODY": "1" if fail_body else "0",
                        "HARNESS_BREAK_CLEANUP": "1" if options.break_cleanup else "0",
                        "TMUX": f"{host_path},{host_pid},0",
                        "TMUX_PANE": "%77",
                        "TMUX_TMPDIR": str(case),
                        "SNAPSHOT_SENTINEL": "captured",
                        "SNAPSHOT_OTHER_ROOT": str(case / "absent"),
                        "LIBTMUX_SOCKET_PATH": str(endpoint)
                        if selector == "path"
                        else "",
                        "LIBTMUX_SOCKET_NAME": ".." if selector == "path" else name,
                    }
                )
                pids: set[int] = set()
                try:
                    executable = (
                        options.snapshot_probe
                        if selector == "snapshot"
                        else options.binary
                    )
                    result = subprocess.run(
                        [str(executable.resolve())],
                        env=child,
                        capture_output=True,
                        text=True,
                        timeout=30,
                        check=False,
                    )
                    records = [
                        json.loads(line) for line in trace.read_text().splitlines()
                    ]
                    pids = {record["pid"] for record in records if "pid" in record}
                    require(len(pids) == 1, f"expected one owned daemon: {records}")
                    require(
                        all(record["path"] == str(endpoint) for record in records),
                        "launch endpoint drifted",
                    )
                    require(
                        all(
                            record["environment"]["TMUX"] is None
                            and record["environment"]["TMUX_PANE"] is None
                            for record in records
                        ),
                        "a client inherited nested tmux context",
                    )
                    require(
                        all(
                            record["environment"]["SNAPSHOT_SENTINEL"] == "captured"
                            for record in records
                        ),
                        "a client reread the host environment",
                    )
                    if selector == "snapshot":
                        require(result.returncode == 0, result.stderr)
                        require(
                            "Snapshot retained; host edits preserved" in result.stdout,
                            result.stdout,
                        )
                        require(
                            any("-C" in record["args"] for record in records),
                            "control mode was not exercised",
                        )
                    elif fail_body:
                        require(
                            result.returncode != 0,
                            "the deliberate body failure was hidden",
                        )
                        require("Example failed:" in result.stderr, result.stderr)
                        require(
                            any(
                                record.get("injected_body_failure")
                                for record in records
                            ),
                            "body injection was not reached",
                        )
                    else:
                        require(result.returncode == 0, result.stderr)
                        require(
                            result.stdout
                            == "Created session with 2 windows\nSession cleaned up\n",
                            result.stdout,
                        )
                        require(
                            any(
                                any(
                                    row.endswith(":2")
                                    for row in record.get("state", [])
                                )
                                for record in records
                            ),
                            "the harness did not observe the created window",
                        )
                    require(
                        all(wait_stopped(pid) for pid in pids),
                        "the example left its daemon running",
                    )
                    require(
                        run_tmux(tmux, endpoint, "list-sessions").returncode != 0,
                        "the owned session survived",
                    )
                    require(
                        run_tmux(
                            tmux, host_path, "list-sessions", "-F", "#{session_name}"
                        ).stdout
                        == "host\n",
                        "the example changed the host witness",
                    )
                    require(
                        dict(os.environ) == before,
                        "the harness changed its host environment",
                    )
                    print(
                        f"{selector} body_failure={fail_body}: effect, captured endpoint/environment, cleanup, daemon exit, host preservation passed"
                    )
                finally:
                    if trace.exists():
                        pids.update(
                            json.loads(line)["pid"]
                            for line in trace.read_text().splitlines()
                            if '"pid"' in line
                        )
                    stop_owned(tmux, endpoint, pids)
        finally:
            stop_owned(tmux, host_path, {host_pid})
    require(dict(os.environ) == before, "the harness changed its host environment")


if __name__ == "__main__":
    main()
