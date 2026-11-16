#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Require `Package.resolved` to keep the pin for Yams.

`Package.resolved` tracks a superset that includes Yams even when the
`YAMLWorkspaces` trait is off, and a trait-off `swift test` resolves without
it and rewrites the file to drop that pin. Checking the committed file is what
catches the drift, because a run that already has the pin never restores it.

    uv run scripts/check_resolved_pins/check_resolved_pins.py [PATH]

PATH defaults to `Package.resolved` in the current directory.
"""

import json
import pathlib
import sys
from collections.abc import Sequence

PINNED = "yams"


def has_pin(document: object, identity: str = PINNED) -> bool:
    """Return whether a parsed `Package.resolved` pins `identity`."""
    if not isinstance(document, dict):
        return False
    pins = document.get("pins")
    if not isinstance(pins, list):
        return False
    return any(
        isinstance(pin, dict) and pin.get("identity") == identity for pin in pins
    )


def main(argv: Sequence[str] | None = None) -> int:
    """Read the file and fail when it no longer pins Yams."""
    args = list(sys.argv[1:] if argv is None else argv)
    path = pathlib.Path(args[0]) if args else pathlib.Path("Package.resolved")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"{path}: cannot read it as JSON: {error}", file=sys.stderr)
        return 2
    if not has_pin(document):
        print(
            f"{path} no longer pins {PINNED}; restore the pin and commit it",
            file=sys.stderr,
        )
        return 1
    print(f"{path} pins {PINNED}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
