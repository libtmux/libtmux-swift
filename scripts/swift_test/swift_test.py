#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Run `swift test` with no tmux selector in its environment.

tmux follows an inherited `TMUX` to the server its caller is inside, ahead of
`TMUX_TMPDIR`, and otherwise uses the default socket under `TMUX_TMPDIR`.
`TMUX_PANE` retargets a command that names no pane, and the `LIBTMUX_SOCKET*`
variables choose a socket for `libtmux-mcp`. A suite started from a tmux pane
therefore reaches the server around it as soon as one case names no socket.

    uv run scripts/swift_test/swift_test.py --traits YAMLWorkspaces

Arguments go to `swift test` unchanged, and so does its exit status. SIGINT and
SIGTERM go to `swift test` too; the script waits for it, cleans up, and exits
with 128 plus the signal. Set `LIBTMUX_TEST_TMUX_TMPDIR` to an absolute path to
put the run's private directory under a parent of your own. The script makes a
fresh directory inside it and removes that directory afterwards. It refuses a
parent that is a link, is not empty, holds a `tmux-<uid>` entry, or is so long
that the default socket under it would pass the socket limit. It never changes
the mode of a directory that exists. The shared root under `/tmp` must belong to
the caller and be closed to other users, or the run refuses it.

Before the directory goes, the script looks for sockets anywhere under it,
whoever named them, and stops every server still listening on one, since
removing the socket of a live server leaves a server nothing can address. It
checks that each stopped server no longer accepts a connection, and fails the
run, naming the sockets, even when `swift test` passed: a case that starts a
server and does not stop it is a defect. A socket file nothing listens on is
not. The directory stays while any server still listens.

The suite reads `LIBTMUX_TEST_SANDBOX` to learn that this script started it. The
fixture never sets the variables itself: `setenv` writes to `environ` while
other cases read it to build a tmux environment, and that is a data race.
"""

from __future__ import annotations

import os
import secrets
import shutil
import signal
import socket
import stat
import string
import subprocess
import sys
import time
from collections.abc import Iterator, Sequence
from contextlib import suppress
from pathlib import Path

ROOT = Path("/tmp/libtmux-swift-test")

# The longest default socket path a parent may produce. `sun_path` holds 108
# bytes on Linux and 104 on macOS (unix(7), unix(4)); 100 stays under the
# shorter one with room for the terminating NUL.
LIMIT = 100

# How long a stopped server may keep accepting connections.
STOP_SECONDS = 3.0

NAME_CHARACTERS = string.ascii_letters + string.digits

SIGNALS = (signal.SIGINT, signal.SIGTERM)


class RefusedError(Exception):
    """The run will not use the directory it was given or found."""


def clear_selectors() -> None:
    """Remove every variable that picks a tmux server or pane."""
    for name in ("TMUX", "TMUX_PANE"):
        os.environ.pop(name, None)
    for name in [name for name in os.environ if name.startswith("LIBTMUX_SOCKET")]:
        del os.environ[name]


def shared_root() -> Path:
    """Return the shared test root, made owner-only when it does not exist.

    A root another user owns, or one other users can write to, would let them
    plant the socket directory the run is about to use.
    """
    with suppress(FileExistsError):
        ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    found = ROOT.lstat()
    if not stat.S_ISDIR(found.st_mode) or found.st_uid != os.getuid():
        message = f"{ROOT} must be a directory that belongs to the caller"
        raise RefusedError(message)
    if found.st_mode & 0o022:
        message = f"{ROOT} must not be writable by group or others"
        raise RefusedError(message)
    return ROOT


def parent_directory() -> Path:
    """Return the directory the run's private directory is made in.

    The caller's `LIBTMUX_TEST_TMUX_TMPDIR` when set, which has to be new or
    empty, and otherwise the shared test root.
    """
    named = os.environ.get("LIBTMUX_TEST_TMUX_TMPDIR", "")
    if not named:
        return shared_root()
    name = "LIBTMUX_TEST_TMUX_TMPDIR"
    if not named.startswith("/"):
        message = f"{name} must be an absolute path"
        raise RefusedError(message)
    parent = Path(named)
    if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
        message = f"{name} must be a new or empty directory, not a link or a file"
        raise RefusedError(message)
    longest = f"{named}/tmux-XXXXXX/tmux-{os.getuid()}/default"
    if len(longest.encode()) > LIMIT:
        message = (
            f"{name} is too long: the default socket under it would pass {LIMIT} bytes"
        )
        raise RefusedError(message)
    if parent.is_dir():
        if os.path.lexists(parent / f"tmux-{os.getuid()}"):
            message = f"{name} holds a tmux socket directory"
            raise RefusedError(message)
        try:
            entries = list(parent.iterdir())
        except OSError as error:
            message = f"{name} cannot be read"
            raise RefusedError(message) from error
        if entries:
            message = f"{name} must be a new or empty directory"
            raise RefusedError(message)
    parent.mkdir(parents=True, exist_ok=True)
    return parent


def make_directory(parent: Path) -> Path:
    """Create an owner-only `tmux-XXXXXX` directory in `parent`.

    The suffix is six characters because `parent_directory` measured the default
    socket path with six.
    """
    while True:
        suffix = "".join(secrets.choice(NAME_CHARACTERS) for _ in range(6))
        directory = parent / f"tmux-{suffix}"
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            continue
        return directory


def sockets_under(directory: Path) -> Iterator[Path]:
    """Yield every socket below `directory`, without following links."""
    for entry in sorted(os.scandir(directory), key=lambda found: found.name):
        if entry.is_dir(follow_symlinks=False):
            yield from sockets_under(Path(entry.path))
        elif stat.S_ISSOCK(entry.stat(follow_symlinks=False).st_mode):
            yield Path(entry.path)


def listening(path: Path) -> bool:
    """Say whether anything accepts a connection on the socket `path`.

    A raw connect, because a tmux client waits on a server that has stopped
    answering, and this runs after the run.
    """
    probe = socket.socket(socket.AF_UNIX)
    probe.settimeout(2)
    try:
        probe.connect(str(path))
    except TimeoutError:
        return True
    except OSError:
        return False
    finally:
        probe.close()
    return True


def gone(path: Path) -> bool:
    """Wait for the socket `path` to stop accepting connections."""
    deadline = time.monotonic() + STOP_SECONDS
    while listening(path):
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)
    return True


def stop_server(path: Path) -> bool:
    """Ask each client the run may have used to stop the server on `path`.

    A client cannot stop a daemon of a release it cannot speak to. What a client
    says is not trusted: `gone` is what decides.
    """
    clients = (
        os.environ.get("LIBTMUX_TMUX_BIN", ""),
        os.environ.get("LIBTMUX_TMUX_CLIENT_BIN", ""),
        "tmux",
    )
    for client in clients:
        if not client or shutil.which(client) is None:
            continue
        try:
            asked = subprocess.run(
                [client, "-f", "/dev/null", "-S", str(path), "kill-server"],
                capture_output=True,
                timeout=10,
                check=False,
            )
        except subprocess.TimeoutExpired:
            continue
        if asked.returncode == 0:
            return True
    return False


def finish(directory: Path, status: int) -> int:
    """Stop leaked servers, remove `directory` and return the exit status.

    A socket someone listens on is a leak and is stopped, and one nobody
    listens on is the file tmux leaves behind and is ignored. A socket that
    still has a listener after the stop keeps the directory.
    """
    stopped: list[str] = []
    stuck: list[str] = []
    for found in sockets_under(directory):
        if not listening(found):
            continue
        stop_server(found)
        name = str(found.relative_to(directory))
        (stopped if gone(found) else stuck).append(name)
    if stopped:
        print(
            "swift-test: the run left a tmux server on these sockets, now stopped:"
            + "".join(f" {name}" for name in stopped),
            file=sys.stderr,
        )
    if stuck:
        print(
            "swift-test: a tmux server on these sockets could not be stopped, "
            "and its directory is left in place:"
            + "".join(f" {name}" for name in stuck),
            file=sys.stderr,
        )
    if (stopped or stuck) and status == 0:
        status = 3
    if not stuck:
        shutil.rmtree(directory, ignore_errors=True)
    return status


class Interrupts:
    """The signals the run received, passed on to `swift test` once it exists."""

    def __init__(self) -> None:
        """Start with nothing received and no child to pass signals to."""
        self.received: list[int] = []
        self.child: subprocess.Popen[bytes] | None = None
        self.sent = 0

    def catch(self, number: int, _frame: object) -> None:
        """Record a signal and pass it on if the child is running."""
        self.received.append(number)
        self.flush()

    def attach(self, child: subprocess.Popen[bytes]) -> None:
        """Pass on every signal that arrived before the child started."""
        self.child = child
        self.flush()

    def flush(self) -> None:
        """Send the child each signal it has not had."""
        while self.child is not None and self.sent < len(self.received):
            number = self.received[self.sent]
            self.sent += 1
            self.child.send_signal(number)


def run_swift(arguments: Sequence[str], interrupts: Interrupts) -> int:
    """Run `swift test` and return its status, or 128 plus the signal that ended it."""
    try:
        child = subprocess.Popen(["swift", "test", *arguments])
    except FileNotFoundError:
        print("swift-test: swift: command not found", file=sys.stderr)
        return 127
    except PermissionError:
        print("swift-test: swift: permission denied", file=sys.stderr)
        return 126
    interrupts.attach(child)
    code = child.wait()
    return code if code >= 0 else 128 - code


def main(argv: Sequence[str] | None = None) -> int:
    """Run `swift test` in a private tmux directory and return its status."""
    arguments = sys.argv[1:] if argv is None else list(argv)
    clear_selectors()
    try:
        parent = parent_directory()
    except RefusedError as refused:
        print(f"swift-test: {refused}", file=sys.stderr)
        return 2
    directory = make_directory(parent)
    os.environ["TMUX_TMPDIR"] = str(directory)
    os.environ["LIBTMUX_TEST_SANDBOX"] = str(directory)

    # A signal reaches `swift test`, and the run still waits for it to end,
    # then cleans up and exits with 128 plus the signal's number.
    interrupts = Interrupts()
    for number in SIGNALS:
        signal.signal(number, interrupts.catch)
    try:
        status = run_swift(arguments, interrupts)
    finally:
        for number in SIGNALS:
            signal.signal(number, signal.SIG_DFL)
    if interrupts.received:
        status = 128 + interrupts.received[0]
    return finish(directory, status)


if __name__ == "__main__":
    sys.exit(main())
