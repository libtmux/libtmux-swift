#!/usr/bin/env python3
"""Require every socket this repository addresses by literal to name this port.

`AGENTS.md` states the rule in prose: a socket lives under
`/tmp/libtmux-swift-test/` or `/tmp/libtmux-swift-dev/`, never anywhere else,
because `/tmp` is shared with the other libtmux ports and a sweep by prefix in
either direction reaps the other's servers. Prose is not a gate — `libtmux-ts`
enforces the same invariant with a script, and this is the Swift half of it.

    python3 Scripts/check_socket_namespace.py

What it can and cannot see. It matches literal `Server(socketPath:)` and
`Server(socketName:)` calls. A path records its root directly; a name resolves
inside `TMUX_TMPDIR`, so the suite gates that part through
`namedSocketsAvailable` and this check requires the name to identify this port.
It cannot tell a server that was addressed from one that was started — nothing
reaches the filesystem until a command runs against it, and that is a runtime
fact. The exceptions below therefore stay explicit decisions rather than
patterns that happen to pass.

It also reads the constructors that name no socket at all: `Server()` or
`Server(tmuxExecutable:)`, `TmuxContext.current()` with no environment, and
`makeServer()`. None of them reaches the filesystem until a command runs, but
each follows `TMUX`, `LIBTMUX_SOCKET*` or tmux's default socket, so a test that
calls one drives whichever server the developer is inside. They are looked for
outside `Sources/`, where the shipped executables use them on purpose.

`dev/Spikes/` is excluded: it is scratch work that CI does not build.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# The two roots AGENTS.md sanctions.
SANCTIONED = ("/tmp/libtmux-swift-test", "/tmp/libtmux-swift-dev")

# Addressed but never started, or a path the reader owns rather than one this
# repository creates. Each is a decision, not a heuristic.
ALLOWED = {
    # "an empty list is a no-op that never invokes tmux" — nothing is spawned.
    ("Tests/LibTmuxTests/CommandListTests.swift", "/tmp/lt-empty"),
    # Identity and equality over endpoints; no server is ever started.
    ("Tests/LibTmuxTests/ServerTests.swift", "/tmp/libtmux-value"),
    # The consumer example addresses tmux's conventional socket; listing does
    # not start it, and its test creates this name only under guarded TMUX_TMPDIR.
    ("Examples/Sources/QuickStart/main.swift", "default"),
    ("Examples/Tests/ExampleTests/QuickStartTests.swift", "default"),
}

# A construction that names no socket, in code that is not shipped, and why it
# is acceptable there.
AMBIENT_ALLOWED = {
    # Reads the endpoint a configuration chose from an environment the test
    # wrote out; no command is sent to the server it builds.
    ("Tests/LibTmuxMCPTests/SocketSelectionTests.swift", "makeServer()"),
    # Compiled, never executed: it shows a reader the call, and the example is
    # only non-nil inside tmux.
    ("Examples/Sources/ExampleCode/Snapshots.swift", "TmuxContext.current()"),
}

PATH_LITERAL = re.compile(r'Server\(\s*socketPath:\s*"([^"]*)"')
NAME_LITERAL = re.compile(r'Server\(\s*socketName:\s*"([^"]*)"')

# Every socket name this repository creates says which port owns it.
NAME_PREFIX = "libtmux-swift"

SERVER_CALL = re.compile(r"(?<![A-Za-z0-9_])Server\(")
CONTEXT_CALL = re.compile(r"(?<![A-Za-z0-9_])TmuxContext\.current\(")
MAKE_SERVER_CALL = re.compile(r"\.makeServer\(")
ADDRESSING_LABEL = re.compile(r"\b(?:socketPath|socketName|endpoint)\s*:")
ENVIRONMENT_LABEL = re.compile(r"\benvironment\s*:")


def tracked_swift_files() -> list[str]:
    """List every Swift file git knows about.

    An untracked scratch file is therefore not a failure, and a committed one
    is.
    """
    listed = subprocess.run(
        ["git", "ls-files", "*.swift"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [line for line in listed.splitlines() if line]


def arguments_of(text: str, opening: int) -> str:
    """Return the text between the parenthesis at `opening` and its partner.

    Parentheses inside a string literal do not count. An unclosed call yields
    the rest of the file, which only makes the labels easier to find.
    """
    depth = 0
    quoted = False
    index = opening
    while index < len(text):
        character = text[index]
        if character == "\\" and quoted:
            index += 2
            continue
        if character == '"':
            quoted = not quoted
        elif not quoted:
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    return text[opening + 1 : index]
        index += 1
    return text[opening + 1 :]


def line_of(text: str, offset: int) -> int:
    """Return the 1-based line number of `offset`."""
    return text.count("\n", 0, offset) + 1


def in_comment(text: str, offset: int) -> bool:
    """Say whether a `//` precedes `offset` on its line.

    A mention in a comment is not a call. A string holding `//` before a call on
    the same line hides the call, which is the cheaper way to be wrong.
    """
    return "//" in text[text.rfind("\n", 0, offset) + 1 : offset]


def names_a_socket(arguments: str) -> bool:
    """Say whether the arguments of a `Server(` decide which socket it uses.

    An `environment:` does when it is written out, since the two variables are
    read from it and nothing else; one taken from the process does not.
    """
    if ADDRESSING_LABEL.search(arguments):
        return True
    return bool(ENVIRONMENT_LABEL.search(arguments)) and "ProcessInfo" not in arguments


def ambient_constructions(relative: str, text: str) -> list[str]:
    """Report each construction in `text` that names no socket, outside `Sources/`."""
    if relative.startswith("Sources/"):
        return []
    found: list[tuple[int, str]] = []
    for match in SERVER_CALL.finditer(text):
        inside = arguments_of(text, match.end() - 1)
        if not names_a_socket(inside):
            found.append((match.start(), "Server()"))
    found.extend(
        (match.start(), "TmuxContext.current()")
        for match in CONTEXT_CALL.finditer(text)
        if not ENVIRONMENT_LABEL.search(arguments_of(text, match.end() - 1))
    )
    found.extend(
        (match.start(), "makeServer()") for match in MAKE_SERVER_CALL.finditer(text)
    )
    return [
        f"{relative}:{line_of(text, offset)}: {symbol} names no socket"
        for offset, symbol in sorted(found)
        if not in_comment(text, offset) and (relative, symbol) not in AMBIENT_ALLOWED
    ]


def scan(relative: str, text: str) -> list[str]:
    """Return one failure per addressed socket or bare construction in `text`."""
    failures: list[str] = []
    for number, line in enumerate(text.splitlines(), start=1):
        for literal in PATH_LITERAL.findall(line):
            if literal.startswith(SANCTIONED):
                continue
            if (relative, literal) in ALLOWED:
                continue
            failures.append(f"{relative}:{number}: path {literal}")
        for literal in NAME_LITERAL.findall(line):
            if literal.startswith(NAME_PREFIX):
                continue
            if (relative, literal) in ALLOWED:
                continue
            failures.append(f"{relative}:{number}: name {literal}")
    return failures + ambient_constructions(relative, text)


def main() -> int:
    """Report any addressed socket that neither names this port nor is allowed."""
    failures: list[str] = []
    checked = 0

    for relative in tracked_swift_files():
        if relative.startswith("dev/Spikes/"):
            continue
        checked += 1
        failures.extend(scan(relative, (ROOT / relative).read_text()))

    if failures:
        print(f"{len(failures)} finding(s):", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nEvery socket path belongs under /tmp/libtmux-swift-test/ (suites)"
            f"\nor /tmp/libtmux-swift-dev/ (by hand), and every socket name starts"
            f"\nwith {NAME_PREFIX}. If this one is addressed but never started, add"
            "\nit to ALLOWED with the reason. A construction that names no socket"
            "\nfollows TMUX and tmux's default socket: give it one, or, if it is"
            "\nnever run, add it to AMBIENT_ALLOWED with the reason. See AGENTS.md.",
            file=sys.stderr,
        )
        return 1

    print(
        f"{checked} Swift files checked; every socket names this port"
        ", none is left to the environment"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
