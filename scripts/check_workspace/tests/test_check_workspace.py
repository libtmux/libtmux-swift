"""Tests for the workspace CLI checks and the terminal helper they share.

The checks drive a `tmux-workspace` executable through a terminal and a private
tmux. Against a stand-in that does nothing, each must fail: that is what shows
they can. CI runs them against the executable it built.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import check_workspace_attach as attach
import check_workspace_progress as progress
import check_workspace_terminal as terminal
import pytest
from owned_terminal import Terminal, listening, stop_server

PLAIN = {"PATH": "/usr/bin:/bin"}

TMUX = os.environ.get("LIBTMUX_TMUX_BIN") or shutil.which("tmux")

needs_tmux = pytest.mark.skipif(TMUX is None, reason="needs a tmux")


@pytest.fixture
def stand_in() -> str:
    """Return an executable that exits 1 at once, whatever it is asked."""
    found = shutil.which("false")
    assert found is not None, "needs a `false` on PATH"
    return found


def test_release_key_orders_builds_the_way_the_library_does() -> None:
    """`next-X.Y` < `X.Y-rc` < `X.Y-rcN` < `X.Y` < the point release."""
    ordered = ["3.7b", "next-3.8", "3.8-rc", "3.8-rc2", "3.8", "3.8a", "3.9"]

    keys = [attach.release_key(token) for token in ordered]

    assert keys == sorted(keys)
    assert len(set(keys)) == len(keys)


def test_release_key_refuses_a_token_that_is_not_a_version(
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A tmux that prints something else is reported, not ordered by guess."""
    with pytest.raises(SystemExit) as stopped:
        attach.release_key("banana")

    assert stopped.value.code == 1
    assert "cannot read a tmux version" in capsys.readouterr().err


def test_a_terminal_relays_input_and_reports_the_exit_status() -> None:
    """The helper forks under a pty, feeds it input and reads what comes back."""
    program = "print('got:' + input()); raise SystemExit(3)"
    owned = Terminal([sys.executable, "-c", program], PLAIN)
    try:
        owned.send(b"hello\n")
        owned.until(lambda: owned.status is not None)

        assert b"got:hello" in owned.content
        assert owned.status == 3
    finally:
        owned.close()


def test_a_terminal_that_exits_early_fails_the_wait() -> None:
    """The defect the helper exists to name: the process ended before the cue."""
    owned = Terminal([sys.executable, "-c", "pass"], PLAIN)
    try:
        with pytest.raises(AssertionError):
            owned.until(lambda: False)
    finally:
        owned.close()


def test_closing_a_terminal_reaps_a_child_that_is_still_running() -> None:
    """Nothing is left behind for the next case to find."""
    owned = Terminal([sys.executable, "-c", "import time; time.sleep(30)"], PLAIN)

    owned.close()

    with pytest.raises(ChildProcessError):
        os.waitpid(owned.pid, os.WNOHANG)


def test_the_terminal_check_fails_against_an_executable_that_does_nothing(
    stand_in: str,
) -> None:
    """The editor never starts, so the check cannot reach its READY cue."""
    with pytest.raises(AssertionError):
        terminal.main([stand_in])


@needs_tmux
def test_the_progress_check_fails_against_an_executable_that_does_nothing(
    stand_in: str,
) -> None:
    """No `Loading workspace` ever reaches the terminal, so the first case fails."""
    with pytest.raises(AssertionError):
        progress.main([stand_in, str(TMUX)])


@needs_tmux
def test_the_attach_check_fails_against_an_executable_that_does_nothing(
    stand_in: str,
) -> None:
    """The load never builds the session, so the choice's outcome is wrong."""
    with pytest.raises(AssertionError):
        attach.main([stand_in, str(TMUX), "detached"])


@needs_tmux
def test_stop_server_returns_once_the_socket_stops_accepting(tmp_path: Path) -> None:
    """The directory under a socket is safe to remove when this says True."""
    socket = str(tmp_path / "s")
    subprocess.run(
        [str(TMUX), "-f", "/dev/null", "-S", socket, "new-session", "-d"],
        env=PLAIN,
        check=True,
    )
    assert listening(socket)

    assert stop_server(str(TMUX), socket, PLAIN)
    assert not listening(socket)


@needs_tmux
def test_stop_server_says_so_when_the_server_keeps_running(tmp_path: Path) -> None:
    """A client that cannot stop the server leaves it listening, and it says so."""
    socket = str(tmp_path / "s")
    subprocess.run(
        [str(TMUX), "-f", "/dev/null", "-S", socket, "new-session", "-d"],
        env=PLAIN,
        check=True,
    )
    try:
        assert not stop_server(shutil.which("true") or "true", socket, PLAIN, 0.2)
    finally:
        assert stop_server(str(TMUX), socket, PLAIN)
