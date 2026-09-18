#!/usr/bin/env python3
"""Check that every API break since the last release is declared.

`swift package diagnose-api-breaking-changes` reports what the public surface
lost or changed since a baseline. On its own it answers only "did anything
break", which for an alpha that breaks deliberately is not the useful question.
The useful one is "is every break a decision someone wrote down", and that is
what this adds:

- A break not named in `.github/api-breakage-allowlist.txt` fails. Nothing
  reaches a consumer unannounced.
- An allowlist entry that no longer describes a real break fails. The file
  cannot accumulate lines that stopped meaning anything.
- A break to a `public` declaration that `CHANGELOG.md` does not carry under
  `## [Unreleased]` fails. `package` declarations are exempt: they are reachable
  only from this package's own targets, so a consumer never sees them change.

The allowlist keeps the format the toolchain documents -- one exact message per
line, nothing else -- so it can also be handed straight to
`--breakage-allowlist-path`. That format tolerates no comments: a single
non-message line silently voids every entry in the file, which is why the
justification lives in `CHANGELOG.md` rather than beside the entry.

    python3 Scripts/check_api_breakage.py
    python3 Scripts/check_api_breakage.py --baseline 0.1.0-alpha.5
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys

# Captured with the `API breakage: ` prefix the toolchain prints, because that
# is the form `--breakage-allowlist-path` matches, and the file stays usable
# with the toolchain directly.
BREAKAGE = re.compile(r"(API breakage: .+?)\s*$")
# `API breakage: enumelement TmuxError.foreignPaneValue has been added...`,
# `API breakage: func Server.scanForward(_:since:) has parameter 5 type...`
SYMBOL = re.compile(r"^API breakage: \w+ ([A-Za-z_][\w.]*)")
UNRELEASED = re.compile(r"^## \[Unreleased\]")
RELEASED = re.compile(r"^## \[(?!Unreleased)")


def ensure_baseline(package: pathlib.Path, baseline: str) -> None:
    """Make `baseline` resolvable, fetching just that tag when it is not.

    CI checks out one commit, so a tag is absent there even though it exists
    on the remote. Without this the comparison fails for a reason that has
    nothing to do with the API.
    """
    resolved = subprocess.run(
        ["git", "rev-parse", "--verify", f"{baseline}^{{commit}}"],
        cwd=package,
        capture_output=True,
        text=True,
        check=False,
    )
    if resolved.returncode == 0:
        return
    fetched = subprocess.run(
        [
            "git",
            "fetch",
            "--depth=1",
            "origin",
            f"refs/tags/{baseline}:refs/tags/{baseline}",
        ],
        cwd=package,
        capture_output=True,
        text=True,
        check=False,
    )
    if fetched.returncode != 0:
        print(fetched.stdout + fetched.stderr, file=sys.stderr, end="")
        message = f"cannot resolve or fetch the baseline tag {baseline}"
        raise SystemExit(message)


def reported_breaks(package: pathlib.Path, baseline: str) -> list[str]:
    """Every breakage message the toolchain reports against `baseline`.

    `swift` is not always on PATH -- a toolchain manager may front it -- so the
    command comes from `$SWIFT`, the same way the benchmark's gate finds it.
    """
    swift = shlex.split(os.environ.get("SWIFT", "swift"))
    result = subprocess.run(
        [
            *swift,
            "package",
            "--force-resolved-versions",
            "diagnose-api-breaking-changes",
            baseline,
        ],
        cwd=package,
        capture_output=True,
        text=True,
        check=False,
    )
    messages = [
        found.group(1)
        for line in (result.stdout + result.stderr).splitlines()
        if (found := BREAKAGE.search(line))
    ]
    if not messages and result.returncode != 0:
        # No breaks and a failure is the toolchain itself failing -- a missing
        # baseline tag in a shallow clone is the usual reason -- and reporting
        # that as "nothing broke" would turn a broken gate into a green one.
        print(result.stdout + result.stderr, file=sys.stderr, end="")
        message = f"diagnose-api-breaking-changes failed against {baseline}"
        raise SystemExit(message)
    return messages


def public_symbols(root: pathlib.Path) -> set[str]:
    """Every member name declared `public` anywhere under `root`."""
    declaration = re.compile(
        r"^\s*public\s+(?:static\s+|class\s+|final\s+|indirect\s+|mutating\s+|nonisolated\s+)*"
        r"(?:func|var|let|case|init|struct|enum|class|actor|protocol|typealias|subscript)"
        r"\s*(\w*)"
    )
    names = set()
    for path in sorted(root.rglob("*.swift")):
        for line in path.read_text(encoding="utf-8").splitlines():
            found = declaration.match(line)
            if found and found.group(1):
                names.add(found.group(1))
    return names


def unreleased_section(changelog: pathlib.Path) -> str:
    """Return the changelog text between `## [Unreleased]` and the release below."""
    lines = changelog.read_text(encoding="utf-8").splitlines()
    collected: list[str] = []
    inside = False
    for line in lines:
        if UNRELEASED.match(line):
            inside = True
            continue
        if inside and RELEASED.match(line):
            break
        if inside:
            collected.append(line)
    return "\n".join(collected)


def failures(
    reported: list[str],
    allowed: list[str],
    exported: set[str],
    unreleased: str,
    allowlist: pathlib.Path,
) -> list[str]:
    """Every way the declared breaks and the reported ones disagree."""
    found: list[str] = [
        f"undeclared API break:\n    {message}\n"
        f"  Add that exact line to {allowlist} and describe it "
        f"in CHANGELOG.md under ## [Unreleased]."
        for message in reported
        if message not in allowed
    ]

    for entry in allowed:
        if entry not in reported:
            found.append(
                f"stale allowlist entry, no longer a break:\n    {entry}\n"
                f"  Remove it from {allowlist}."
            )
            continue
        symbol = SYMBOL.match(entry)
        if not symbol:
            continue
        member = symbol.group(1).rsplit(".", 1)[-1]
        # A `package` declaration cannot be seen from outside this package, so
        # its change is not something a consumer has to be told about.
        if member in exported and member not in unreleased:
            found.append(
                f"public API break absent from the changelog:\n    {entry}\n"
                f"  CHANGELOG.md's ## [Unreleased] section does not mention "
                f"`{member}`."
            )

    return found


def main() -> int:
    """Compare the reported breaks with the declared ones."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="0.1.0-alpha.5")
    parser.add_argument("--package", type=pathlib.Path, default=pathlib.Path())
    parser.add_argument("--sources", type=pathlib.Path, default=pathlib.Path("Sources"))
    parser.add_argument(
        "--changelog", type=pathlib.Path, default=pathlib.Path("CHANGELOG.md")
    )
    parser.add_argument(
        "--allowlist",
        type=pathlib.Path,
        default=pathlib.Path(".github/api-breakage-allowlist.txt"),
    )
    arguments = parser.parse_args()

    allowed = [
        line.rstrip("\n")
        for line in arguments.allowlist.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    ensure_baseline(arguments.package, arguments.baseline)
    reported = reported_breaks(arguments.package, arguments.baseline)
    exported = public_symbols(arguments.sources)
    unreleased = unreleased_section(arguments.changelog)

    found = failures(reported, allowed, exported, unreleased, arguments.allowlist)
    if found:
        for failure in found:
            print(f"error: {failure}", file=sys.stderr)
        return 1

    print(
        f"{len(reported)} API break(s) against {arguments.baseline}, "
        f"each allowlisted and declared"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
