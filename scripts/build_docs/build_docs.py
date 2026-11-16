#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Build the DocC catalogs and fail when DocC reports a warning.

Run it from the package root, once for the three documented targets:

    uv run scripts/build_docs/build_docs.py

It runs `swift package --force-resolved-versions generate-documentation` for
each target in turn, passes the output through as it is written, and appends it
to `docs.log`, which it empties first. A failing build stops the run with the
build's own status. When every build succeeds, any line that says `warning:`
fails the run with that line and the three after it, because a DocC warning is
a broken link or a missing symbol that no reader sees until the page is wrong.
"""

import argparse
import pathlib
import subprocess
import sys
from collections.abc import Callable, Iterable, Sequence

TARGETS = ("LibTmux", "TmuxWorkspace", "LibTmuxMCP")
WARNING = "warning:"
CONTEXT = 3


def swift_command(target: str) -> list[str]:
    """Return the command that builds the documentation of one target."""
    return [
        "swift",
        "package",
        "--force-resolved-versions",
        "generate-documentation",
        "--target",
        target,
    ]


def warning_report(lines: Sequence[str]) -> list[str]:
    """Return each warning line with the lines after it, groups apart by `--`.

    A line that follows another group's context joins that group, as a search
    tool prints it, so two warnings close together read as one block.
    """
    keep: set[int] = set()
    for index, line in enumerate(lines):
        if WARNING in line:
            keep.update(range(index, min(index + CONTEXT + 1, len(lines))))
    report: list[str] = []
    previous = -2
    for index in sorted(keep):
        if report and index != previous + 1:
            report.append("--")
        report.append(lines[index])
        previous = index
    return report


def run_target(
    command: list[str], log: pathlib.Path, output: Callable[[str], object]
) -> tuple[int, list[str]]:
    """Run one build, pass its output on and into `log`, and return its status."""
    lines: list[str] = []
    with (
        subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        ) as child,
        log.open("a", encoding="utf-8") as sink,
    ):
        for line in child.stdout or ():
            output(line)
            sink.write(line)
            lines.append(line.rstrip("\n"))
    return child.returncode, lines


def build(
    targets: Iterable[str],
    log: pathlib.Path,
    command: Callable[[str], list[str]] = swift_command,
) -> int:
    """Build each target, and return the first failure or 1 for a warning."""
    log.write_text("", encoding="utf-8")
    lines: list[str] = []
    for target in targets:
        status, output = run_target(command(target), log, sys.stdout.write)
        if status != 0:
            return status
        lines.extend(output)
    report = warning_report(lines)
    if not report:
        return 0
    print("::error::DocC reported warnings")
    print("\n".join(report))
    return 1


def main(argv: Sequence[str] | None = None) -> int:
    """Parse the command line and build the documentation."""
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0] if __doc__ else None
    )
    parser.add_argument("--log", type=pathlib.Path, default=pathlib.Path("docs.log"))
    parser.add_argument("targets", nargs="*", default=TARGETS)
    options = parser.parse_args(argv)
    return build(options.targets, options.log)


if __name__ == "__main__":
    raise SystemExit(main())
