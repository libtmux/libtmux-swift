#!/usr/bin/env python3
"""Require every documented Swift example to be one that compiles.

A README snippet is prose until something builds it. This session shipped one
that named a package identity SwiftPM does not use, and two more that compiled
with a warning — none of which a reader could tell from the page.

`Snippets/` is built by `swift build`, so anything living there is compiled on
every build and in CI. This checks the other half: that each ```swift block in
the README and the DocC catalogue appears in one of those snippets, rather than
being a copy that drifted away from it.

    python3 Scripts/check_examples.py

Matching is by line sequence after removing each block's own indentation, so an
example may be shown on its own and kept in a snippet inside a function.
"""

from __future__ import annotations

import pathlib
import re
import sys
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
SNIPPETS = ROOT / "Snippets"
DOCUMENTS = [ROOT / "README.md", *sorted((ROOT / "Sources").rglob("*.docc/*.md"))]

# Excerpts from a consumer's `Package.swift`. They are Swift, and they are
# fenced as Swift so they highlight, but none is a statement that can compile on
# its own. Listed rather than detected, so the next one has to be a decision
# somebody made rather than a heuristic somebody's example happened to match.
MANIFEST_EXCERPTS = {
    '.package(url: "https://github.com/libtmux/libtmux-swift.git", from: "0.1.0")',
    '.package(url: "https://github.com/libtmux/libtmux-swift.git", branch: "master")',
    '.product(name: "LibTmux", package: "libtmux-swift")',
    (
        '.package(\n'
        '    url: "https://github.com/libtmux/libtmux-swift.git",\n'
        '    from: "0.1.0",\n'
        '    traits: ["YAMLWorkspaces"]\n'
        ")"
    ),
}

FENCE = re.compile(r"```swift\n(.*?)```", re.DOTALL)


def lines_of(text: str) -> list[str]:
    """Reduce a block to comparable lines: no shared indent, no trailing space."""
    return [line.rstrip() for line in textwrap.dedent(text).strip("\n").split("\n")]


def contains(snippet: list[str], block: list[str]) -> bool:
    """Whether `block` appears in `snippet`, ignoring how far it is indented."""
    for start in range(len(snippet) - len(block) + 1):
        window = snippet[start : start + len(block)]
        if lines_of("\n".join(window)) == block:
            return True
    return False


def main() -> int:
    """Report any documented example that no snippet compiles."""
    snippets = {
        path: lines_of(path.read_text()) for path in sorted(SNIPPETS.glob("*.swift"))
    }
    if not snippets:
        print(f"no snippets in {SNIPPETS}", file=sys.stderr)
        return 1

    orphans: list[tuple[pathlib.Path, str]] = []
    checked = 0
    for document in DOCUMENTS:
        for block in FENCE.findall(document.read_text()):
            if block.strip() in MANIFEST_EXCERPTS:
                continue
            checked += 1
            wanted = lines_of(block)
            if not any(contains(body, wanted) for body in snippets.values()):
                orphans.append((document, block.strip()))

    if orphans:
        print(
            f"{len(orphans)} documented example(s) are in no snippet, so nothing "
            f"compiles them:",
            file=sys.stderr,
        )
        for document, block in orphans:
            print(f"\n  {document.relative_to(ROOT)}:", file=sys.stderr)
            for line in block.split("\n"):
                print(f"    {line}", file=sys.stderr)
        print(
            f"\nAdd each to a file in {SNIPPETS.relative_to(ROOT)}, or fix the "
            f"copy that drifted.",
            file=sys.stderr,
        )
        return 1

    print(f"{checked} documented examples, each compiled by a snippet")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
