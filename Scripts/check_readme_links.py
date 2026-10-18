#!/usr/bin/env python3
"""Require every README link that points into this project to resolve.

A README link is a claim about where something lives. Three kinds go stale
without anyone editing the page: a link into this repository after a directory
moves, a link to an API page after a type is renamed, and a link to a tool page
after a tool is renamed. This reads every `README.md` and checks all of them
against the tree, with no network, so it can run on every push:

- `https://github.com/libtmux/libtmux-swift/tree/master/<path>` and relative
  links name a path that exists, and a `#fragment` names a heading that exists.
- A libtmux.org API page names a public symbol the sources declare, and a tool
  page names a tool in `ToolOperation`.
- A reference-style link has a definition.
- The root README and the core README link every product directory from a
  heading, and the root README links the types a reader meets first.
- No prose block in a product README runs past `WALL_LIMIT` rendered characters.
  Detail a caller does not need to run the package belongs in `docs/` or on
  libtmux.org, linked from a short bullet.

That the page answers 200 once published is a separate fact: the documentation
workflow publishes after a merge, so this gate cannot wait on it.

    python3 Scripts/check_readme_links.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

SITE = "https://libtmux.org/en/swift/latest/"
TREE = re.compile(
    r"^https://github\.com/libtmux/libtmux-swift/(?:tree|blob)/master/(.+)$"
)

# Each API section of libtmux.org, and the source directories whose public
# symbols its pages are generated from.
API_SECTIONS = {
    "reference/": ("Sources/LibTmux", "Tests/TmuxFixture"),
    "workspace/reference/": ("Sources/TmuxWorkspace",),
    "mcp/reference/": ("Sources/LibTmuxMCP",),
}

# Pages in those sections that describe the section rather than one symbol.
SECTION_PAGES = {"glossary", "compatibility", "output", "exit-codes"}

TOOLS_SOURCE = "Sources/LibTmuxMCP/ToolOperation.swift"

# The types a reader meets first, which the root README must link by name.
REQUIRED_API = {
    "reference/": ["server", "session", "window", "pane", "filterexpr", "tmuxmode"],
    "workspace/reference/": ["workspace", "workspacebuilder"],
    "mcp/reference/": ["tmuxtools", "toolauthority"],
}

# READMEs whose product headings must each link a product directory.
HEADING_READMES = ("README.md", "Sources/LibTmux/README.md")

# A paragraph, list item, or quote longer than this, once its link syntax and
# code ticks are removed, is a wall: roughly three lines at 80 columns.
WALL_LIMIT = 240

FENCE = re.compile(r"^```")
INLINE = re.compile(r"\]\(<?([^)\s>]+)>?\)")
ATTRIBUTE = re.compile(r'(?:src|srcset|href)="([^"]+)"')
DEFINITION = re.compile(r"^\[([^\]]+)\]:\s*<?([^>\s]+)>?\s*$")
FULL_REFERENCE = re.compile(r"\]\[([^\]]+)\]")
CODE_SHORTCUT = re.compile(r"\[(`[^`\]]+`)\](?![(:\[])")
PUBLIC = re.compile(
    r"\bpublic\s+(?:(?:final|indirect|static|nonisolated)\s+)*"
    r"(?:struct|enum|class|actor|protocol|typealias|func|var|let)\s+(\w+)",
)
CASE = re.compile(r'case \w+ = "(\w+)"')


def prose(text: str) -> list[str]:
    """Return the lines of `text` that are outside fenced code blocks."""
    lines: list[str] = []
    inside = False
    for line in text.splitlines():
        if FENCE.match(line):
            inside = not inside
        elif not inside:
            lines.append(line)
    return lines


def definitions(lines: list[str]) -> dict[str, str]:
    """Map each reference label, lowercased, to its target."""
    found: dict[str, str] = {}
    for line in lines:
        match = DEFINITION.match(line)
        if match is not None:
            found[match.group(1).lower()] = match.group(2)
    return found


def used_labels(lines: list[str]) -> list[str]:
    """List every reference label a line of prose asks to resolve."""
    labels: list[str] = []
    for line in lines:
        if DEFINITION.match(line):
            continue
        labels += FULL_REFERENCE.findall(line)
        labels += CODE_SHORTCUT.findall(line)
    return labels


def targets(lines: list[str], defined: dict[str, str]) -> list[str]:
    """List every URL or path a page links, whether inline or by reference."""
    found: list[str] = []
    for line in lines:
        found += INLINE.findall(line)
        found += ATTRIBUTE.findall(line)
    found += defined.values()
    return found


def slug(heading: str) -> str:
    """Return the anchor GitHub gives a heading."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)|\[([^\]]*)\]\[[^\]]*\]", r"\1\2", heading)
    text = text.replace("`", "").lower()
    kept = "".join(c for c in text if c.isalnum() or c in " -_")
    return kept.strip().replace(" ", "-")


def anchors(lines: list[str]) -> set[str]:
    """List the anchors the headings of a page define."""
    return {slug(line.lstrip("#")) for line in lines if re.match(r"#{1,6} ", line)}


def public_names(root: pathlib.Path, directories: tuple[str, ...]) -> set[str]:
    """List the lowercased public symbols the Swift sources declare."""
    names: set[str] = set()
    for directory in directories:
        for path in sorted((root / directory).rglob("*.swift")):
            names.update(n.lower() for n in PUBLIC.findall(path.read_text()))
    return names


def tool_names(root: pathlib.Path) -> set[str]:
    """List the MCP tool names `ToolOperation` declares."""
    path = root / TOOLS_SOURCE
    return set(CASE.findall(path.read_text())) if path.exists() else set()


def readmes(root: pathlib.Path) -> list[pathlib.Path]:
    """List every README, and every page under `docs/`, outside hidden directories."""
    found = list(root.rglob("README.md")) + list((root / "docs").glob("*.md"))
    return sorted(
        path
        for path in found
        if not any(part.startswith(".") for part in path.relative_to(root).parts)
    )


def product_directories(root: pathlib.Path) -> list[str]:
    """List the directories that ship a product and keep a README."""
    found = [
        path.parent.relative_to(root).as_posix()
        for path in sorted((root / "Sources").glob("*/README.md"))
    ]
    fixture = root / "Tests/TmuxFixture/README.md"
    return found + (["Tests/TmuxFixture"] if fixture.exists() else [])


def check_target(
    root: pathlib.Path,
    page: pathlib.Path,
    target: str,
    symbols: dict[str, set[str]],
    tools: set[str],
) -> list[str]:
    """Return what is wrong with one link, or nothing."""
    if target.startswith(SITE):
        return check_site(target.removeprefix(SITE), symbols, tools)
    tree = TREE.match(target)
    if tree is not None:
        path = tree.group(1).split("#")[0].rstrip("/")
        return [] if (root / path).exists() else [f"{target} names no path here"]
    if re.match(r"^[a-z][a-z0-9+.-]*:", target) or target.startswith("mailto:"):
        return []
    path_part, _, fragment = target.partition("#")
    resolved = page if not path_part else (page.parent / path_part).resolve()
    if not resolved.exists():
        return [f"{target} names no path here"]
    if fragment and resolved.suffix == ".md":
        known = anchors(prose(resolved.read_text()))
        if fragment not in known:
            return [f"{target} names no heading in {resolved.name}"]
    return []


def check_site(
    path: str,
    symbols: dict[str, set[str]],
    tools: set[str],
) -> list[str]:
    """Return what is wrong with a libtmux.org link, or nothing."""
    page = SITE + path
    if path.startswith("mcp/tools/"):
        name = path.removeprefix("mcp/tools/").strip("/")
        if name and name not in tools:
            return [f"{page} names no tool in ToolOperation"]
        return []
    for section in sorted(API_SECTIONS, key=len, reverse=True):
        if not path.startswith(section):
            continue
        slug_ = path.removeprefix(section).strip("/")
        if not slug_ or "/" in slug_ or slug_ in SECTION_PAGES:
            return []
        leading = re.split(r"[-(]", slug_, maxsplit=1)[0]
        if leading not in symbols[section]:
            return [f"{page} names no public symbol the sources declare"]
        return []
    return []


def rendered(text: str) -> str:
    """Return `text` as a reader sees it: link text and code, without markup."""
    text = re.sub(r"\[([^\]]*)\]\[[^\]]*\]", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"\[(`[^`]+`)\]", r"\1", text)
    return " ".join(text.replace("`", "").split())


def walls(lines: list[str]) -> list[str]:
    """Return the start of every prose block longer than `WALL_LIMIT`.

    A block is a paragraph, a list item, or a quote. Tables, headings, HTML,
    reference definitions, and the `**Contents**` index line are not prose.
    """
    found: list[str] = []
    block: list[str] = []

    def flush() -> None:
        text = rendered(" ".join(block))
        if len(text) > WALL_LIMIT:
            found.append(text[:60])
        block.clear()

    for line in lines:
        skip = (
            not line.strip()
            or line.lstrip().startswith(("|", "<", "#"))
            or line.startswith("**Contents**")
            or DEFINITION.match(line)
        )
        if skip or re.match(r"\s*(?:[-*]|\d+\.)\s", line):
            flush()
        if not skip:
            block.append(line)
    flush()
    return found


def check_headings(
    root: pathlib.Path,
    relative: str,
    lines: list[str],
    defined: dict[str, str],
) -> list[str]:
    """Require a product heading to link each product directory."""
    linked: set[str] = set()
    for line in lines:
        if not re.match(r"#{2,6} ", line):
            continue
        urls = INLINE.findall(line)
        urls += [
            defined.get(label.lower(), "") for label in FULL_REFERENCE.findall(line)
        ]
        for url in urls:
            tree = TREE.match(url)
            if tree is not None:
                linked.add(tree.group(1).rstrip("/"))
    return [
        f"{relative}: no heading links https://github.com/libtmux/libtmux-swift"
        f"/tree/master/{directory}"
        for directory in product_directories(root)
        if directory not in linked
    ]


def check(
    root: pathlib.Path = ROOT,
    required: dict[str, list[str]] | None = None,
) -> list[str]:
    """Return every problem the READMEs under `root` have."""
    wanted = REQUIRED_API if required is None else required
    symbols = {
        section: public_names(root, directories)
        for section, directories in API_SECTIONS.items()
    }
    tools = tool_names(root)
    wall_checked = {"README.md"} | {f"{d}/README.md" for d in product_directories(root)}
    problems: list[str] = []
    for page in readmes(root):
        relative = page.relative_to(root).as_posix()
        lines = prose(page.read_text())
        defined = definitions(lines)
        problems += [
            f"{relative}: [{label}] has no definition"
            for label in sorted(set(used_labels(lines)))
            if label.lower() not in defined
        ]
        for target in sorted(set(targets(lines, defined))):
            problems += [
                f"{relative}: {problem}"
                for problem in check_target(root, page, target, symbols, tools)
            ]
        if relative in HEADING_READMES:
            problems += check_headings(root, relative, lines, defined)
        if relative in wall_checked:
            problems += [
                f"{relative}: a block over {WALL_LIMIT} characters starts {start!r}"
                for start in walls(lines)
            ]
        if relative == "README.md":
            linked = set(targets(lines, {}))
            linked |= {
                defined[x.lower()] for x in used_labels(lines) if x.lower() in defined
            }
            for section, slugs in wanted.items():
                problems += [
                    f"{relative}: never links {SITE}{section}{name}/"
                    for name in slugs
                    if f"{SITE}{section}{name}/" not in linked
                ]
    return problems


def main() -> int:
    """Report every README link that does not resolve."""
    problems = check()
    if problems:
        print(f"{len(problems)} README link problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"{len(readmes(ROOT))} READMEs checked; every link resolves")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
