#!/usr/bin/env python3
"""Compile public filter consumers and reject unsupported typed expressions."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shlex
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Examples" / "TypeChecks"
DIAGNOSTICS = {
    "unsupported-field.swift": r"has no member 'width'",
    "wrong-operation.swift": r"cannot convert value of type 'FilterField<Pane, Int>'",
    "wrong-root.swift": r"cannot convert value of type 'FilterField<Session, String>'",
    "forged-field.swift": (
        r"initializer is inaccessible due to 'fileprivate' protection level"
    ),
    "wrong-identifier.swift": (
        r"cannot convert value of type 'SessionID' "
        r"to expected argument type 'PaneID'"
    ),
}


def main() -> int:
    """Check successful imports before attributing failures to the type system."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--jobs", default="2")
    args = parser.parse_args()
    swift = shlex.split(os.environ.get("SWIFT", "swift"))
    swiftc = [*swift[:-1], str(pathlib.Path(swift[-1]).with_name("swiftc"))]
    if not args.skip_build:
        subprocess.run(
            [*swift, "build", "--jobs", args.jobs, "--force-resolved-versions"],
            cwd=ROOT,
            check=True,
        )
    binary = pathlib.Path(
        subprocess.check_output(
            [*swift, "build", "--show-bin-path", "--force-resolved-versions"],
            cwd=ROOT,
            text=True,
        ).strip()
    )
    command = [
        *swiftc,
        "-typecheck",
        "-parse-as-library",
        "-swift-version",
        "6",
        "-strict-concurrency=complete",
        "-warnings-as-errors",
        "-I",
        str(binary / "Modules"),
        "-I",
        str(ROOT / ".build/checkouts/swift-system/Sources/CSystem/include"),
        "-I",
        str(
            ROOT / ".build/checkouts/swift-subprocess/Sources/_SubprocessCShims/include"
        ),
    ]
    fixtures = [("filter-fields.swift", None), *DIAGNOSTICS.items()]
    for name, diagnostic in fixtures:
        result = subprocess.run(
            [*command, str(FIXTURES / name)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
        output = result.stdout.replace(str(ROOT), "<repository>")
        if diagnostic is None:
            passed = result.returncode == 0
        else:
            passed = (
                result.returncode == 1 and re.search(diagnostic, output) is not None
            )
        if not passed:
            print(f"FAIL: {name} (compiler status {result.returncode})")
            print(output)
            return 1
        print(f"PASS: {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
