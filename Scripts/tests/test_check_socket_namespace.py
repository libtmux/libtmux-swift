"""Tests for the socket namespace gate."""

from __future__ import annotations

import runpy
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).parents[1] / "check_socket_namespace.py"
GATE = runpy.run_path(str(SCRIPT))

SCAN = GATE["scan"]


def test_a_path_under_a_sanctioned_root_passes() -> None:
    """The roots AGENTS.md sanctions are the only places a path may point."""
    source = 'let s = try Server(socketPath: "/tmp/libtmux-swift-test/a/s")'

    assert SCAN("Tests/A.swift", source) == []


def test_a_path_outside_the_roots_is_reported() -> None:
    """A socket another port can find is the failure the namespace prevents."""
    source = 'let s = try Server(socketPath: "/tmp/libtmux-test/s")'

    assert SCAN("Tests/A.swift", source) == [
        "Tests/A.swift:1: path /tmp/libtmux-test/s"
    ]


def test_a_name_that_does_not_identify_this_port_is_reported() -> None:
    """A name resolves inside TMUX_TMPDIR, so the name carries the port."""
    source = 'let s = try Server(socketName: "libtmux-test")'

    assert SCAN("Tests/A.swift", source) == ["Tests/A.swift:1: name libtmux-test"]


@pytest.mark.parametrize(
    "source",
    [
        "let s = Server()",
        'let s = try Server(tmuxExecutable: "tmux")',
        'let s = try Server(tmuxExecutable: "tmux", configurationFile: "/dev/null")',
        "let s = try Server(\n    tmuxExecutable: x,\n    configurationFile: nil\n)",
        "let s = LibTmux.Server()",
    ],
)
def test_a_server_that_names_no_socket_is_reported(source: str) -> None:
    """It follows TMUX and then tmux's default socket, whichever server that is."""
    assert SCAN("Tests/A.swift", source) == [
        "Tests/A.swift:1: Server() names no socket"
    ]


@pytest.mark.parametrize(
    "source",
    [
        "let s = try Server(socketPath: path)",
        "let s = try Server(socketName: name, tmuxExecutable: executable)",
        "let s = Server(endpoint: endpoint, transport: transport)",
        "let s = Server(\n    tmuxExecutable: executable,\n    endpoint: endpoint\n)",
        'let s = Server(tmuxExecutable: "a (b", endpoint: endpoint)',
        "let c = ServerConfiguration(environment: [:])",
        "try await withTmuxServer { server in }",
        "let name = SomeServer()",
        "// Server() is what the next release adds",
        "let s = try Server(socketPath: path) // not Server()",
    ],
)
def test_a_server_that_names_its_socket_passes(source: str) -> None:
    """The label is what matters, wherever it sits in the argument list."""
    assert SCAN("Tests/A.swift", source) == []


def test_the_context_of_this_process_is_reported() -> None:
    """Reading TMUX from the process is how a test finds the developer's server."""
    assert SCAN("Tests/A.swift", "let c = TmuxContext.current()") == [
        "Tests/A.swift:1: TmuxContext.current() names no socket"
    ]
    assert SCAN("Tests/A.swift", "let c = TmuxContext.current(environment: env)") == []


def test_make_server_is_reported() -> None:
    """A configuration builds its server from the environment it was given."""
    assert SCAN("Tests/A.swift", "let s = try configuration.makeServer()") == [
        "Tests/A.swift:1: makeServer() names no socket"
    ]


def test_the_line_of_a_multi_line_call_is_where_it_starts() -> None:
    """A reader jumps to the opening line."""
    source = "let a = 1\nlet b = 2\nlet s = Server(\n    tmuxExecutable: x\n)\n"

    assert SCAN("Tests/A.swift", source) == [
        "Tests/A.swift:3: Server() names no socket"
    ]


def test_the_shipped_sources_may_use_them() -> None:
    """The executables choose a server from the environment on purpose."""
    assert SCAN("Sources/libtmux-mcp/main.swift", "let s = try c.makeServer()") == []


def test_a_listed_exception_passes_only_in_its_file() -> None:
    """An allowance is for one call in one place, not for a pattern."""
    source = "let c = TmuxContext.current()"
    listed = "Examples/Sources/ExampleCode/Snapshots.swift"

    assert SCAN(listed, source) == []
    assert SCAN("Examples/Sources/ExampleCode/Other.swift", source) != []
    assert SCAN(listed, "let s = Server()") != []


def test_the_repository_passes() -> None:
    """Nothing tracked names no socket or names one outside the roots."""
    finished = subprocess.run(
        [sys.executable, str(SCRIPT)], capture_output=True, text=True, check=False
    )

    assert finished.returncode == 0, finished.stderr


def test_a_planted_construction_fails_the_script(tmp_path: Path) -> None:
    """The script run end to end exits nonzero on a tracked file that has one."""
    (tmp_path / "Scripts").mkdir()
    shutil.copy(SCRIPT, tmp_path / "Scripts" / SCRIPT.name)
    (tmp_path / "Tests").mkdir()
    (tmp_path / "Tests" / "Planted.swift").write_text(
        "let server = Server()\n", encoding="utf-8"
    )
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "Tests/Planted.swift"], cwd=tmp_path, check=True)

    finished = subprocess.run(
        [sys.executable, str(tmp_path / "Scripts" / SCRIPT.name)],
        capture_output=True,
        text=True,
        check=False,
    )

    assert finished.returncode == 1
    assert "Tests/Planted.swift:1: Server() names no socket" in finished.stderr
