"""Tests for the API breakage gate.

The gate's own policy is what these exercise -- which disagreements between the
reported breaks and the declared ones are failures. Running the toolchain's
comparison needs a built baseline and takes tens of seconds, so the policy is a
pure function and this suite never invokes it.
"""

from __future__ import annotations

import runpy
from pathlib import Path

GATE = runpy.run_path(Path(__file__).parents[1] / "check_api_breakage.py")

ADDED_CASE = (
    "API breakage: enumelement TmuxError.foreignPaneValue "
    "has been added as a new enum case"
)
PACKAGE_CHANGE = (
    "API breakage: func Server.scanForward(_:since:) has parameter 5 type change "
    "from ([Swift.String]) -> Swift.Bool to ([Swift.String], Swift.Bool) -> Swift.Bool"
)
ALLOWLIST = Path(".github/api-breakage-allowlist.txt")


def failures(
    reported: list[str],
    allowed: list[str],
    exported: set[str] | None = None,
    unreleased: str = "",
) -> list[str]:
    """Return the gate's verdict on one pairing of reported and declared breaks."""
    return GATE["failures"](
        reported,
        allowed,
        exported if exported is not None else set(),
        unreleased,
        ALLOWLIST,
    )


def test_a_declared_break_passes() -> None:
    """An allowlisted public break the changelog names is the green path."""
    assert not failures(
        [ADDED_CASE],
        [ADDED_CASE],
        exported={"foreignPaneValue"},
        unreleased="`TmuxError.foreignPaneValue` is a new case.",
    )


def test_an_unallowlisted_break_fails() -> None:
    """Nothing reaches a consumer without a line naming it."""
    found = failures([ADDED_CASE], [])

    assert len(found) == 1
    assert "undeclared API break" in found[0]


def test_a_stale_allowlist_entry_fails() -> None:
    """The file cannot keep lines that stopped describing a break."""
    found = failures([], [ADDED_CASE])

    assert len(found) == 1
    assert "stale allowlist entry" in found[0]


def test_a_public_break_absent_from_the_changelog_fails() -> None:
    """The gate that would have caught three breaks documented out of four."""
    found = failures(
        [ADDED_CASE],
        [ADDED_CASE],
        exported={"foreignPaneValue"},
        unreleased="Something else entirely.",
    )

    assert len(found) == 1
    assert "absent from the changelog" in found[0]


def test_a_longer_word_does_not_stand_in_for_the_symbol() -> None:
    """A rename to `send` is not excused by a sentence about `sendKeys`."""
    renamed = "API breakage: func Server.send(_:to:) has been removed"
    found = failures(
        [renamed],
        [renamed],
        exported={"send"},
        unreleased="`Server.sendKeys(_:to:literally:)` is unchanged.",
    )

    assert len(found) == 1
    assert "absent from the changelog" in found[0]


def test_a_constructor_is_owed_its_owning_type() -> None:
    """`init` is not a member name the changelog gate can resolve on a type."""
    removed = (
        "API breakage: constructor Server.init(socketPath:tmuxExecutable:) "
        "has been removed"
    )

    assert not failures(
        [removed],
        [removed],
        exported={"Server", "init"},
        unreleased="Every `Server` initializer now takes a transport.",
    )
    assert failures(
        [removed],
        [removed],
        exported={"Server", "init"},
        unreleased="Something about panes.",
    )


def test_a_package_break_needs_no_changelog_entry() -> None:
    """`package` is reachable only from this package, so nobody is told."""
    assert not failures(
        [PACKAGE_CHANGE],
        [PACKAGE_CHANGE],
        exported=set(),
        unreleased="",
    )


def test_the_unreleased_section_stops_at_the_release_below_it(tmp_path: Path) -> None:
    """A symbol named in an old release does not excuse a new break."""
    changelog = tmp_path / "CHANGELOG.md"
    changelog.write_text(
        "# Changelog\n\n"
        "## [Unreleased]\n\n- `Server.send(_:to:)` is new.\n\n"
        "## [0.1.0-alpha.5] - 2026-09-17\n\n- `Server.older(_:)` changed.\n",
        encoding="utf-8",
    )

    section = GATE["unreleased_section"](changelog)

    assert "send" in section
    assert "older" not in section


def test_public_declarations_are_collected(tmp_path: Path) -> None:
    """Only `public` counts: `package` is what the exemption turns on."""
    (tmp_path / "Sample.swift").write_text(
        "public struct Server {\n"
        "    public func send() {}\n"
        "    package func scanForward() {}\n"
        "}\n",
        encoding="utf-8",
    )

    exported = GATE["public_symbols"](tmp_path)

    assert "send" in exported
    assert "scanForward" not in exported
