"""Tests for the script that runs the suite without ambient tmux selectors.

The script is run against a stand-in for `swift`, never the suite. Most
stand-ins record their arguments, the names of the variables they were handed
and a few booleans about them, never a value, so no failure here can print part
of an environment. The leak tests use a stand-in that starts a real tmux on the
sandbox the wrapper made for it, with no -L or -S, and nothing else. Each
stand-in is a Python program under `stand_ins/`, run with the interpreter that
runs the tests.
"""

import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Iterator
from pathlib import Path

import pytest
import swift_test

WRAPPER = Path(__file__).parents[1] / "swift_test.py"
STAND_INS = Path(__file__).parent / "stand_ins"

ROOT = Path("/tmp/libtmux-swift-test")

DECOYS = {
    "TMUX": "/decoy/socket,1,0",
    "TMUX_PANE": "%9",
    "LIBTMUX_SOCKET": "decoy-name",
    "LIBTMUX_SOCKET_PATH": "/decoy/path",
    "LIBTMUX_SOCKET_EXTRA": "decoy-extra",
}


class Recorded:
    """What one run of the stand-in wrote."""

    def __init__(self, text: str) -> None:
        """Parse the record, or an empty one when the stand-in never ran."""
        self.arguments: list[str] = []
        self.names: set[str] = set()
        self.flags: set[str] = set()
        self.mode = ""
        self.directory_id = ""
        for line in text.splitlines():
            key, _, value = line.partition("=")
            if key == "arg":
                self.arguments.append(value)
            elif key == "name":
                self.names.add(value)
            elif key == "flag":
                self.flags.add(value)
            elif key == "mode":
                self.mode = value
            elif key == "directory_id":
                self.directory_id = value


def install(program: str, path: Path) -> Path:
    """Install the stand-in `program` as the executable `path`.

    The shebang names the interpreter that runs the tests, so a stand-in needs
    nothing from `PATH`, which the tests restrict.
    """
    source = (STAND_INS / f"{program}.py").read_text(encoding="utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!{sys.executable}\n{source}", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


@pytest.fixture
def stand_in(tmp_path: Path) -> Path:
    """Put a recording `swift` first on PATH and return its directory."""
    install("recorder", tmp_path / "bin" / "swift")
    return tmp_path / "bin"


def run(
    tmp_path: Path,
    stand_in: Path,
    *arguments: str,
    environment: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], Recorded]:
    """Run the wrapper and return the process and what the stand-in recorded."""
    record = tmp_path / "record"
    record.unlink(missing_ok=True)
    env = {
        "PATH": f"{stand_in}{os.pathsep}/usr/bin{os.pathsep}/bin",
        "RECORD_TO": str(record),
        **(environment or {}),
    }
    finished = subprocess.run(
        [sys.executable, str(WRAPPER), *arguments],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    text = record.read_text(encoding="utf-8") if record.exists() else ""
    return finished, Recorded(text)


def _resolve_test_tmux() -> str | None:
    """Resolve the tmux executable for the leak tests."""
    for name in ("LIBTMUX_TEST_TMUX", "LIBTMUX_TMUX_BIN"):
        value = os.environ.get(name, "")
        if value.strip():
            return shutil.which(value) or value
    return shutil.which("tmux")


TMUX = _resolve_test_tmux()

needs_tmux = pytest.mark.skipif(TMUX is None, reason="needs a tmux to leak")


def alive(pid: int) -> bool:
    """Say whether a process with this id exists."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def gone(pid: int) -> bool:
    """Wait a few seconds for a process to exit, and say whether it did."""
    deadline = time.monotonic() + 5
    while alive(pid) and time.monotonic() < deadline:
        time.sleep(0.05)
    return not alive(pid)


def is_tmux_server(pid: int) -> bool:
    """Say whether this id is a tmux server, so cleanup never kills anything else."""
    shown = subprocess.run(
        ["ps", "-p", str(pid), "-o", "comm="],
        capture_output=True,
        text=True,
        check=False,
    )
    return shown.stdout.strip().startswith("tmux")


Leaker = tuple[Path, Path, Path]


@pytest.fixture
def leaker() -> Iterator[Leaker]:
    """Put a leaking `swift` on PATH and stop any server it started afterwards.

    The wrapper is given a parent of its own to make its directory in, so the
    server lands on a socket nobody else can reach. A test that fails because
    the wrapper let a server live must not leave it running, so the server's id
    is read back and, if it is a tmux server and still alive, terminated.
    """
    scratch = Path(tempfile.mkdtemp(prefix="sw-"))
    install("leaker", scratch / "bin" / "swift")
    install("client", scratch / "client" / "tmux")
    parent = scratch / "parent"
    pid_file = scratch / "pid"
    yield scratch, pid_file, parent
    if pid_file.exists() and pid_file.read_text(encoding="utf-8").strip().isdigit():
        pid = int(pid_file.read_text(encoding="utf-8"))
        if alive(pid) and is_tmux_server(pid):
            os.kill(pid, 15)
            gone(pid)
    shutil.rmtree(scratch, ignore_errors=True)


def leak_run(
    leaker: Leaker,
    mode: str,
    client: str | None = None,
    **extra: str,
) -> tuple[subprocess.CompletedProcess[str], int | None]:
    """Run the wrapper over the leaking stand-in; return it and the server id.

    With `client`, the wrapper's tmux is the stand-in client in that mode,
    which cannot stop a server, both on PATH and in LIBTMUX_TEST_TMUX.
    """
    scratch, pid_file, parent = leaker
    broken = f"{scratch / 'client'}{os.pathsep}" if client else ""
    env = {
        "PATH": f"{broken}{scratch / 'bin'}{os.pathsep}/usr/bin{os.pathsep}/bin",
        "MODE": mode,
        "CLIENT_MODE": client or "",
        "PID_FILE": str(pid_file),
        "OUTSIDE": str(scratch / "outside.sock"),
        "TMUX_UNDER_TEST": str(TMUX),
        "LIBTMUX_TEST_TMUX": str(scratch / "client" / "tmux") if client else str(TMUX),
        "LIBTMUX_TEST_TMUX_TMPDIR": str(parent),
        **extra,
    }
    finished = subprocess.run(
        [sys.executable, str(WRAPPER)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    text = pid_file.read_text(encoding="utf-8").strip() if pid_file.exists() else ""
    return finished, int(text) if text.isdigit() else None


def test_every_selector_is_removed(tmp_path: Path, stand_in: Path) -> None:
    """TMUX, TMUX_PANE and every LIBTMUX_SOCKET* variable are gone."""
    finished, seen = run(tmp_path, stand_in, environment=DECOYS)

    assert finished.returncode == 0, finished.stderr
    assert sorted(set(DECOYS) & seen.names) == []


def test_the_recorder_sees_a_selector_when_nothing_removes_it(
    tmp_path: Path, stand_in: Path
) -> None:
    """Negative control: without the wrapper the same decoys reach `swift`."""
    record = tmp_path / "record"
    env = {
        "PATH": f"{stand_in}{os.pathsep}/usr/bin{os.pathsep}/bin",
        "RECORD_TO": str(record),
        "TMUX_TMPDIR": str(tmp_path),
        **DECOYS,
    }
    subprocess.run(["swift"], env=env, check=True)

    seen = Recorded(record.read_text(encoding="utf-8"))
    assert sorted(set(DECOYS) - seen.names) == []


def test_unrelated_variables_survive(tmp_path: Path, stand_in: Path) -> None:
    """Other LIBTMUX_ variables are the suite's own settings, not selectors."""
    kept = {
        "LIBTMUX_TEST_TMUX",
        "LIBTMUX_TMUX_BIN",
        "LIBTMUX_TMUX_CLIENT_BIN",
        "LIBTMUX_EXPECT_REFUSAL",
    }
    finished, seen = run(
        tmp_path, stand_in, environment={**dict.fromkeys(kept, "kept"), **DECOYS}
    )

    assert finished.returncode == 0, finished.stderr
    assert sorted(kept - seen.names) == []


@pytest.mark.parametrize("blank", ["", " ", " \t\n "])
def test_candidate_clients_orders_test_tmux_ahead_of_fallbacks_and_ignores_blank(
    blank: str,
) -> None:
    """LIBTMUX_TEST_TMUX comes first untrimmed; blank values count as unset."""
    assert swift_test.candidate_clients(
        {
            "LIBTMUX_TEST_TMUX": " /opt/test/tmux ",
            "LIBTMUX_TMUX_BIN": "/opt/legacy/tmux",
            "LIBTMUX_TMUX_CLIENT_BIN": "/opt/client/tmux",
        }
    ) == (" /opt/test/tmux ", "/opt/legacy/tmux", "/opt/client/tmux", "tmux")

    assert swift_test.candidate_clients(
        {
            "LIBTMUX_TEST_TMUX": blank,
            "LIBTMUX_TMUX_BIN": "/opt/legacy/tmux",
            "LIBTMUX_TMUX_CLIENT_BIN": blank,
        }
    ) == ("", "/opt/legacy/tmux", "", "tmux")


def test_tmux_tmpdir_is_a_fresh_private_directory_under_the_root(
    tmp_path: Path, stand_in: Path
) -> None:
    """The caller's TMUX_TMPDIR is replaced, and the replacement is owner-only."""
    finished, seen = run(
        tmp_path,
        stand_in,
        environment={
            "TMUX_TMPDIR": str(tmp_path / "users-own"),
            "INHERITED_TMPDIR": str(tmp_path / "users-own"),
        },
    )

    assert finished.returncode == 0, finished.stderr
    assert "under_root" in seen.flags
    assert "inherited" not in seen.flags
    assert "marker_matches" in seen.flags
    assert seen.mode == "drwx------"


def test_each_run_gets_its_own_directory_and_removes_it(
    tmp_path: Path, stand_in: Path
) -> None:
    """A directory made for one run is neither reused nor left behind."""
    before = set(ROOT.iterdir()) if ROOT.exists() else set()
    _, first = run(tmp_path, stand_in)
    _, second = run(tmp_path, stand_in)
    after = set(ROOT.iterdir()) if ROOT.exists() else set()

    assert first.directory_id != second.directory_id
    assert "exists" in first.flags
    assert after - before == set()


def test_arguments_and_the_exit_status_pass_through(
    tmp_path: Path, stand_in: Path
) -> None:
    """Whatever follows the script name is `swift test`'s, and so is its status."""
    before = set(ROOT.iterdir()) if ROOT.exists() else set()
    finished, seen = run(
        tmp_path,
        stand_in,
        "--traits",
        "YAMLWorkspaces",
        "--filter",
        "a b",
        environment={"RECORD_STATUS": "7"},
    )
    after = set(ROOT.iterdir()) if ROOT.exists() else set()

    assert seen.arguments == ["test", "--traits", "YAMLWorkspaces", "--filter", "a b"]
    assert finished.returncode == 7
    assert after - before == set()


@pytest.mark.parametrize(
    ("sent", "status"), [(signal.SIGINT, 130), (signal.SIGTERM, 143)]
)
def test_a_signal_reaches_swift_and_the_run_ends_after_it(
    tmp_path: Path, stand_in: Path, sent: signal.Signals, status: int
) -> None:
    """The signal is forwarded, the run waits for `swift test`, cleans up, then exits.

    The stand-in takes a moment to finish after the signal, and the run exits
    128 plus the signal only once it has.
    """
    install("blocker", stand_in / "swift")
    finished = tmp_path / "finished"
    before = set(ROOT.iterdir()) if ROOT.exists() else set()

    with subprocess.Popen(
        [sys.executable, str(WRAPPER)],
        env={
            "PATH": f"{stand_in}{os.pathsep}/usr/bin{os.pathsep}/bin",
            "FINISHED": str(finished),
        },
        stdout=subprocess.PIPE,
        text=True,
    ) as running:
        assert running.stdout is not None
        assert running.stdout.readline() == "started\n"
        running.send_signal(sent)
        code = running.wait(timeout=10)
        reported = running.stdout.read()

    after = set(ROOT.iterdir()) if ROOT.exists() else set()
    assert reported == f"signalled {sent.value}\n"
    assert code == status
    assert finished.exists(), "the run ended before swift did"
    assert after - before == set()


@pytest.mark.parametrize("kind", ["group-writable", "link", "file"])
def test_a_shared_root_the_caller_does_not_own_alone_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, kind: str
) -> None:
    """A root others can write to, or that is not a directory, is not used."""
    root = tmp_path / "root"
    if kind == "link":
        (tmp_path / "elsewhere").mkdir()
        root.symlink_to(tmp_path / "elsewhere", target_is_directory=True)
    elif kind == "file":
        root.write_text("", encoding="utf-8")
    else:
        root.mkdir()
        root.chmod(0o770)
    monkeypatch.setattr(swift_test, "ROOT", root)

    with pytest.raises(swift_test.RefusedError):
        swift_test.shared_root()


def test_a_shared_root_that_only_the_caller_can_write_is_used(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Control: an owner-only root is returned as it is."""
    monkeypatch.setattr(swift_test, "ROOT", tmp_path / "root")

    assert swift_test.shared_root() == tmp_path / "root"
    assert modes(tmp_path / "root") == 0o700


def modes(path: Path) -> int:
    """Return the permission bits of `path`."""
    return stat.S_IMODE(path.stat().st_mode)


def test_a_parent_the_caller_names_is_created_and_holds_a_fresh_directory(
    tmp_path: Path, stand_in: Path, short_parent: Path
) -> None:
    """LIBTMUX_TEST_TMUX_TMPDIR is a parent: the run's directory is made inside it."""
    parent = short_parent / "mine" / "nested"
    finished, seen = run(
        tmp_path,
        stand_in,
        environment={
            "LIBTMUX_TEST_TMUX_TMPDIR": str(parent),
            "EXPECT_PARENT": str(parent),
        },
    )

    assert finished.returncode == 0, finished.stderr
    assert {"under_parent", "marker_matches", "exists"} <= seen.flags
    assert seen.mode == "drwx------"
    assert list(parent.iterdir()) == []


def test_an_empty_parent_is_used_and_its_mode_is_left_alone(
    tmp_path: Path, stand_in: Path, short_parent: Path
) -> None:
    """An existing directory is never chmodded, whatever its mode."""
    parent = short_parent / "mine"
    parent.mkdir()
    parent.chmod(0o755)
    finished, seen = run(
        tmp_path,
        stand_in,
        environment={
            "LIBTMUX_TEST_TMUX_TMPDIR": str(parent),
            "EXPECT_PARENT": str(parent),
        },
    )

    assert finished.returncode == 0, finished.stderr
    assert "under_parent" in seen.flags
    assert modes(parent) == 0o755
    assert list(parent.iterdir()) == []


@pytest.mark.parametrize("kind", ["not-empty", "socket-directory", "link", "file"])
def test_a_directory_that_may_be_in_use_is_refused_untouched(
    tmp_path: Path, stand_in: Path, short_parent: Path, kind: str
) -> None:
    """A parent that is not new or empty is refused before swift runs."""
    parent = short_parent / "theirs"
    parent.mkdir()
    parent.chmod(0o755)
    named = parent
    if kind == "not-empty":
        (parent / "keep").write_text("kept", encoding="utf-8")
    elif kind == "socket-directory":
        (parent / f"tmux-{os.getuid()}").mkdir()
    elif kind == "link":
        named = short_parent / "link"
        named.symlink_to(parent, target_is_directory=True)
    else:
        named = short_parent / "file"
        named.write_text("kept", encoding="utf-8")

    finished, seen = run(
        tmp_path, stand_in, environment={"LIBTMUX_TEST_TMUX_TMPDIR": str(named)}
    )

    assert finished.returncode == 2
    assert "LIBTMUX_TEST_TMUX_TMPDIR" in finished.stderr
    assert seen.names == set()
    assert modes(parent) == 0o755
    assert sorted(entry.name for entry in parent.iterdir()) == sorted(
        {
            "not-empty": ["keep"],
            "socket-directory": [f"tmux-{os.getuid()}"],
        }.get(kind, [])
    )
    if kind == "file":
        assert named.read_text(encoding="utf-8") == "kept"


def test_the_refusal_for_a_socket_directory_says_so(
    tmp_path: Path, stand_in: Path, short_parent: Path
) -> None:
    """A directory holding tmux's own tmux-<uid> is told apart from a full one."""
    (short_parent / "theirs").mkdir()
    (short_parent / "theirs" / f"tmux-{os.getuid()}").mkdir()

    finished, _ = run(
        tmp_path,
        stand_in,
        environment={"LIBTMUX_TEST_TMUX_TMPDIR": str(short_parent / "theirs")},
    )

    assert finished.returncode == 2
    assert "socket directory" in finished.stderr


def test_a_relative_directory_is_refused_before_swift_runs(
    tmp_path: Path, stand_in: Path
) -> None:
    """A path that depends on the working directory is not a private one."""
    finished, seen = run(
        tmp_path, stand_in, environment={"LIBTMUX_TEST_TMUX_TMPDIR": "relative/dir"}
    )

    assert finished.returncode == 2
    assert "absolute" in finished.stderr
    assert seen.names == set()


@needs_tmux
def test_a_server_the_run_left_fails_the_run_and_is_stopped(leaker: Leaker) -> None:
    """Removing a live server's socket strands it, so the wrapper stops it first."""
    finished, pid = leak_run(leaker, "leak")

    assert pid is not None, finished.stderr
    assert finished.returncode == 3
    assert "left a tmux server" in finished.stderr
    assert "default" in finished.stderr
    assert gone(pid), "the server outlived the wrapper"
    assert list(leaker[2].iterdir()) == []


@needs_tmux
@pytest.mark.parametrize(
    ("mode", "named"), [("custom", "custom.sock"), ("nested", "deep/er/custom.sock")]
)
def test_a_server_on_a_socket_the_run_named_is_found_and_stopped(
    leaker: Leaker, mode: str, named: str
) -> None:
    """A socket given with -S inside the sandbox is a leak wherever it sits."""
    finished, pid = leak_run(leaker, mode)

    assert pid is not None, finished.stderr
    assert finished.returncode == 3
    assert "left a tmux server" in finished.stderr
    assert named in finished.stderr
    assert gone(pid), "the server outlived the wrapper"
    assert list(leaker[2].iterdir()) == []


@needs_tmux
def test_a_failing_run_that_also_leaked_keeps_its_status(leaker: Leaker) -> None:
    """The child's own failure is not hidden by the leak, and the server still goes."""
    finished, pid = leak_run(leaker, "custom", RECORD_STATUS="7")

    assert pid is not None, finished.stderr
    assert finished.returncode == 7
    assert "left a tmux server" in finished.stderr
    assert gone(pid), "the server outlived the wrapper"


@needs_tmux
def test_a_run_that_stops_its_own_server_passes(leaker: Leaker) -> None:
    """Control: the same server, stopped by the run, is not reported."""
    finished, pid = leak_run(leaker, "clean")

    assert pid is not None, finished.stderr
    assert finished.returncode == 0, finished.stderr
    assert "left a tmux server" not in finished.stderr
    assert gone(pid)
    assert list(leaker[2].iterdir()) == []


@needs_tmux
def test_a_socket_file_nothing_listens_on_is_not_a_leak(leaker: Leaker) -> None:
    """A server that exited leaves its socket file behind, wherever it was."""
    finished, _ = leak_run(leaker, "stale")

    assert finished.returncode == 0, finished.stderr
    assert finished.stderr == ""
    assert list(leaker[2].iterdir()) == []


@needs_tmux
def test_a_link_to_a_socket_outside_the_sandbox_is_left_alone(leaker: Leaker) -> None:
    """The scan does not follow links, so it never stops a server it did not own."""
    finished, pid = leak_run(leaker, "link")

    assert pid is not None, finished.stderr
    assert finished.returncode == 0, finished.stderr
    assert finished.stderr == ""
    assert alive(pid), "the wrapper stopped a server outside the sandbox"
    assert list(leaker[2].iterdir()) == []


@needs_tmux
def test_a_server_that_takes_a_moment_to_stop_is_waited_for(leaker: Leaker) -> None:
    """The check retries for a few seconds, so a slow stop is not called a failure."""
    finished, pid = leak_run(leaker, "custom", client="slow")

    assert pid is not None, finished.stderr
    assert finished.returncode == 3
    assert "now stopped" in finished.stderr
    assert "could not be stopped" not in finished.stderr
    assert gone(pid), "the server outlived the wrapper"
    assert list(leaker[2].iterdir()) == []


@needs_tmux
@pytest.mark.parametrize(
    ("client", "mode", "named"),
    [("noop", "custom", "custom.sock"), ("mismatch", "leak", "default")],
)
def test_a_server_that_is_not_stopped_keeps_its_directory_and_fails(
    leaker: Leaker, client: str, mode: str, named: str
) -> None:
    """A stop that did not work is caught: the server still answers, so nothing goes."""
    finished, pid = leak_run(leaker, mode, client=client)

    assert pid is not None, finished.stderr
    assert finished.returncode == 3
    assert "could not be stopped" in finished.stderr
    assert named in finished.stderr
    assert alive(pid)
    assert len(list(leaker[2].iterdir())) == 1


@pytest.fixture
def short_parent() -> Iterator[Path]:
    """Make a parent directory with a short path, for the length tests."""
    parent = Path(tempfile.mkdtemp(prefix="sw-"))
    yield parent
    shutil.rmtree(parent, ignore_errors=True)


def parent_with_default_socket_of(short_parent: Path, length: int) -> Path:
    """Return a parent whose default socket path would be `length` bytes."""
    suffix = len(f"/tmux-XXXXXX/tmux-{os.getuid()}/default")
    padding = length - suffix - len(str(short_parent)) - 1
    return short_parent / ("p" * padding)


def test_a_parent_at_the_socket_limit_is_accepted(
    tmp_path: Path, stand_in: Path, short_parent: Path
) -> None:
    """A default socket of exactly 100 bytes still fits an address."""
    parent = parent_with_default_socket_of(short_parent, 100)
    finished, seen = run(
        tmp_path,
        stand_in,
        environment={
            "LIBTMUX_TEST_TMUX_TMPDIR": str(parent),
            "EXPECT_PARENT": str(parent),
        },
    )

    assert finished.returncode == 0, finished.stderr
    assert "under_parent" in seen.flags


def test_a_parent_past_the_socket_limit_is_refused_and_not_created(
    tmp_path: Path, stand_in: Path, short_parent: Path
) -> None:
    """One byte over, a socket path would not fit, so nothing is made or run."""
    parent = parent_with_default_socket_of(short_parent, 101)
    finished, seen = run(
        tmp_path, stand_in, environment={"LIBTMUX_TEST_TMUX_TMPDIR": str(parent)}
    )

    assert finished.returncode == 2
    assert "too long" in finished.stderr
    assert "LIBTMUX_TEST_TMUX_TMPDIR" in finished.stderr
    assert seen.names == set()
    assert not parent.exists()
