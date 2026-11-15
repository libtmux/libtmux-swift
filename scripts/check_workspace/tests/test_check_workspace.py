"""Tests for the workspace CLI checks and the terminal helper they share.

The checks drive a `tmux-workspace` executable through a terminal and a private
tmux. Against a stand-in that does nothing, each must fail: that is what shows
they can. CI runs them against the executable it built.
"""

from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

import check_workspace_attach as attach
import check_workspace_progress as progress
import check_workspace_terminal as terminal
import pytest
from owned_terminal import Terminal

PLAIN = {"PATH": "/usr/bin:/bin"}

TMUX = os.environ.get("LIBTMUX_TMUX_BIN") or shutil.which("tmux")

needs_tmux = pytest.mark.skipif(TMUX is None, reason="needs a tmux")


@pytest.fixture
def stand_in(tmp_path: Path) -> str:
    """Return an executable that exits 1 at once, whatever it is asked."""
    script = tmp_path / "tmux-workspace"
    script.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return str(script)


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
    owned = Terminal(
        ["/bin/sh", "-c", 'read line; printf "got:%s\\n" "$line"; exit 3'], PLAIN
    )
    try:
        owned.send(b"hello\n")
        owned.until(lambda: owned.status is not None)

        assert b"got:hello" in owned.content
        assert owned.status == 3
    finally:
        owned.close()


def test_a_terminal_that_exits_early_fails_the_wait() -> None:
    """The defect the helper exists to name: the process ended before the cue."""
    owned = Terminal(["/bin/sh", "-c", "exit 0"], PLAIN)
    try:
        with pytest.raises(AssertionError):
            owned.until(lambda: False)
    finally:
        owned.close()


def test_closing_a_terminal_reaps_a_child_that_is_still_running() -> None:
    """Nothing is left behind for the next case to find."""
    owned = Terminal(["/bin/sh", "-c", "exec sleep 30"], PLAIN)

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
