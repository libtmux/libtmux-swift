#!/usr/bin/env python3
"""Check that the docs and the workflows follow the CI manifest.

`Scripts/tmux-matrix.json` is the one list of tmux versions. This fails when a
page states a range or a table the manifest does not, when the workflow carries
a version list of its own, and when the workflow structure the plan relies on
has been undone: a dispatch input spliced into a script, a tmate step that is
not pinned or not limited to the actor, an aggregate job that forgot a job, a
workflow that no longer runs on a tag, a script that calls apt-get or apt
without `Scripts/apt-get.sh`.

    python3 Scripts/check_ci.py
"""

from __future__ import annotations

import argparse
import importlib.util
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

RANGE_PAGES = (
    "README.md",
    "Sources/LibTmux/LibTmux.docc/PlatformSupport.md",
    "Sources/LibTmux/LibTmux.docc/LibTmux.md",
    "Sources/TmuxWorkspaceCLI/README.md",
)
EDGE_PAGES = ("README.md", ".github/CONTRIBUTING.md")
CONTRIBUTING = ".github/CONTRIBUTING.md"
WORKFLOWS = ".github/workflows"
ACTIONS = ".github/actions"

RANGE_CLAIM = re.compile(r"(\d+\.\d+[a-z]?) through (\d+\.\d+[a-z]?), and (\w+)")
TABLE_ROW = re.compile(r"\| tmux \| ([^|]+?) \|")
TMATE = re.compile(r"uses:\s*mxschmitt/action-tmate@(\S+)")
SPLICED = re.compile(
    r"\$\{\{[^}]*\b("
    r"inputs\.|github\.event\.inputs|needs\.plan\.outputs"
    r"|matrix\.(?:tmux|slug|ref|source|client|client_slug|swift|tmate)"
    r"|steps\.[\w-]+\.outputs"
    r")"
)
RUN_KEY = re.compile(r"^(\s*)(?:- )?run:\s*(.*)$")
# `apt-get` or `apt` where a command starts: after a separator, a shell keyword,
# or `sudo`/`env`, their options and any VAR=value words. A path such as
# `./Scripts/apt-get.sh` and `apt-cache` do not match.
RAW_APT = re.compile(
    r"(?:^|[;&|({]|\b(?:then|do|else|sudo|env|exec|time)\b)"
    r"(?:\s+(?:-\S+|\w+=\S*))*\s*(apt-get|apt)(?![\w./-])"
)
STEP_START = re.compile(r"^(\s*)- (?:name|id|if|uses|run|env|with|shell):")
JOB_ID = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def _load_plan() -> object:
    path = pathlib.Path(__file__).with_name("ci_plan.py")
    spec = importlib.util.spec_from_file_location("ci_plan", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _squash(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def _code(text: str) -> str:
    """Return a workflow without its comment lines."""
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
    return "\n".join(lines)


def _run_bodies(text: str) -> list[tuple[int, str]]:
    """Return each line of every `run:` script with its line number."""
    lines = text.splitlines()
    bodies: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        match = RUN_KEY.match(lines[index])
        index += 1
        if not match:
            continue
        indent, value = len(match[1]), match[2]
        if value and not value.startswith(("|", ">")):
            bodies.append((index, value))
            continue
        while index < len(lines):
            line = lines[index]
            if line.strip() and len(line) - len(line.lstrip()) <= indent:
                break
            bodies.append((index + 1, line))
            index += 1
    return bodies


def _jobs(text: str) -> dict[str, str]:
    """Return each top-level job of a workflow, by id, with its text."""
    section = text.split("\njobs:\n", 1)[-1]
    parts = re.split(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", section)
    return dict(zip(parts[1::2], parts[2::2], strict=True))


def _steps(job: str) -> list[str]:
    return re.split(r"(?m)^      - ", job)[1:]


def _where(lines: list[str], number: int) -> str:
    """Return the job and step that line `number` (1-based) of a workflow is in."""
    start = next(
        (i for i in range(number - 1, -1, -1) if STEP_START.match(lines[i])), None
    )
    if start is None:
        return "outside a step"
    indent = len(STEP_START.match(lines[start])[1])
    named = re.compile(rf"^ {{{indent}}}(?:- |  )name:\s*(.*?)\s*$")
    end = next(
        (i for i in range(start + 1, len(lines)) if STEP_START.match(lines[i])),
        len(lines),
    )
    step = "unnamed"
    for line in lines[start:end]:
        if match := named.match(line):
            step = repr(match[1].strip("'\""))
            break
    job = ""
    if "jobs:" in lines:
        for line in reversed(lines[:start]):
            if line == "jobs:":
                break
            if match := JOB_ID.match(line):
                job = f"job {match[1]}, "
                break
    return f"{job}step {step}"


def check_apt(text: str, name: str) -> list[str]:
    """Return each `run` line of a workflow or action that calls apt directly."""
    lines = text.splitlines()
    problems: list[str] = []
    for number, body in _run_bodies(text):
        call = None if body.lstrip().startswith("#") else RAW_APT.search(body)
        if call:
            problems.append(
                f"{name}:{number} {_where(lines, number)} calls {call[1]} directly; "
                "run it through Scripts/apt-get.sh"
            )
    return problems


def check_docs(root: pathlib.Path, manifest: object) -> list[str]:
    """Return where a page disagrees with the manifest."""
    problems: list[str] = []
    preview = next(iter(manifest.preview))
    ends = (manifest.oldest, manifest.newest)
    for page in RANGE_PAGES:
        stated = RANGE_CLAIM.findall(_squash((root / page).read_text()))
        if not stated:
            problems.append(
                f"{page} does not say tmux {ends[0]} through {ends[1]}, and {preview}"
            )
        problems += [
            f"{page} says tmux {first} through {last}, and {name}, "
            f"not {ends[0]} through {ends[1]}, and {preview}"
            for first, last, name in stated
            if (first, last, name) != (*ends, preview)
        ]

    contributing = _squash((root / CONTRIBUTING).read_text())
    row = TABLE_ROW.search(contributing)
    wanted = ", ".join([*manifest.released, *manifest.preview])
    if row is None:
        problems.append(f"{CONTRIBUTING} has no tmux row in its compatibility table")
    elif row[1] != wanted:
        problems.append(f"{CONTRIBUTING} lists tmux {row[1]}, not {wanted}")

    edges = f"{ends[0]} and {ends[1]}"
    problems += [
        f"{page} does not say a push tests the edges, {edges}"
        for page in EDGE_PAGES
        if edges not in _squash((root / page).read_text())
    ]
    problems += [
        f"{CONTRIBUTING} does not name the refusal cell {version}"
        for version in manifest.refused
        if not re.search(rf"(?<![\w.]){re.escape(version)}(?![\w.])", contributing)
    ]
    if "gh workflow run ci.yml" not in contributing:
        problems.append(f"{CONTRIBUTING} has no `gh workflow run ci.yml` command")
    return problems


def _check_tmate_step(step: str) -> str:
    pin = TMATE.search(step)[1]
    if re.fullmatch(r"[0-9a-f]{40}", pin) is None:
        return f"action-tmate is pinned to {pin}, not a full commit"
    if "limit-access-to-actor: true" not in step:
        return "an action-tmate step does not limit access to the actor"
    if "timeout-minutes:" not in step:
        return "an action-tmate step has no timeout-minutes"
    if "github.event_name == 'workflow_dispatch'" not in step:
        return "an action-tmate step can run outside a workflow_dispatch"
    return ""


def check_ci(text: str, manifest: object) -> list[str]:
    """Return what is wrong with ci.yml."""
    code = _code(text)
    problems: list[str] = [
        f"ci.yml names tmux {version}; the manifest owns that list"
        for version in (*manifest.released, *manifest.refused)
        if re.search(rf"(?<![\w.]){re.escape(version)}(?![\w.])", code)
    ]
    problems += [
        f"ci.yml pins tmux commit {commit}; the manifest owns that pin"
        for commit in manifest.preview.values()
        if commit in code
    ]
    problems += [
        f"ci.yml:{number} splices an input into a script; use env:"
        for number, body in _run_bodies(text)
        if SPLICED.search(body)
    ]
    if not re.search(r'(?m)^    tags: \["\*"\]$', text):
        problems.append("ci.yml does not run on a tag, so a release is not tested")

    # GitHub reads a bare `off` as false, in the options and in the default. A
    # default that is not one of the options refuses every dispatch that sets
    # nothing, and a bare pair reaches the plan as `false`.
    if (
        "options: ['off', before-tests, on-failure]" not in text
        or "default: 'off'" not in text
    ):
        problems.append(
            "the tmate input must quote 'off': GitHub reads a bare off as false"
        )

    jobs = _jobs(text)
    for name in ("test", "refusal"):
        wanted = f"matrix: ${{{{ fromJSON(needs.plan.outputs.{name}) }}}}"
        if wanted not in jobs.get(name, ""):
            problems.append(f"the {name} job does not take its matrix from the plan")

    aggregate = jobs.get("required", "")
    listed = set(re.findall(r"(?m)^      - ([\w-]+)$", aggregate.split("steps:")[0]))
    wanted_jobs = set(jobs) - {"required"}
    problems += [
        f"required does not need {job}" for job in sorted(wanted_jobs - listed)
    ]
    problems += [
        f"required needs {job}, which is not a job"
        for job in sorted(listed - wanted_jobs)
    ]

    group = re.search(r"(?m)^  group: (.*)$", text.split("concurrency:", 1)[-1])
    if (
        not group
        or "github.run_id" not in group[1]
        or "workflow_dispatch" not in group[1]
    ):
        problems.append("the concurrency group does not separate dispatch runs")

    tmate = [step for step in _steps(jobs.get("test", "")) if TMATE.search(step)]
    if len(tmate) != 2:
        problems.append(
            "the test job needs a before-tests and an on-failure tmate step"
        )
    problems += [_check_tmate_step(step) for step in tmate]
    if len(TMATE.findall(code)) != len(tmate):
        problems.append("action-tmate appears outside the test job")
    return [problem for problem in problems if problem]


def check(root: pathlib.Path) -> list[str]:
    """Return every disagreement between the manifest, the docs and the workflows."""
    plan = _load_plan()
    manifest = plan.load_manifest(root / "Scripts/tmux-matrix.json")
    problems = check_docs(root, manifest)
    workflows = root / WORKFLOWS
    problems += check_ci((workflows / "ci.yml").read_text(), manifest)
    problems += [
        f"{path.name} runs action-tmate; only ci.yml may"
        for path in sorted(workflows.glob("*.yml"))
        if path.name != "ci.yml" and TMATE.search(path.read_text())
    ]
    scripts = [
        *sorted(workflows.glob("*.y*ml")),
        *sorted((root / ACTIONS).glob("*/action.y*ml")),
    ]
    for path in scripts:
        problems += check_apt(path.read_text(), str(path.relative_to(root)))
    return problems


def main(argv: list[str] | None = None) -> int:
    """Print every disagreement and exit nonzero if there is one."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=ROOT)
    args = parser.parse_args(argv)
    plan = _load_plan()
    try:
        problems = check(args.root.resolve())
    except (plan.PlanError, OSError, ValueError) as error:
        problems = [f"cannot check: {error}"]
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
