"""Tests for the version pin gate."""

from __future__ import annotations

import runpy
from pathlib import Path

CHECK_VERSION = runpy.run_path(Path(__file__).parents[1] / "check_version.py")

OWN_PINS = CHECK_VERSION["own_pins"]


def test_documentation_pin_is_a_claim_about_this_package() -> None:
    """The pin a reader is told to depend on is what the gate measures."""
    manifest = """
    .package(
        url: "https://github.com/libtmux/libtmux-swift.git",
        exact: "0.1.0-alpha.3"
    )
    """

    assert OWN_PINS(manifest) == [(4, "0.1.0-alpha.3")]


def test_third_party_pin_passes_through() -> None:
    """A nested package holds its dependency at that dependency's version."""
    manifest = (
        '.package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")'
    )

    assert OWN_PINS(manifest) == []


def test_loose_pin_outside_a_package_block_is_still_checked() -> None:
    """Prose naming a tag is a claim even without a manifest around it."""
    assert OWN_PINS('exact: "0.1.0-alpha.3"') == [(1, "0.1.0-alpha.3")]


def test_a_third_party_block_does_not_shadow_the_next_own_pin() -> None:
    """Each `.package(` opens a new subject rather than inheriting the last."""
    manifest = """
    .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.0.0")
    .package(
        url: "https://github.com/libtmux/libtmux-swift.git",
        exact: "0.1.0-alpha.3"
    )
    """

    assert OWN_PINS(manifest) == [(5, "0.1.0-alpha.3")]
