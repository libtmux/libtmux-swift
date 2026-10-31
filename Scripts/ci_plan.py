#!/usr/bin/env python3
r"""Plan the tmux axis of the CI matrix from one manifest and the triggering event.

`Scripts/tmux-matrix.json` is the only list of tmux versions CI uses. A push or
pull request runs its first and last released entries; a tag, a `schedule` run
and a dispatch with `scope: full` run all of it, the pinned `master` and the
refusal cells; a dispatch with `scope: custom` runs the refs it names. Nothing
here touches the network, so the same plan can be reproduced locally:

    python3 Scripts/ci_plan.py matrix --event push
    python3 Scripts/ci_plan.py matrix --event workflow_dispatch --scope custom \
        --tmux-ref 3.6b,master --tmate on-failure
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import NamedTuple

MANIFEST_PATH = pathlib.Path(__file__).with_name("tmux-matrix.json")

REF_PATTERN = re.compile(r"[A-Za-z0-9._/-]{1,64}")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
VERSION_PATTERN = re.compile(r"(\d+)\.(\d+)([a-z]?)")
SWIFT_PATTERN = re.compile(r"\d{1,2}\.\d{1,2}(\.\d{1,2})?")

SCOPES = ("edges", "full", "custom")
TMATE_MODES = ("off", "before-tests", "on-failure")
OS = "ubuntu-latest"

# GitHub rejects a matrix over 256 jobs; a dispatch that asks for more than
# this is a typo or a loop, and it is cheaper to refuse it here.
MAX_LEGS = 16


class PlanError(Exception):
    """The inputs describe a run CI will not make."""


class Manifest(NamedTuple):
    """The tmux versions CI knows about, oldest release first."""

    released: tuple[str, ...]
    preview: dict[str, str]
    refused: tuple[str, ...]
    clients: dict[str, str]
    swift: str
    version_checks: str

    @property
    def oldest(self) -> str:
        """Return the oldest released version, the support floor."""
        return self.released[0]

    @property
    def newest(self) -> str:
        """Return the newest released version."""
        return self.released[-1]


class Ref(NamedTuple):
    """One tmux to test: what to call it, what to resolve, how to build it."""

    name: str
    ref: str
    source: str


class Plan(NamedTuple):
    """What one run builds on the tmux axis."""

    scope: str
    test: tuple[dict[str, object], ...]
    refusal: tuple[dict[str, str], ...]
    refusal_planned: bool

    @property
    def tmux_jobs(self) -> int:
        """Return how many jobs the tmux axis expands to."""
        planned = len(self.refusal) if self.refusal_planned else 0
        return len(self.test) + planned

    def outputs(self) -> dict[str, str]:
        """Return the step outputs, each on one line."""
        return {
            "scope": self.scope,
            "test": _json({"include": list(self.test)}),
            "refusal": _json({"include": list(self.refusal)}),
            "refusal_planned": str(self.refusal_planned).lower(),
            "tmux_jobs": str(self.tmux_jobs),
        }


def _json(value: object) -> str:
    return json.dumps(value, separators=(",", ":"))


def version_key(version: str) -> tuple[int, int, str]:
    """Order a tmux release the way the library does: 3.7 < 3.7a < 3.7b."""
    match = VERSION_PATTERN.fullmatch(version)
    if match is None:
        message = f"{version!r} is not a tmux release such as 3.6 or 3.6b"
        raise PlanError(message)
    return int(match[1]), int(match[2]), match[3]


def _strings(raw: dict[str, object], key: str) -> tuple[str, ...]:
    value = raw.get(key)
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        message = f"the manifest needs {key!r} as a list of strings"
        raise PlanError(message)
    return tuple(value)


def _preview(raw: dict[str, object], released: tuple[str, ...]) -> dict[str, str]:
    value = raw.get("preview")
    if not isinstance(value, list):
        message = "the manifest needs 'preview' as a list"
        raise PlanError(message)
    preview: dict[str, str] = {}
    for entry in value:
        name = entry.get("name") if isinstance(entry, dict) else None
        commit = entry.get("commit") if isinstance(entry, dict) else None
        if (
            not isinstance(name, str)
            or REF_PATTERN.fullmatch(name) is None
            or name in released
            or name in preview
        ):
            message = f"preview entry {entry!r} needs a new name and a commit"
            raise PlanError(message)
        if not isinstance(commit, str) or SHA_PATTERN.fullmatch(commit) is None:
            message = f"preview {name} must pin a 40-hex commit"
            raise PlanError(message)
        preview[name] = commit
    return preview


def parse_manifest(raw: dict[str, object]) -> Manifest:
    """Validate a decoded manifest and return it."""
    released = _strings(raw, "released")
    refused = _strings(raw, "refused")
    preview = _preview(raw, released)
    clients = raw.get("clients")
    swift = raw.get("swift")
    checks = raw.get("version_checks")
    if not released:
        message = "the manifest lists no released tmux"
        raise PlanError(message)
    if not refused:
        message = "the manifest lists no refusal cell"
        raise PlanError(message)
    keys = [version_key(version) for version in released]
    if keys != sorted(set(keys)):
        message = "released tmux versions must be unique and oldest first"
        raise PlanError(message)
    for version in refused:
        if version_key(version) >= keys[0]:
            message = f"refusal cell {version} is not below the floor {released[0]}"
            raise PlanError(message)
    wanted = {"legacy", "legacy_through", "current"}
    if not isinstance(clients, dict) or set(clients) != wanted:
        message = f"the manifest needs 'clients' with {', '.join(sorted(wanted))}"
        raise PlanError(message)
    for role in ("legacy", "current"):
        if clients[role] not in released:
            message = f"the {role} client {clients[role]!r} must be a released tmux"
            raise PlanError(message)
    version_key(clients["legacy_through"])
    if not isinstance(swift, str) or SWIFT_PATTERN.fullmatch(swift) is None:
        message = "the manifest needs 'swift' such as 6.2"
        raise PlanError(message)
    if checks not in released:
        message = "'version_checks' must name a released tmux"
        raise PlanError(message)
    return Manifest(released, preview, refused, clients, swift, checks)


def load_manifest(path: pathlib.Path = MANIFEST_PATH) -> Manifest:
    """Read and validate the manifest at ``path``."""
    return parse_manifest(json.loads(path.read_text()))


def scope_for(event: str, ref_type: str, requested: str) -> str:
    """Return the scope an event runs at.

    An explicit request wins. Otherwise a tag and a ``schedule`` run the whole
    table, because a release must prove all of it, and everything else runs the
    edges.
    """
    if requested:
        if requested not in SCOPES:
            message = f"scope must be one of {', '.join(SCOPES)}, not {requested!r}"
            raise PlanError(message)
        return requested
    if event == "schedule" or (event == "push" and ref_type == "tag"):
        return "full"
    return "edges"


def _split(text: str) -> list[str]:
    items: list[str] = []
    for raw in text.split(","):
        item = raw.strip()
        if item and item not in items:
            items.append(item)
    return items


def _refs(text: str, manifest: Manifest) -> list[str]:
    refs = _split(text)
    for ref in refs:
        if REF_PATTERN.fullmatch(ref) is None or ref.startswith("-"):
            message = f"tmux-ref {ref!r} must match [A-Za-z0-9._/-]{{1,64}}"
            raise PlanError(message)
        if ref in manifest.refused:
            message = (
                f"tmux {ref} is below the floor; its refusal cell runs with scope full"
            )
            raise PlanError(message)
    return refs


def _swifts(text: str, manifest: Manifest) -> list[str]:
    versions = _split(text)
    for version in versions:
        if SWIFT_PATTERN.fullmatch(version) is None:
            message = f"swift {version!r} must look like 6.1 or 6.2.1"
            raise PlanError(message)
    return versions or [manifest.swift]


def _slug(ref: str) -> str:
    if SHA_PATTERN.fullmatch(ref):
        return ref[:12]
    return re.sub(r"[^A-Za-z0-9._-]", "-", ref)


def named_ref(manifest: Manifest, name: str, *, pinned: bool) -> Ref:
    """Say how a name from the manifest or a person is built.

    A release in the manifest keeps its tarball. The pinned preview commit is
    what `full` scope tests, so an upstream break reds nothing unrelated; a
    `custom` run that names the preview wants the tip instead.
    """
    if name in manifest.released:
        return Ref(name, name, "release")
    if pinned and name in manifest.preview:
        return Ref(name, manifest.preview[name], "git")
    return Ref(name, name, "git")


def chosen_refs(manifest: Manifest, scope: str, refs: list[str]) -> list[Ref]:
    """Return the tmux builds the test job covers for a scope."""
    if scope == "full":
        names = [*manifest.released, *manifest.preview]
        return [named_ref(manifest, name, pinned=True) for name in names]
    if scope == "custom" and refs:
        return [named_ref(manifest, name, pinned=False) for name in refs]
    return [
        named_ref(manifest, n, pinned=True) for n in (manifest.oldest, manifest.newest)
    ]


def refusal_in_scope(scope: str) -> bool:
    """Return whether the refusal cells run: only when the whole table does."""
    return scope == "full"


def client_for(manifest: Manifest, name: str) -> str:
    """Return the release built as the client for a daemon.

    A 3.3a client cannot speak to a 3.6 or newer daemon, so a daemon up to
    `legacy_through` gets the legacy client and everything else, including a
    branch or commit whose release is unknown, gets the current one.
    """
    clients = manifest.clients
    if VERSION_PATTERN.fullmatch(name) and version_key(name) <= version_key(
        clients["legacy_through"]
    ):
        return clients["legacy"]
    return clients["current"]


def _leg(build: Ref, swift: str, manifest: Manifest) -> dict[str, object]:
    client = client_for(manifest, build.name)
    own = build.source == "release" and build.name == client
    stack = swift == manifest.swift
    return {
        "os": OS,
        "tmux": build.name,
        "slug": _slug(build.name),
        "ref": build.ref,
        "source": build.source,
        "client": "" if own else client,
        "client_slug": _slug(build.name) if own else client,
        "swift": swift,
        "repo_checks": stack and build.name == manifest.newest,
        "version_checks": stack and build.name == manifest.version_checks,
        "tmate": "off",
    }


def assign_tmate(legs: list[dict[str, object]], tmate: str, event: str) -> None:
    """Give the one test leg a tmate session, or refuse the run."""
    if tmate in ("", "off"):
        return
    if tmate not in TMATE_MODES:
        message = f"tmate must be one of {', '.join(TMATE_MODES)}, not {tmate!r}"
        raise PlanError(message)
    if event != "workflow_dispatch":
        message = "tmate only runs from a workflow_dispatch"
        raise PlanError(message)
    if len(legs) != 1:
        message = (
            f"tmate needs exactly one test leg and this plan has {len(legs)}: "
            "use scope custom with one tmux-ref and at most one swift"
        )
        raise PlanError(message)
    legs[0]["tmate"] = tmate


def make_plan(
    manifest: Manifest,
    *,
    event: str,
    ref_type: str = "",
    scope: str = "",
    tmux_ref: str = "",
    swift: str = "",
    tmate: str = "",
) -> Plan:
    """Return the plan for one event and its dispatch inputs."""
    effective = scope_for(event, ref_type, scope)
    refs = _refs(tmux_ref, manifest)
    swifts = _swifts(swift, manifest)
    if refs and effective != "custom":
        message = "tmux-ref only applies with scope custom"
        raise PlanError(message)
    if effective == "custom" and not refs and not swift.strip():
        message = "scope custom needs a tmux-ref or a swift version"
        raise PlanError(message)

    legs = [
        _leg(build, version, manifest)
        for build in chosen_refs(manifest, effective, refs)
        for version in swifts
    ]
    if len(legs) > MAX_LEGS:
        message = f"{len(legs)} test legs is over the limit of {MAX_LEGS}"
        raise PlanError(message)
    assign_tmate(legs, tmate, event)
    if not legs:
        message = "the plan has no test leg"
        raise PlanError(message)

    # The refusal cells are always described, so the matrix is never empty
    # even when the job is skipped; `refusal_planned` says whether they run.
    refusal = tuple(
        {
            "tmux": version,
            "client": manifest.clients["legacy"],
            "swift": manifest.swift,
        }
        for version in manifest.refused
    )
    return Plan(
        effective,
        tuple(legs),
        refusal,
        refusal_planned=refusal_in_scope(effective),
    )


def expected_result(job: str, *, refusal_planned: bool) -> str:
    """Return the result a job must report for the aggregate to pass.

    Every job must have succeeded. The refusal cells are the one exception:
    they are skipped when the plan put them out of scope.
    """
    if job == "refusal" and not refusal_planned:
        return "skipped"
    return "success"


def verify_needs(
    needs: dict[str, dict[str, object]], *, refusal_planned: bool
) -> list[str]:
    """Return what is wrong with the results the aggregate job saw."""
    problems = []
    for name, info in sorted(needs.items()):
        expected = expected_result(name, refusal_planned=refusal_planned)
        result = info.get("result")
        if result != expected:
            problems.append(f"{name} reported {result}, expected {expected}")
    return problems


def _summary(plan: Plan) -> str:
    legs = ", ".join(f"{leg['tmux']} (swift {leg['swift']})" for leg in plan.test)
    refusals = (
        ", ".join(leg["tmux"] for leg in plan.refusal)
        if plan.refusal_planned
        else "out of scope"
    )
    return "\n".join(
        [
            f"scope: {plan.scope}",
            f"test: {legs}",
            f"refusal: {refusals}",
            f"tmux jobs: {plan.tmux_jobs}",
        ]
    )


def _run_matrix(args: argparse.Namespace) -> int:
    plan = make_plan(
        load_manifest(),
        event=args.event,
        ref_type=args.ref_type,
        scope=args.scope,
        tmux_ref=args.tmux_ref,
        swift=args.swift,
        tmate=args.tmate,
    )
    print(_summary(plan))
    if args.github_output:
        with pathlib.Path(args.github_output).open("a") as output:
            output.writelines(f"{k}={v}\n" for k, v in plan.outputs().items())
    return 0


def _run_verify(args: argparse.Namespace) -> int:
    needs = json.loads(args.needs)
    problems = verify_needs(needs, refusal_planned=args.refusal_planned == "true")
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    """Plan the matrix, or check the results of the jobs it ran."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    matrix = subparsers.add_parser("matrix", help="print the plan for an event")
    matrix.add_argument("--event", required=True)
    matrix.add_argument("--ref-type", default="")
    matrix.add_argument("--scope", default="")
    matrix.add_argument("--tmux-ref", default="")
    matrix.add_argument("--swift", default="")
    matrix.add_argument("--tmate", default="")
    matrix.add_argument("--github-output", default="")
    matrix.set_defaults(handler=_run_matrix)

    verify = subparsers.add_parser("verify", help="check the aggregate job's needs")
    verify.add_argument("--needs", required=True, help="the JSON of `needs`")
    verify.add_argument("--refusal-planned", default="false")
    verify.set_defaults(handler=_run_verify)

    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except PlanError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
