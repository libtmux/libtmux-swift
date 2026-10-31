"""Tests for the CI plan.

Each rule is checked twice: once against the real plan, and once against a plan
with that rule removed, which must fail. A check that passes either way proves
nothing about the rule it is named for.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Any

import pytest

if TYPE_CHECKING:
    from collections.abc import Callable


def load(name: str, filename: str) -> Any:
    """Import a script from `Scripts/` under `name`."""
    path = Path(__file__).parents[1] / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


PLAN = load("ci_plan", "ci_plan.py")

REAL_LEG = PLAN._leg
PIN = "b" * 40
SHA = "a" * 40
FIXTURE = PLAN.parse_manifest(
    {
        "released": ["1.0", "1.1", "1.1a", "2.0", "2.1"],
        "preview": [{"name": "main", "commit": PIN}],
        "refused": ["0.9", "0.9a"],
        "clients": {"legacy": "1.0", "legacy_through": "1.1a", "current": "2.0"},
        "swift": "6.2",
        "version_checks": "1.1a",
    }
)


def make(**kwargs: str) -> Any:
    """Plan an event against the fixture."""
    kwargs.setdefault("event", "push")
    return PLAN.make_plan(FIXTURE, **kwargs)


def tmux_of(result: Any) -> list[str]:
    """Return the tmux names of the test legs."""
    return [leg["tmux"] for leg in result.test]


def leg(result: Any, tmux: str) -> dict[str, Any]:
    """Return the first test leg for `tmux`."""
    return next(item for item in result.test if item["tmux"] == tmux)


def check_push_runs_edges() -> None:
    """Check that a push runs the oldest and newest release and nothing else."""
    result = make(event="push", ref_type="branch")
    assert tmux_of(result) == ["1.0", "2.1"]
    assert not result.refusal_planned
    assert result.tmux_jobs == 2


def check_pull_request_runs_edges() -> None:
    """Check that a pull request runs the same edges as a push."""
    result = make(event="pull_request")
    assert tmux_of(result) == ["1.0", "2.1"]
    assert not result.refusal_planned


def check_tag_runs_everything() -> None:
    """Check that a tag push proves the table, the preview and the refusals."""
    result = make(event="push", ref_type="tag")
    assert tmux_of(result) == ["1.0", "1.1", "1.1a", "2.0", "2.1", "main"]
    assert result.refusal_planned
    assert result.tmux_jobs == 6 + 2


def check_schedule_runs_everything() -> None:
    """Check that a schedule keeps full scope."""
    result = make(event="schedule")
    assert result.scope == "full"
    assert result.refusal_planned


def check_dispatch_defaults_to_edges() -> None:
    """Check that a dispatch that asks for edges runs only the edges."""
    result = make(event="workflow_dispatch", scope="edges")
    assert tmux_of(result) == ["1.0", "2.1"]
    assert not result.refusal_planned


def check_dispatch_full() -> None:
    """Check that scope full runs everything, preview and refusals."""
    result = make(event="workflow_dispatch", scope="full")
    assert tmux_of(result) == ["1.0", "1.1", "1.1a", "2.0", "2.1", "main"]
    assert result.refusal_planned


def check_dispatch_custom() -> None:
    """Check that custom runs the refs it names, in order, once each."""
    result = make(
        event="workflow_dispatch",
        scope="custom",
        tmux_ref=f" 1.1a, main,{SHA},1.1a,feature/x ",
    )
    assert tmux_of(result) == ["1.1a", "main", SHA, "feature/x"]
    assert leg(result, SHA)["slug"] == "a" * 12
    assert leg(result, "feature/x")["slug"] == "feature-x"
    assert not result.refusal_planned


def check_full_pins_the_preview() -> None:
    """Check that the whole table tests the pinned commit, not the tip."""
    main = leg(make(event="push", ref_type="tag"), "main")
    assert (main["ref"], main["source"]) == (PIN, "git")


def check_custom_preview_is_the_tip() -> None:
    """Check that naming the preview in a custom run asks for its tip."""
    result = make(event="workflow_dispatch", scope="custom", tmux_ref="main")
    assert (leg(result, "main")["ref"], leg(result, "main")["source"]) == (
        "main",
        "git",
    )


def check_releases_keep_their_tarball() -> None:
    """Check that a release in the manifest is built from its tarball."""
    result = make(event="workflow_dispatch", scope="custom", tmux_ref="1.1,9.9")
    assert leg(result, "1.1")["source"] == "release"
    assert leg(result, "9.9")["source"] == "git"


def check_edges_are_first_and_last_release() -> None:
    """Check that the edges are the ends of the released list."""
    result = make(event="push")
    assert result.test[0]["tmux"] == FIXTURE.released[0]
    assert result.test[-1]["tmux"] == FIXTURE.released[-1]
    assert "main" not in tmux_of(result)


def check_repo_checks_run_on_the_newest_edge() -> None:
    """Check that the repository-wide steps land on exactly one leg."""
    for scope in ("edges", "full"):
        result = make(event="workflow_dispatch", scope=scope)
        flagged = [item["tmux"] for item in result.test if item["repo_checks"]]
        assert flagged == ["2.1"]
    custom = make(
        event="workflow_dispatch", scope="custom", tmux_ref="2.1", swift="6.1,6.2"
    )
    flagged = [item["swift"] for item in custom.test if item["repo_checks"]]
    assert flagged == ["6.2"]


def check_version_checks_need_their_release() -> None:
    """Check that the tmux-dependent steps exist only where their release runs."""
    assert not any(item["version_checks"] for item in make(event="push").test)
    full = make(event="workflow_dispatch", scope="full")
    assert [item["tmux"] for item in full.test if item["version_checks"]] == ["1.1a"]


def check_client_rule() -> None:
    """Check that the client is the legacy tmux up to the cutoff, current above."""
    full = make(event="workflow_dispatch", scope="full")
    assert (leg(full, "1.0")["client"], leg(full, "1.0")["client_slug"]) == ("", "1.0")
    assert (leg(full, "1.1")["client"], leg(full, "1.1")["client_slug"]) == (
        "1.0",
        "1.0",
    )
    assert leg(full, "1.1a")["client"] == "1.0"
    assert (leg(full, "2.0")["client"], leg(full, "2.0")["client_slug"]) == ("", "2.0")
    assert leg(full, "2.1")["client"] == "2.0"
    assert leg(full, "main")["client"] == "2.0"
    custom = make(event="workflow_dispatch", scope="custom", tmux_ref=f"{SHA},1.1b")
    assert leg(custom, SHA)["client"] == "2.0"
    assert leg(custom, "1.1b")["client"] == "2.0"


def check_tmate_takes_the_one_leg() -> None:
    """Check that a tmate session lands on the single leg of a custom dispatch."""
    result = make(
        event="workflow_dispatch", scope="custom", tmux_ref="1.1", tmate="on-failure"
    )
    assert [item["tmate"] for item in result.test] == ["on-failure"]


def check_tmate_refuses_many_legs() -> None:
    """Check that edges are two legs, so tmate on them is an error."""
    with pytest.raises(PLAN.PlanError, match="exactly one"):
        make(event="workflow_dispatch", scope="edges", tmate="before-tests")


def check_tmate_needs_a_dispatch() -> None:
    """Check that only a workflow_dispatch may open a session."""
    with pytest.raises(PLAN.PlanError, match="workflow_dispatch"):
        make(event="push", scope="custom", tmux_ref="1.1", tmate="on-failure")


def check_bad_ref_is_refused() -> None:
    """Check that a ref outside the allowed characters never reaches a step."""
    for bad in ("1.0;rm", "$(id)", "a b", "x" * 65, "-oops", "a,b|c"):
        with pytest.raises(PLAN.PlanError):
            make(event="workflow_dispatch", scope="custom", tmux_ref=bad)


def check_too_many_legs_is_refused() -> None:
    """Check that a dispatch cannot fan out past the limit."""
    refs = ",".join(f"9.{n}" for n in range(40))
    with pytest.raises(PLAN.PlanError, match="limit"):
        make(event="workflow_dispatch", scope="custom", tmux_ref=refs)


def check_matrix_is_never_empty() -> None:
    """Check that every scope plans a leg and describes the refusal cells."""
    for event, scope, ref_type in (
        ("push", "", "branch"),
        ("push", "", "tag"),
        ("pull_request", "", ""),
        ("schedule", "", ""),
        ("workflow_dispatch", "edges", ""),
        ("workflow_dispatch", "full", ""),
    ):
        result = make(event=event, scope=scope, ref_type=ref_type)
        assert result.test
        assert result.refusal


def check_aggregate_accepts_success() -> None:
    """Check that an all-success run passes with the refusals skipped."""
    ok = {"plan": {"result": "success"}, "test": {"result": "success"}}
    assert PLAN.verify_needs(ok, refusal_planned=False) == []
    skipped = {**ok, "refusal": {"result": "skipped"}}
    assert PLAN.verify_needs(skipped, refusal_planned=False) == []
    ran = {**ok, "refusal": {"result": "success"}}
    assert PLAN.verify_needs(ran, refusal_planned=True) == []


def check_aggregate_refuses_anything_else() -> None:
    """Check that a failed, cancelled or skipped job fails the aggregate."""
    for result in ("failure", "cancelled", "skipped"):
        needs = {"test": {"result": result}}
        assert PLAN.verify_needs(needs, refusal_planned=False)
    planned = {"test": {"result": "success"}, "refusal": {"result": "skipped"}}
    assert PLAN.verify_needs(planned, refusal_planned=True)
    unplanned = {"test": {"result": "success"}, "refusal": {"result": "success"}}
    assert PLAN.verify_needs(unplanned, refusal_planned=False)


def always(value: object) -> Callable[..., object]:
    """Return a stand-in rule that ignores its arguments."""
    return lambda *_args, **_kwargs: value


def newest_is_second_release(manifest: Any, scope: str, refs: list[str]) -> list[Any]:
    """Stand in for an edge rule that takes the wrong release as the newest."""
    names = [manifest.oldest, manifest.released[1]]
    if scope == "full":
        names = [*manifest.released, *manifest.preview]
    if scope == "custom" and refs:
        names = refs
    return [PLAN.named_ref(manifest, name, pinned=True) for name in names]


def unpinned_refs(manifest: Any, scope: str, refs: list[str]) -> list[Any]:
    """Stand in for a full scope that tests the preview tip instead of its pin."""
    names = [manifest.oldest, manifest.newest]
    if scope == "full":
        names = [*manifest.released, *manifest.preview]
    if scope == "custom" and refs:
        names = refs
    return [PLAN.named_ref(manifest, name, pinned=False) for name in names]


def pinned_refs(manifest: Any, scope: str, refs: list[str]) -> list[Any]:
    """Stand in for a custom scope that pins the preview instead of the tip."""
    names = [manifest.oldest, manifest.newest]
    if scope == "full":
        names = [*manifest.released, *manifest.preview]
    if scope == "custom" and refs:
        names = refs
    return [PLAN.named_ref(manifest, name, pinned=True) for name in names]


def every_ref_is_git(manifest: Any, name: str, *, pinned: bool) -> Any:
    """Stand in for a plan that builds every release from a clone."""
    return PLAN.Ref(name, name, "git")


def edges_instead(manifest: Any, scope: str, refs: list[str]) -> list[Any]:
    """Stand in for a plan that ignores the scope and always runs the edges."""
    names = [manifest.oldest, manifest.newest]
    return [PLAN.named_ref(manifest, name, pinned=True) for name in names]


def oldest_flagged(build: Any, swift: str, manifest: Any) -> dict[str, Any]:
    """Stand in for a plan that flags the oldest release for the repo checks."""
    item = REAL_LEG(build, swift, manifest)
    item["repo_checks"] = build.name == manifest.oldest
    return item


def the_current_client(manifest: Any, name: str) -> str:
    """Stand in for a client rule that never uses the legacy client."""
    return manifest.clients["current"]


def the_legacy_client(manifest: Any, name: str) -> str:
    """Stand in for a client rule that never uses the current client."""
    return manifest.clients["legacy"]


# Each entry pairs a check with a rule removed from the plan. The check must
# pass on the real plan and fail on the broken one.
MUTANTS: dict[Callable[[], None], tuple[str, object]] = {
    check_push_runs_edges: ("scope_for", always("full")),
    check_pull_request_runs_edges: ("scope_for", always("full")),
    check_tag_runs_everything: ("scope_for", always("edges")),
    check_schedule_runs_everything: ("scope_for", always("edges")),
    check_dispatch_defaults_to_edges: ("scope_for", always("full")),
    check_dispatch_full: ("chosen_refs", edges_instead),
    check_dispatch_custom: ("chosen_refs", edges_instead),
    check_full_pins_the_preview: ("chosen_refs", unpinned_refs),
    check_custom_preview_is_the_tip: ("chosen_refs", pinned_refs),
    check_releases_keep_their_tarball: ("named_ref", every_ref_is_git),
    check_edges_are_first_and_last_release: (
        "chosen_refs",
        newest_is_second_release,
    ),
    check_repo_checks_run_on_the_newest_edge: ("_leg", oldest_flagged),
    check_version_checks_need_their_release: (
        "chosen_refs",
        lambda m, s, r: [PLAN.named_ref(m, n, pinned=True) for n in m.released],
    ),
    check_client_rule: ("client_for", the_current_client),
    check_tmate_takes_the_one_leg: ("assign_tmate", always(None)),
    check_tmate_refuses_many_legs: ("assign_tmate", always(None)),
    check_tmate_needs_a_dispatch: ("assign_tmate", always(None)),
    check_bad_ref_is_refused: ("_refs", lambda text, m: PLAN._split(text)),
    check_too_many_legs_is_refused: ("MAX_LEGS", 10_000),
    check_matrix_is_never_empty: ("chosen_refs", always([])),
    check_aggregate_accepts_success: ("expected_result", always("success")),
    check_aggregate_refuses_anything_else: ("expected_result", always("skipped")),
}

CHECKS = [
    value
    for name, value in sorted(globals().items())
    if name.startswith("check_") and callable(value)
]


@pytest.mark.parametrize("check", CHECKS, ids=lambda check: check.__name__)
def test_the_rule_holds(check: Callable[[], None]) -> None:
    """Every rule holds on the real plan."""
    check()


def test_every_check_has_a_mutant() -> None:
    """No rule is left without a negative test."""
    assert set(CHECKS) == set(MUTANTS)


@pytest.mark.parametrize(
    ("check", "removed"),
    list(MUTANTS.items()),
    ids=[check.__name__ for check in MUTANTS],
)
def test_removing_the_rule_fails_its_check(
    check: Callable[[], None],
    removed: tuple[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A check that survives its rule's removal is not testing it."""
    name, broken = removed
    monkeypatch.setattr(PLAN, name, broken)
    with pytest.raises((AssertionError, PLAN.PlanError, pytest.fail.Exception)):
        check()


def test_the_edge_rule_fails_without_the_first_release(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Taking the second release for the floor breaks the edge check."""
    monkeypatch.setattr(
        PLAN.Manifest, "oldest", property(lambda self: self.released[1])
    )
    with pytest.raises(AssertionError):
        check_push_runs_edges()


def test_the_legacy_client_rule_fails_when_unused(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A client rule that always picks the legacy tmux breaks the check."""
    monkeypatch.setattr(PLAN, "client_for", the_legacy_client)
    with pytest.raises(AssertionError):
        check_client_rule()


@pytest.mark.parametrize(
    "arguments",
    [
        {"event": "workflow_dispatch", "scope": "everything"},
        {"event": "workflow_dispatch", "scope": "edges", "tmux_ref": "1.1"},
        {"event": "workflow_dispatch", "scope": "custom"},
        {"event": "workflow_dispatch", "scope": "custom", "tmux_ref": "0.9"},
        {"event": "workflow_dispatch", "scope": "custom", "swift": "six"},
        {"event": "workflow_dispatch", "scope": "custom", "swift": "6.2;id"},
        {"event": "workflow_dispatch", "scope": "full", "tmate": "always"},
    ],
    ids=[
        "unknown-scope",
        "tmux-ref-without-custom",
        "empty-custom",
        "refusal-cell-as-leg",
        "word-as-swift",
        "swift-injection",
        "unknown-tmate-mode",
    ],
)
def test_a_dispatch_that_asks_for_the_wrong_thing_is_refused(
    arguments: dict[str, str],
) -> None:
    """These are mistakes, and they fail before a runner is spent."""
    with pytest.raises(PLAN.PlanError):
        make(**arguments)


def test_custom_swift_alone_uses_the_edges() -> None:
    """A toolchain without refs runs the edges under each toolchain."""
    result = make(event="workflow_dispatch", scope="custom", swift="6.1,6.2")
    assert [(item["tmux"], item["swift"]) for item in result.test] == [
        ("1.0", "6.1"),
        ("1.0", "6.2"),
        ("2.1", "6.1"),
        ("2.1", "6.2"),
    ]


def test_outputs_are_single_line_json() -> None:
    """GITHUB_OUTPUT takes one line per value."""
    outputs = make(event="push", ref_type="tag").outputs()
    for value in outputs.values():
        assert "\n" not in value
    assert json.loads(outputs["test"])["include"][0]["tmux"] == "1.0"
    assert outputs["refusal_planned"] == "true"
    assert outputs["tmux_jobs"] == "8"
    assert json.loads(outputs["refusal"])["include"][0] == {
        "tmux": "0.9",
        "client": "1.0",
        "swift": "6.2",
    }


def test_the_refusal_matrix_is_described_even_when_skipped() -> None:
    """The matrix is never empty, so no evaluator sees `[]`."""
    outputs = make(event="push").outputs()
    assert outputs["refusal_planned"] == "false"
    assert len(json.loads(outputs["refusal"])["include"]) == 2
    assert outputs["tmux_jobs"] == "2"


BASE: dict[str, Any] = {
    "released": ["1.0", "2.0"],
    "preview": [{"name": "main", "commit": PIN}],
    "refused": ["0.9"],
    "clients": {"legacy": "1.0", "legacy_through": "1.0", "current": "2.0"},
    "swift": "6.2",
    "version_checks": "2.0",
}


def parse(**changes: object) -> Any:
    """Parse the base manifest with some keys replaced."""
    return PLAN.parse_manifest({**BASE, **changes})


def test_the_shipped_manifest_loads() -> None:
    """The real manifest is valid."""
    manifest = PLAN.load_manifest()
    assert manifest.oldest == manifest.released[0]
    assert manifest.newest == manifest.released[-1]


@pytest.mark.parametrize(
    "changes",
    [
        {"released": ["2.0", "1.0"]},
        {"released": ["1.0", "1.0"]},
        {"released": ["1.0a", "1.0"]},
        {"released": []},
        {"refused": []},
        {"refused": ["1.0"]},
        {"refused": ["1.5"]},
        {"preview": [{"name": "2.0", "commit": PIN}]},
        {"preview": [{"name": "main", "commit": "main"}]},
        {"preview": [{"name": "main"}]},
        {"clients": {"legacy": "1.0", "current": "2.0"}},
        {"clients": {"legacy": "0.5", "legacy_through": "1.0", "current": "2.0"}},
        {"swift": "latest"},
        {"version_checks": "9.9"},
    ],
    ids=lambda changes: (
        next(iter(changes)) + ":" + json.dumps(next(iter(changes.values())))[:30]
    ),
)
def test_the_manifest_refuses_what_makes_the_edges_wrong(
    changes: dict[str, object],
) -> None:
    """Each of these would make an edge, a floor or a pin mean something else."""
    with pytest.raises(PLAN.PlanError):
        parse(**changes)


def test_suffix_letters_order_after_the_release() -> None:
    """3.7 < 3.7a < 3.7b, as the library orders them."""
    parse(
        released=["1.0", "1.0a", "1.0b", "1.1"],
        clients={"legacy": "1.0", "legacy_through": "1.0a", "current": "1.1"},
        version_checks="1.1",
    )


@pytest.mark.parametrize("key", ["released", "preview", "refused", "clients", "swift"])
def test_missing_keys_are_refused(key: str) -> None:
    """Every key is required."""
    raw = {k: v for k, v in BASE.items() if k != key}
    with pytest.raises(PLAN.PlanError):
        PLAN.parse_manifest(raw)


def test_matrix_writes_github_output(tmp_path: Path) -> None:
    """Each output lands as `name=value`."""
    output = tmp_path / "out"
    status = PLAN.main(["matrix", "--event", "push", "--github-output", str(output)])
    lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
    assert status == 0
    assert lines["scope"] == "edges"
    assert lines["refusal_planned"] == "false"
    assert len(json.loads(lines["test"])["include"]) == 2


def test_a_refused_plan_exits_nonzero() -> None:
    """Exit nonzero when tmate has two legs to attach to."""
    arguments = ["matrix", "--event", "workflow_dispatch", "--scope", "edges"]
    assert PLAN.main([*arguments, "--tmate", "on-failure"]) == 1


def test_verify_reports_a_failed_job() -> None:
    """The aggregate step exits nonzero on any non-success."""
    good = json.dumps({"test": {"result": "success"}})
    bad = json.dumps({"test": {"result": "failure"}})
    assert PLAN.main(["verify", "--needs", good]) == 0
    assert PLAN.main(["verify", "--needs", bad]) == 1
