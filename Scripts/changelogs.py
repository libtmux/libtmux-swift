#!/usr/bin/env python3
"""Hold every product to a changelog of its own, and build release notes from them.

Each public product keeps a `CHANGELOG.md`: `LibTmux` at the repository root,
which also lists the changes that span products, and `TmuxWorkspace` and
`LibTmuxMCP` beside their sources. The products share one version, so every file
has a section for every release. Nothing else noticed a product losing its
file, so `check` holds each claim that can be answered from the checkout:

- the file exists;
- it opens with the name of the product it belongs to, so another product's
  file pasted over it fails where it was pasted;
- it has an `[Unreleased]` section for the next release to land under;
- it lists the same releases as the root file; and
- `Package.swift` excludes it from its target, which SwiftPM would otherwise
  report as an unhandled resource.

`notes` is what `.github/workflows/release.yml` publishes: the root section for
a version, then each product's, under a heading naming it. It refuses a version
that any file has no section for.

    python3 Scripts/changelogs.py check
    python3 Scripts/changelogs.py notes 0.1.1
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections.abc import Iterator

ROOT = pathlib.Path(__file__).resolve().parent.parent

PRODUCTS = {
    "LibTmux": "CHANGELOG.md",
    "TmuxWorkspace": "Sources/TmuxWorkspace/CHANGELOG.md",
    "LibTmuxMCP": "Sources/LibTmuxMCP/CHANGELOG.md",
}
# The target whose directory holds each changelog. The root file is not inside
# one.
TARGETS = {"TmuxWorkspace": "TmuxWorkspace", "LibTmuxMCP": "LibTmuxMCP"}

OPENING = re.compile(r"\A# Changelog\s+Notable changes to `([^`]+)`\.$", re.MULTILINE)
RELEASE = re.compile(r"^## \[([^\]]+)\]")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})(.*)$")
TARGET_START = re.compile(r"\.(?:executableTarget|testTarget|target)\(")
EXCLUDE = re.compile(r"exclude:\s*\[([^\]]*)\]")
COMMENT = re.compile(r"^\s*//.*$", re.MULTILINE)


def scan(markdown: str) -> Iterator[tuple[str, bool]]:
    """Yield each line of `markdown` with whether a code fence holds it.

    A fence closes on a line of the same character, at least as long, with no
    info string, so a shorter or different fence inside one does not end it.
    The fence lines themselves count as inside.
    """
    fence: str | None = None
    for line in markdown.splitlines():
        match = FENCE.match(line)
        if fence is None:
            if match:
                fence = match.group(1)
            yield line, match is not None
        else:
            yield line, True
            if (
                match
                and match.group(1)[0] == fence[0]
                and len(match.group(1)) >= len(fence)
                and not match.group(2).strip()
            ):
                fence = None


def outside_fences(markdown: str) -> list[str]:
    """Return the lines of `markdown` that no code fence holds."""
    return [line for line, fenced in scan(markdown) if not fenced]


def releases(markdown: str) -> list[str]:
    """Return a changelog's release headings in order, outside code fences."""
    return [
        heading.group(1)
        for line in outside_fences(markdown)
        if (heading := RELEASE.match(line))
    ]


def section(markdown: str, version: str) -> str | None:
    """Return the text under `## [version]` up to the next release heading.

    Fences only decide which lines are headings; the text keeps their content.
    """
    collecting = False
    kept: list[str] = []
    for line, fenced in scan(markdown):
        heading = None if fenced else RELEASE.match(line)
        if heading and collecting:
            break
        if heading:
            collecting = heading.group(1) == version
        elif collecting:
            kept.append(line)
    return "\n".join(kept).strip("\n") if collecting else None


def excludes(manifest: str, target: str) -> bool:
    """Say whether `Package.swift` lists CHANGELOG.md in the `exclude` of `target`."""
    code = COMMENT.sub("", manifest)
    for chunk in TARGET_START.split(code):
        if re.match(rf'\s*name:\s*"{re.escape(target)}"', chunk) is None:
            continue
        listed = EXCLUDE.search(chunk)
        return bool(listed and '"CHANGELOG.md"' in listed.group(1))
    return False


def failures(root: pathlib.Path) -> list[str]:
    """Return every way the products' changelogs fall short of the policy above."""
    found: list[str] = []
    texts: dict[str, str] = {}
    manifest = (root / "Package.swift").read_text(encoding="utf-8")
    for name, path in PRODUCTS.items():
        file = root / path
        if not file.is_file():
            found.append(f"{path}: {name} has no changelog")
            continue
        text = file.read_text(encoding="utf-8")
        texts[name] = text
        opening = OPENING.search(text)
        if opening is None:
            found.append(f'{path}: does not open with "Notable changes to `{name}`."')
        elif opening.group(1) != name:
            found.append(f"{path}: is the changelog of {opening.group(1)}, not {name}")
        if "## [Unreleased]" not in outside_fences(text):
            found.append(f'{path}: has no "## [Unreleased]" section')
        if name in TARGETS and not excludes(manifest, TARGETS[name]):
            found.append(
                f"Package.swift: target {TARGETS[name]} does not exclude "
                "CHANGELOG.md, so SwiftPM reports it as an unhandled resource"
            )
    reference = texts.get("LibTmux")
    if reference is not None:
        for name, text in texts.items():
            if name != "LibTmux" and releases(text) != releases(reference):
                found.append(
                    f"{PRODUCTS[name]}: lists different releases than CHANGELOG.md; "
                    "the products share one version, so every file has every release"
                )
    return found


def notes(root: pathlib.Path, version: str) -> str:
    """Return the release notes for `version`: the root section, then each product's."""
    problems = failures(root)
    if problems:
        message = "every product needs a changelog:\n" + "\n".join(problems)
        raise ValueError(message)
    parts: list[str] = []
    for name, path in PRODUCTS.items():
        body = section((root / path).read_text(encoding="utf-8"), version)
        if body is None:
            message = f"{path} has no section for {version}"
            raise ValueError(message)
        if name == "LibTmux":
            if body.strip():
                parts.append(body)
        elif body.strip() and not body.strip().startswith("No entries for"):
            demoted = "\n".join(
                f"#{line}" if line.startswith("### ") and not fenced else line
                for line, fenced in scan(body)
            )
            parts.append(f"### {name}\n\n{demoted}")
    if not parts:
        message = f"the changelogs have no entries for {version}"
        raise ValueError(message)
    return "\n\n".join(parts) + "\n"


def main() -> int:
    """Run `check` or `notes`."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check", help="hold every product to a changelog")
    printing = commands.add_parser(
        "notes", help="print the release notes for a version"
    )
    printing.add_argument("version")
    arguments = parser.parse_args()
    if arguments.command == "check":
        problems = failures(ROOT)
        for problem in problems:
            print(problem, file=sys.stderr)
        if problems:
            return 1
        print(f"every product keeps a changelog: {', '.join(PRODUCTS)}")
        return 0
    try:
        sys.stdout.write(notes(ROOT, arguments.version))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
