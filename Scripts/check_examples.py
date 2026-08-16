#!/usr/bin/env python3
"""Require every documented Swift example to compile, and say how many run.

A README snippet is prose until something builds it. This session shipped one
that named a package identity SwiftPM does not use, and two more that compiled
with a warning — none of which a reader could tell from the page.

`Examples/` is a package of its own that depends on this one, so everything in
it is compiled by `swift build --package-path Examples` and compiled the way a
reader compiles it: through the products, with no `@testable`. This checks that
each ```swift block in the README and the DocC catalogue appears there, rather
than being a copy that drifted away from it.

Compiling is not the whole claim. A call that was renamed stops the build, but
one that quietly began answering something else does not. Every example lives in
a function, so an example is *executed* when a test in `Examples/Tests/` calls
that function by name — which is a fact about the tree rather than a claim in a
comment.

    python3 Scripts/check_examples.py
    python3 Scripts/check_examples.py --min-executed 18

Matching is by line sequence after removing each block's own indentation, so an
example may be shown on its own and kept inside a function.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
EXAMPLES = ROOT / "Examples" / "Sources"
TESTS = ROOT / "Examples" / "Tests"
DOCUMENTS = [ROOT / "README.md", *sorted((ROOT / "Sources").rglob("*.docc/*.md"))]

# Excerpts from a consumer's `Package.swift`. They are Swift, and they are
# fenced as Swift so they highlight, but none is a statement that can compile on
# its own. Listed rather than detected, so the next one has to be a decision
# somebody made rather than a heuristic somebody's example happened to match.
MANIFEST_EXCERPTS = {
    '.package(url: "https://github.com/libtmux/libtmux-swift.git", branch: "master")',
    '.product(name: "LibTmux", package: "libtmux-swift")',
    (
        '.package(\n'
        '    url: "https://github.com/libtmux/libtmux-swift.git",\n'
        '    exact: "0.1.0-alpha.1"\n'
        ")"
    ),
    (
        '.package(\n'
        '    url: "https://github.com/libtmux/libtmux-swift.git",\n'
        '    exact: "0.1.0-alpha.1",\n'
        '    traits: ["YAMLWorkspaces"]\n'
        ")"
    ),
}

FENCE = re.compile(r"```swift\n(.*?)```", re.DOTALL)
FUNCTION = re.compile(r"^(?:public )?func (\w+)")


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


def units() -> dict[str, list[str]]:
    """Map each example's name to the lines it is written on.

    A unit is one function, because that is what a test can call. Top-level code
    has no function to name, so `main.swift` takes the name of the executable it
    builds — which a test runs rather than calls.
    """
    found: dict[str, list[str]] = {}
    for path in sorted(EXAMPLES.rglob("*.swift")):
        current = path.parent.name if path.name == "main.swift" else path.stem
        found.setdefault(current, [])
        for line in path.read_text().splitlines():
            match = FUNCTION.match(line)
            if match:
                current = match.group(1)
                found.setdefault(current, [])
            found[current].append(line.rstrip())
    return found


def called() -> set[str]:
    """Every name a test reaches for, by call or by string.

    A function is executed when a test calls it; an executable is executed when
    a test spawns it, and a spawned binary is named by a string rather than by
    an identifier.
    """
    text = "\n".join(p.read_text() for p in TESTS.rglob("*.swift"))
    return set(re.findall(r"\b(\w+)\s*\(", text)) | set(re.findall(r'"(\w+)"', text))


def main() -> int:
    """Report any documented example the package does not compile."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--min-executed",
        type=int,
        default=0,
        help="fail unless at least this many documented examples are executed",
    )
    arguments = parser.parse_args()

    written = units()
    if not written:
        print(f"no examples in {EXAMPLES}", file=sys.stderr)
        return 1
    invoked = called()

    missing: dict[pathlib.Path, list[list[str]]] = {}
    total = executed = 0
    for document in DOCUMENTS:
        for match in FENCE.finditer(document.read_text()):
            block = textwrap.dedent(match.group(1)).strip()
            if block in MANIFEST_EXCERPTS:
                continue
            total += 1
            wanted = lines_of(block)
            homes = [name for name, body in written.items() if contains(body, wanted)]
            if not homes:
                missing.setdefault(document, []).append(wanted)
            elif any(name in invoked for name in homes):
                executed += 1

    if missing:
        print(
            f"{sum(len(b) for b in missing.values())} documented example(s) that "
            f"no file in {EXAMPLES.relative_to(ROOT)} compiles:",
            file=sys.stderr,
        )
        for document, blocks in missing.items():
            print(f"\n  {document.relative_to(ROOT)}:", file=sys.stderr)
            for block in blocks:
                for line in block:
                    print(f"    {line}", file=sys.stderr)
        print(
            "\nAdd each to a file under Examples/Sources/ rather than writing it "
            "twice.",
            file=sys.stderr,
        )
        return 1

    print(
        f"{total} documented examples, each compiled; "
        f"{executed} of them run against a real tmux"
    )
    if executed < arguments.min_executed:
        print(
            f"expected at least {arguments.min_executed} executed, found {executed}",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
