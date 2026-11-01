#!/usr/bin/env python3
"""Check that every symbol `CHANGELOG.md` names still exists.

A changelog entry leads with an identifier, which makes it the one document
that goes stale silently: a renamed type or a method attributed to the wrong
owner still reads fine. `check_examples.py` holds README fences to compiled
code and `check_version.py` holds the pins to the version; this does the same
for the ledger.

Only qualified references are checked -- `Owner.member(labels:)` and
`Owner.member` -- and only when `Owner` is a type this package declares. A bare
type name would drag in every Swift standard library name a sentence mentions,
and an unqualified method name has no owner to check against.

Every changelog is read: the root file and the one beside each product's
sources, since an entry moved to a product file goes stale the same way.

    python3 Scripts/check_changelog_symbols.py
    python3 Scripts/check_changelog_symbols.py --changelog CHANGELOG.md
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

TYPE = re.compile(
    r"^\s*(?:public |package |internal |private |fileprivate )?"
    r"(?:final )?(?:struct|enum|class|actor|protocol|typealias)\s+(\w+)"
)
EXTENSION = re.compile(r"^\s*extension\s+(\w+)")
MEMBER = re.compile(
    r"^\s*(?:public |package |internal |private |fileprivate )?"
    r"(?:static |class |mutating |nonisolated |final )*"
    r"(?:func|var|let|case|init)\s+(\w+)"
)
REFERENCE = re.compile(r"`([A-Z]\w*)\.(\w+)(\([^`]*\))?`")


def declarations(root: pathlib.Path) -> dict[str, set[str]]:
    """Member names per owning type, across declarations and extensions.

    Nesting is tracked by brace depth, so a type declared inside another is
    both a member of it and an owner of its own.
    """
    members: dict[str, set[str]] = {}
    for path in sorted(root.rglob("*.swift")):
        scopes: list[tuple[str, int]] = []
        depth = 0
        for line in path.read_text(encoding="utf-8").splitlines():
            while scopes and depth < scopes[-1][1]:
                scopes.pop()
            owner = scopes[-1][0] if scopes else None
            declared = TYPE.match(line) or EXTENSION.match(line)
            if declared:
                name = declared.group(1)
                members.setdefault(name, set())
                if owner:
                    members[owner].add(name)
                scopes.append((name, depth + 1))
            else:
                member = MEMBER.match(line)
                if member and owner:
                    members[owner].add(member.group(1))
            depth += line.count("{") - line.count("}")
    return members


def changelogs(root: pathlib.Path) -> list[pathlib.Path]:
    """Return the root changelog and the one beside each product's sources."""
    return [root / "CHANGELOG.md", *sorted(root.glob("Sources/*/CHANGELOG.md"))]


def unresolved(paths: list[pathlib.Path], members: dict[str, set[str]]) -> list[str]:
    """Describe every qualified reference in `paths` that no longer resolves."""
    failures = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        for number, line in enumerate(text.splitlines(), 1):
            for owner, member, _ in REFERENCE.findall(line):
                if owner not in members:
                    continue
                if member in members[owner]:
                    continue
                elsewhere = sorted(o for o, names in members.items() if member in names)
                hint = f" -- declared on {', '.join(elsewhere)}" if elsewhere else ""
                failures.append(
                    f"{path}:{number}: {owner}.{member} does not exist{hint}"
                )
    return failures


def main() -> int:
    """Report every qualified reference that no longer resolves."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changelog", action="append", type=pathlib.Path)
    parser.add_argument("--sources", default="Sources")
    arguments = parser.parse_args()

    members = declarations(pathlib.Path(arguments.sources))
    paths = arguments.changelog or changelogs(pathlib.Path())
    failures = unresolved(paths, members)

    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        print(f"\n{len(failures)} unresolved reference(s)", file=sys.stderr)
        return 1
    print("every qualified CHANGELOG reference resolves")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
