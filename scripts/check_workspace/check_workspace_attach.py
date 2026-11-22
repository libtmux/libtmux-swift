#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Verify native workspace attachment and explicit terminal choices.

The arguments are the staged `tmux-workspace` executable (`<cli>`), the tmux to
run it against (or empty to resolve `LIBTMUX_TEST_TMUX`, `LIBTMUX_TMUX_BIN`,
then `PATH`), and optionally the names of the choices to check:

    uv run scripts/check_workspace/check_workspace_attach.py <cli> [tmux] [name ...]

Each choice runs against a private temporary directory under
`/tmp/libtmux-swift-dev/` and prints one JSON line when all pass.
"""

import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from functools import partial
from pathlib import Path

from owned_terminal import (
    Terminal,
    resolve_tmux,
    stop_server,
    without_ambient_selectors,
)

FIXTURE = Path(__file__).with_name("fixture_program.py")


def release_key(token: str) -> tuple[int, int, str, tuple[int, int]]:
    """Order a tmux version the way the library does.

    `next-X.Y` ranks below `X.Y-rc`, which ranks below `X.Y-rcN`, which
    ranks below `X.Y`; the point-release letter orders last.
    """
    build = None
    if token.startswith("next-"):
        build, token = "next", token[len("next-") :]
    elif "-" in token:
        token, build = token.split("-", 1)
    match = re.fullmatch(r"(\d+)\.(\d+)([a-z]*)", token)
    if match is None:
        print(f"cannot read a tmux version from {token!r}", file=sys.stderr)
        sys.exit(1)
    if build == "next":
        rank = (0, 0)
    elif build is not None and build.startswith("rc"):
        rank = (1, int(build[2:] or 0))
    else:
        rank = (2, 0)
    return (int(match.group(1)), int(match.group(2)), match.group(3), rank)


NEEDS_ACTIVE_PANE_FLAG = {
    "independent-yes",
    "independent-detached",
    "independent-append",
    "independent-other-window",
    "gained-independent",
}

# Choices whose keeper window has a second pane that a viewer can focus.
INDEPENDENT = {"independent-yes", "independent-detached", "independent-append"}

# Choices whose workspaces run a `before_script`.
SCRIPTED = {*INDEPENDENT, "gained-independent"}

# What a person types at the prompt. Anything else answers yes.
ANSWERS = {
    "detached": b"n\n",
    "append": b"a\n",
    "eof": b"\x04",
    "quit": b"q\n",
    "interrupt": b"\x03",
}


@dataclass
class Fixture:
    """One choice's private tmux server, environment and owned terminals."""

    binary: str
    tmux: str
    root: Path
    environment: dict[str, str]
    terminals: list[Terminal] = field(default_factory=list)
    pane: str = ""
    other_pane: str = ""
    files: list[str] = field(default_factory=list)

    @property
    def socket(self) -> str:
        """Return the socket of the keeper server."""
        return str(self.root / "tmux")

    @property
    def foreign(self) -> str:
        """Return the socket of a second server the load must not touch."""
        return str(self.root / "foreign")

    @property
    def script_marker(self) -> Path:
        """Return the file a workspace's `before_script` writes when it runs."""
        return self.root / "script-ran"

    def command(self, *arguments: str, endpoint: str | None = None) -> str:
        """Run tmux against an explicit fixture endpoint."""
        result = subprocess.run(
            [self.tmux, "-f", "/dev/null", "-S", endpoint or self.socket, *arguments],
            env=self.environment,
            capture_output=True,
            text=True,
            check=True,
            timeout=3,
        )
        return result.stdout.strip()

    def clients(self) -> list[list[str]]:
        """Read client names, process IDs and sessions."""
        listing = self.command(
            "list-clients", "-F", "#{client_name}\t#{client_pid}\t#{session_name}"
        )
        return [line.split("\t") for line in listing.splitlines()]

    def sessions(self) -> list[str]:
        """Read the fixture session names."""
        return self.command("list-sessions", "-F", "#{session_name}").splitlines()

    def terminal(self, arguments: list[str]) -> Terminal:
        """Track an owned terminal for cleanup."""
        result = Terminal(arguments, self.environment)
        self.terminals.append(result)
        return result

    def attach(self, target: str = "=keeper", *flags: str) -> Terminal:
        """Attach an ordinary client to `target`."""
        return self.terminal(
            [self.tmux, "-S", self.socket, "attach-session", "-t", target, *flags]
        )

    def prepare(self, *, independent: bool, scripted: bool) -> None:
        """Start the keeper session and write the two workspaces to load."""
        self.pane = self.command(
            "new-session", "-d", "-s", "keeper", "-P", "-F", "#{pane_id}", "/bin/sh"
        )
        if independent:
            self.other_pane = self.command(
                "split-window",
                "-d",
                "-t",
                self.pane,
                "-P",
                "-F",
                "#{pane_id}",
                "/bin/sh",
            )
        marker = ["mark", str(self.script_marker)]
        for name in ["first", "final"]:
            document: dict[str, object] = {
                "session_name": name,
                "windows": [{"panes": [None]}],
            }
            if scripted:
                document["before_script"] = shlex.join(
                    [sys.executable, str(FIXTURE), *marker]
                )
            file = self.root / f"{name}.json"
            file.write_text(json.dumps(document))
            self.files.append(str(file))

    def run_load(
        self, *flags: str, endpoint: str | None = None, spoofing: str | None = None
    ) -> Path:
        """Type a `load` of the final workspace at the keeper pane.

        Return the file that receives its exit status.
        """
        marker = self.root / "exit-code"
        arguments = [
            self.binary,
            "load",
            self.files[1],
            "-S",
            endpoint or self.socket,
            "--no-progress",
            *flags,
        ]
        if spoofing:
            arguments = ["env", f"TMUX_PANE={spoofing}", *arguments]
        line = (
            shlex.join(arguments)
            + "; printf '%s\\n' \"$?\" > "
            + shlex.quote(str(marker))
        )
        self.command("send-keys", "-t", self.pane, "-l", line)
        self.command("send-keys", "-t", self.pane, "Enter")
        return marker

    def start_viewer(self, *flags: str) -> tuple[Terminal, str]:
        """Attach a viewer to the keeper and return it with its client name."""
        viewer = self.attach("=keeper", *flags)
        viewer.until(lambda: len(self.clients()) == 1)
        return viewer, self.clients()[0][0]

    def inside_keeper(self) -> bool:
        """Say whether every client is still on the keeper session."""
        return all(row[2] == "keeper" for row in self.clients())


def exit_status(viewer: Terminal, marker: Path) -> int:
    """Wait for the load to write its exit status and return it."""
    viewer.until(lambda: marker.exists() and marker.read_text().endswith("\n"))
    return int(marker.read_text())


def wait_for_prompt(viewer: Terminal) -> None:
    """Wait for the `[y]` choice the load asks for."""
    viewer.until(lambda: b"[y]" in viewer.content)


def check_focus(fixture: Fixture, viewer: Terminal, choice: str) -> None:
    """Require an `active-pane` client to type into the pane it focused.

    The viewer's input goes to the second pane, while `list-clients` still
    reports the keeper pane.
    """
    focus = fixture.root / "input-pane"
    typed = "printf '%s' \"$TMUX_PANE\" > " + shlex.quote(str(focus)) + "\n"
    viewer.send(b"\x02o" + typed.encode())
    viewer.until(lambda: focus.exists() and focus.read_text() == fixture.other_pane)
    assert fixture.command("list-clients", "-F", "#{pane_id}") == fixture.pane
    flags = fixture.command("list-clients", "-F", "#{client_flags}")
    assert "active-pane" in flags
    print(
        f"{choice}: input pane={focus.read_text()}, list-clients pane={fixture.pane}",
        file=sys.stderr,
        flush=True,
    )


def assert_unchanged(fixture: Fixture, status: int, sessions: list[str]) -> None:
    """Require a load that failed and left `sessions` and the viewer in place."""
    assert status != 0, (status, fixture.sessions(), fixture.clients())
    assert fixture.sessions() == sessions
    assert fixture.clients()[0][2] == "keeper"


def assert_loaded(
    fixture: Fixture,
    status: int,
    selected: str,
    *,
    stays: bool = False,
    elsewhere: bool = False,
) -> None:
    """Require the viewer `selected` to be switched to `final`.

    With `stays` nothing is switched, and with `elsewhere` a client of another
    session is left where it was.
    """
    expected = ["final", "keeper"]
    if elsewhere:
        expected.insert(0, "elsewhere")
    assert status == 0 and fixture.sessions() == expected
    for name, _, session in fixture.clients():
        if not stays and name == selected:
            assert session == "final"
        else:
            assert session == (
                "elsewhere" if elsewhere and name != selected else "keeper"
            )


def assert_appended(fixture: Fixture, status: int) -> None:
    """Require the workspace's window to be appended to the keeper session."""
    assert status == 0 and fixture.sessions() == ["keeper"]
    count = fixture.command(
        "display-message", "-p", "-t", "=keeper:", "#{session_windows}"
    )
    assert count == "2"
    assert fixture.clients()[0][2] == "keeper"


def load_outside(fixture: Fixture) -> Terminal:
    """Load both workspaces from a terminal that is not inside tmux."""
    return fixture.terminal(
        [
            fixture.binary,
            "load",
            *fixture.files,
            "-S",
            fixture.socket,
            "-f",
            "/dev/null",
            "--no-progress",
        ]
    )


def check_outside_malformed(fixture: Fixture) -> None:
    """Refuse a malformed `TMUX` from outside tmux, and build nothing."""
    fixture.environment["TMUX"] = "invalid"
    owner = load_outside(fixture)
    owner.until(lambda: owner.status is not None)
    assert owner.status == 2 and fixture.sessions() == ["keeper"]
    assert fixture.clients() == []


def check_outside(fixture: Fixture, ending: str) -> None:
    """Load two workspaces from outside tmux, attach, and end by `ending`.

    Detaching exits 0 and an interruption exits 130; either way both
    sessions stay and no client is left.
    """
    if ending == "detach":
        fixture.environment["TMUX"] = ""
    owner = load_outside(fixture)
    owner.until(lambda: any(row[2] == "final" for row in fixture.clients()))
    assert fixture.sessions() == ["final", "first", "keeper"]
    if ending == "detach":
        owner.send(b"\x02d")
    else:
        os.kill(owner.pid, signal.SIGINT if ending == "int" else signal.SIGTERM)
    owner.until(lambda: owner.status is not None)
    assert owner.status == (0 if ending == "detach" else 130)
    assert fixture.clients() == []
    assert fixture.sessions() == ["final", "first", "keeper"]


def check_session_fallback(fixture: Fixture) -> None:
    """Fall back to the only client of the session when no client has the pane.

    A second, ordinary client sits on a different window of the same session.
    Nothing makes the loading pane its active pane, so the exact-match set is
    empty and load switches the only client attached to the session.
    """
    other_window = fixture.command(
        "new-window", "-d", "-t", "=keeper:", "-P", "-F", "#{window_index}"
    )
    other = fixture.attach(f"=keeper:{other_window}")
    other.until(lambda: len(fixture.clients()) == 1)
    status = exit_status(other, fixture.run_load("-y"))
    assert status == 0, (status, fixture.sessions(), fixture.clients())
    assert fixture.sessions() == ["final", "keeper"]
    assert fixture.clients()[0][2] == "final", fixture.clients()


def check_prompted(fixture: Fixture, mode: str) -> None:
    """Answer the prompt in the viewer and check the outcome of `mode`.

    Switching and declining leave both sessions; `append` adds a window; an
    end of input exits 2, a quit exits 0 and an interrupt exits 130, each with
    nothing built and the viewer unmoved.
    """
    viewer, selected = fixture.start_viewer()
    marker = fixture.run_load()
    wait_for_prompt(viewer)
    viewer.send(ANSWERS.get(mode, b"y\n"))
    status = exit_status(viewer, marker)
    if mode == "append":
        assert_appended(fixture, status)
    elif mode in {"eof", "quit", "interrupt"}:
        # EOF answers nothing, so it is usage; declining is a plain exit.
        want = {"eof": 2, "quit": 0, "interrupt": 130}[mode]
        assert status == want and fixture.sessions() == ["keeper"]
        assert fixture.clients()[0][2] == "keeper"
    else:
        assert_loaded(fixture, status, selected, stays=mode == "detached")


def check_yes(fixture: Fixture) -> None:
    """Load with `-y` and switch the only viewer without asking."""
    viewer, selected = fixture.start_viewer()
    status = exit_status(viewer, fixture.run_load("-y"))
    assert_loaded(fixture, status, selected)


def check_ambiguous(fixture: Fixture) -> None:
    """Ask which of two clients to switch, and refuse an out-of-range answer."""
    viewer, _ = fixture.start_viewer()
    other = fixture.attach()
    other.until(lambda: len(fixture.clients()) == 2)
    marker = fixture.run_load()
    wait_for_prompt(viewer)
    viewer.send(b"y\n")
    viewer.until(lambda: b"Choose client" in viewer.content)
    selected = min(row[0] for row in fixture.clients())
    viewer.send(b"99\n")
    viewer.until(lambda: b"99" in viewer.content)
    assert fixture.sessions() == ["keeper"]
    viewer.send(b"1\n")
    assert_loaded(fixture, exit_status(viewer, marker), selected)


def check_ambiguous_yes(fixture: Fixture) -> None:
    """Refuse `-y` with several clients on the pane, as a usage error."""
    viewer, _ = fixture.start_viewer()
    fixture.attach().until(lambda: len(fixture.clients()) == 2)
    log_file = fixture.root / "ambiguous-yes.ndjson"
    status = exit_status(viewer, fixture.run_load("-y", "--log-file", str(log_file)))
    assert status != 0
    assert fixture.sessions() == ["keeper"]
    assert fixture.inside_keeper()
    # The invocation is what is wrong, so the shared code table names it.
    records = [
        json.loads(entry)
        for entry in log_file.read_text().splitlines()
        if entry.strip()
    ]
    codes = [entry["code"] for entry in records if "code" in entry]
    assert codes == ["usage"], codes


def check_foreign(fixture: Fixture) -> None:
    """Refuse to load on a server the viewer is not attached to."""
    viewer, _ = fixture.start_viewer()
    fixture.command(
        "new-session", "-d", "-s", "foreign-keeper", endpoint=fixture.foreign
    )
    status = exit_status(viewer, fixture.run_load(endpoint=fixture.foreign))
    assert status != 0
    assert fixture.sessions() == ["keeper"]
    assert fixture.inside_keeper()
    listed = fixture.command(
        "list-sessions", "-F", "#{session_name}", endpoint=fixture.foreign
    )
    assert listed == "foreign-keeper"


def check_spoofed_pane(fixture: Fixture) -> None:
    """Refuse a `TMUX_PANE` that names a pane the viewer is not looking at."""
    viewer, _ = fixture.start_viewer()
    spoofed = fixture.command(
        "new-window", "-d", "-t", "=keeper:", "-P", "-F", "#{pane_id}"
    )
    status = exit_status(viewer, fixture.run_load(spoofing=spoofed))
    assert status != 0
    assert fixture.sessions() == ["keeper"]
    assert fixture.inside_keeper()


def check_stale_client(fixture: Fixture) -> None:
    """Fail when the client moved to another session after the prompt."""
    viewer, first_client = fixture.start_viewer()
    marker = fixture.run_load()
    wait_for_prompt(viewer)
    fixture.command("new-session", "-d", "-s", "elsewhere")
    fixture.command("switch-client", "-c", first_client, "-t", "=elsewhere")
    fixture.command("send-keys", "-t", fixture.pane, "y", "Enter")
    status = exit_status(viewer, marker)
    assert status != 0
    assert fixture.sessions() == ["elsewhere", "final", "keeper"]
    assert fixture.clients()[0][2] == "elsewhere"


def check_gained_independent(fixture: Fixture) -> None:
    """Fail when the client gains `active-pane` while the prompt is open.

    The `before_script` has run by then, so its marker exists and the
    `final` session was built, but nothing was switched.
    """
    viewer, first_client = fixture.start_viewer()
    marker = fixture.run_load()
    wait_for_prompt(viewer)
    fixture.command("refresh-client", "-t", first_client, "-f", "active-pane")
    viewer.send(b"y\n")
    status = exit_status(viewer, marker)
    assert_unchanged(fixture, status, ["final", "keeper"])
    assert fixture.script_marker.exists()


def check_independent_yes(fixture: Fixture) -> None:
    """Refuse `-y` from an `active-pane` client, before the script runs."""
    viewer, _ = fixture.start_viewer("-f", "active-pane")
    check_focus(fixture, viewer, "independent-yes")
    status = exit_status(viewer, fixture.run_load("-y"))
    assert_unchanged(fixture, status, ["keeper"])
    assert not fixture.script_marker.exists()
    transcript = fixture.command("capture-pane", "-p", "-t", fixture.pane, "-S", "-100")
    assert "active-pane" in transcript and "-d" in transcript, transcript


def check_independent_prompted(fixture: Fixture, mode: str) -> None:
    """Answer the prompt in the pane an `active-pane` client does not type into."""
    choice = f"independent-{mode}"
    viewer, selected = fixture.start_viewer("-f", "active-pane")
    check_focus(fixture, viewer, choice)
    marker = fixture.run_load()
    wait_for_prompt(viewer)
    fixture.command(
        "send-keys", "-t", fixture.pane, ANSWERS[mode].decode().strip(), "Enter"
    )
    status = exit_status(viewer, marker)
    if mode == "append":
        assert_appended(fixture, status)
    else:
        assert_loaded(fixture, status, selected, stays=True)


def check_independent_other_window(fixture: Fixture) -> None:
    """Switch only the viewer, and leave an `active-pane` client elsewhere."""
    viewer, selected = fixture.start_viewer()
    fixture.command("new-session", "-d", "-s", "elsewhere", "/bin/sh")
    other = fixture.attach("=elsewhere", "-f", "active-pane")
    other.until(lambda: len(fixture.clients()) == 2)
    marker = fixture.run_load()
    wait_for_prompt(viewer)
    viewer.send(b"y\n")
    status = exit_status(viewer, marker)
    assert_loaded(fixture, status, selected, elsewhere=True)


CASES: dict[str, Callable[[Fixture], None]] = {
    "outside-detach": partial(check_outside, ending="detach"),
    "outside-int": partial(check_outside, ending="int"),
    "outside-term": partial(check_outside, ending="term"),
    "outside-malformed": check_outside_malformed,
    "detached": partial(check_prompted, mode="detached"),
    "append": partial(check_prompted, mode="append"),
    "switch": partial(check_prompted, mode="switch"),
    "yes": check_yes,
    "eof": partial(check_prompted, mode="eof"),
    "quit": partial(check_prompted, mode="quit"),
    "interrupt": partial(check_prompted, mode="interrupt"),
    "ambiguous": check_ambiguous,
    "ambiguous-yes": check_ambiguous_yes,
    "foreign": check_foreign,
    "spoofed-pane": check_spoofed_pane,
    "stale-client": check_stale_client,
    "independent-yes": check_independent_yes,
    "independent-detached": partial(check_independent_prompted, mode="detached"),
    "independent-append": partial(check_independent_prompted, mode="append"),
    "independent-other-window": check_independent_other_window,
    "gained-independent": check_gained_independent,
    "session-fallback": check_session_fallback,
}


def check(choice: str, binary: str, tmux: str, base: Path) -> None:
    """Exercise one load choice against an owned terminal and server."""
    with tempfile.TemporaryDirectory(prefix="attach-", dir=base) as directory:
        root = Path(directory)
        environment = without_ambient_selectors(
            os.environ,
            TERM="xterm-256color",
            HOME=str(root),
            SHELL="/bin/sh",
            ENV="/dev/null",
            BASH_ENV="/dev/null",
            ZDOTDIR=str(root),
            LIBTMUX_TMUX_BIN=tmux,
            TMUX_TMPDIR=str(root),
        )
        fixture = Fixture(binary, tmux, root, environment)
        try:
            fixture.prepare(
                independent=choice in INDEPENDENT, scripted=choice in SCRIPTED
            )
            CASES[choice](fixture)
        finally:
            for endpoint in [fixture.socket, fixture.foreign]:
                if not stop_server(tmux, endpoint, environment):
                    print(
                        f"{choice}: a server on {endpoint} did not stop",
                        file=sys.stderr,
                    )
            for owner in fixture.terminals:
                owner.close()


def main(argv: Sequence[str] | None = None) -> int:
    """Check the choices named in `argv`, or every choice, and print the result."""
    arguments = sys.argv[1:] if argv is None else list(argv)
    binary = str(Path(arguments[0]).resolve())
    tmux = resolve_tmux(arguments[1] if len(arguments) > 1 else None)
    base = Path("/tmp/libtmux-swift-dev")
    base.mkdir(exist_ok=True)
    # tmux 3.8 removed the `active-pane` client flag, so a client cannot be made
    # independent there.
    has_active_pane_flag = release_key(
        subprocess.check_output([tmux, "-V"], text=True).split()[-1]
    ) < release_key("3.8")
    checks = []
    for choice in arguments[2:] or CASES:
        if choice in NEEDS_ACTIVE_PANE_FLAG and not has_active_pane_flag:
            print(
                f"{choice}: skipped, this tmux has no active-pane flag",
                file=sys.stderr,
            )
            continue
        check(choice, binary, tmux, base)
        checks.append(choice)

    print(
        json.dumps(
            {
                "tmux": subprocess.check_output([tmux, "-V"], text=True).strip(),
                "passed": checks,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
