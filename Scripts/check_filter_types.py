#!/usr/bin/env python3
"""Compile public filter consumers and reject unsupported typed expressions."""

from __future__ import annotations

import argparse
import json
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


def _dependency_checkout(swift: list[str], identity: str) -> pathlib.Path:
    """Find where SwiftPM resolved one dependency to, by package identity.

    `.build/checkouts/<name>` assumes the checkout directory is always named
    after the package and always lives under `checkouts`, which stops holding
    the moment a dependency moves to a renamed fork or a local path override.
    Asking SwiftPM directly reports whatever a bump or an override actually
    resolved to, so a missing header reports as the dependency it belongs to
    rather than as an unrelated filter-type regression.

    Parameters
    ----------
    swift : list[str]
        The `swift` invocation, already split into argv.
    identity : str
        The package identity to find, as SwiftPM names it.

    Returns
    -------
    pathlib.Path
        Where that dependency's sources are checked out.
    """
    described = json.loads(
        subprocess.check_output(
            [*swift, "package", "show-dependencies", "--format", "json"],
            cwd=ROOT,
            text=True,
        )
    )

    def walk(node: dict) -> pathlib.Path | None:
        if node.get("identity") == identity:
            return pathlib.Path(node["path"])
        for child in node.get("dependencies", []):
            found = walk(child)
            if found is not None:
                return found
        return None

    found = walk(described)
    if found is None:
        message = (
            f"dependency {identity!r} is not resolved; run `swift package resolve`"
        )
        raise SystemExit(message)
    return found


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
    swift_system = _dependency_checkout(swift, "swift-system")
    swift_subprocess = _dependency_checkout(swift, "swift-subprocess")
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
        str(swift_system / "Sources" / "CSystem" / "include"),
        "-I",
        str(swift_subprocess / "Sources" / "_SubprocessCShims" / "include"),
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
