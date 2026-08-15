"""Executable observations for inherited Swift parity behavior rows."""

from __future__ import annotations

import copy
import json
import pathlib
import typing as t

import pytest
from libtmux import exc
from libtmux._internal.query_list import QueryList
from libtmux.session import Session
from libtmux.window import Window
from python_parity_behavior_probes import (
    INHERITED_FAMILIES,
    OBSERVABLE_FIELDS,
    ProbeContext,
    observe_inherited_behavior,
)

if t.TYPE_CHECKING:
    from libtmux._internal.control_mode import ControlMode
    from libtmux.server import Server

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CONTRACT_PATH = REPO_ROOT / "Parity" / "python-behavior-contracts.json"


def _inherited_contracts() -> dict[str, dict[str, t.Any]]:
    """Load inherited behavior rows keyed by family ID.

    Returns
    -------
    dict[str, dict[str, typing.Any]]
        Curated inherited rows indexed by their behavior family.

    Examples
    --------
    >>> contracts = _inherited_contracts()
    >>> len(contracts)
    38
    >>> all(row["inheritance"] == "inherited" for row in contracts.values())
    True
    """
    document = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    return {
        row["behaviorFamilyId"]: row
        for row in document["entries"]
        if row["inheritance"] == "inherited"
    }


def _assert_matches_contract(
    observed: dict[str, object],
    expected: dict[str, object],
) -> None:
    """Require every structured observation to equal its contract field.

    Parameters
    ----------
    observed : dict[str, object]
        Values derived by executing Python behavior.
    expected : dict[str, object]
        Curated contract values under validation.

    Raises
    ------
    AssertionError
        When any contract field differs from the observation.

    Examples
    --------
    >>> _assert_matches_contract({"shape": {"count": 0}}, {"shape": {"count": 0}})
    >>> try:
    ...     _assert_matches_contract(
    ...         {"shape": {"count": 0}}, {"shape": {"count": 1}}
    ...     )
    ... except AssertionError:
    ...     mismatch_rejected = True
    >>> mismatch_rejected
    True
    """
    assert observed == expected


@pytest.mark.parametrize("family", sorted(INHERITED_FAMILIES))
def test_inherited_behavior_contract_matches_observation(
    family: str,
    server: Server,
    session: Session,
    control_mode: t.Callable[[], ControlMode],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: pathlib.Path,
) -> None:
    """Each inherited row equals values derived from executed Python behavior.

    Parameters
    ----------
    family : str
        Inherited behavior family selected by pytest.
    server : Server
        Isolated live tmux server.
    session : Session
        Live session on ``server``.
    control_mode : Callable[[], ControlMode]
        Factory for a control-mode client.
    monkeypatch : pytest.MonkeyPatch
        Scoped replacement helper for deterministic failure branches.
    tmp_path : pathlib.Path
        Temporary directory for executable version and byte fixtures.

    Examples
    --------
    Falsifying an observed field is rejected independently:

    >>> observed = {"shape": {"pythonType": "builtins.list", "count": 0}}
    >>> try:
    ...     _assert_matches_contract(
    ...         observed, {"shape": {"pythonType": "builtins.list", "count": 1}}
    ...     )
    ... except AssertionError:
    ...     mismatch_rejected = True
    >>> mismatch_rejected
    True
    """
    contracts = _inherited_contracts()
    assert set(INHERITED_FAMILIES) == set(contracts)
    context = ProbeContext(
        server=server,
        session=session,
        control_mode=control_mode,
        monkeypatch=monkeypatch,
        tmp_path=tmp_path,
    )

    observed = observe_inherited_behavior(family, context)
    expected = {field: contracts[family][field] for field in OBSERVABLE_FIELDS}

    assert all(not isinstance(observed[field], str) for field in OBSERVABLE_FIELDS)
    _assert_matches_contract(observed, expected)

    if family == "list.session.active-window.cardinality":
        no_active = observed["exitStderrPolicy"]["noActive"]
        multiple = observed["exitStderrPolicy"]["multipleActive"]
        assert (
            no_active["exception"]
            == f"{exc.NoActiveWindow.__module__}.{exc.NoActiveWindow.__qualname__}"
        )
        assert multiple["exception"] == (
            f"{exc.MultipleActiveWindows.__module__}."
            f"{exc.MultipleActiveWindows.__qualname__}"
        )
    elif family == "transport.cmd.invalid-bytes":
        result = observed["expectedResultShape"]
        assert result["stdout"] == ["\\xffout"]
        assert result["stderr"] == ["\\xfeerr"]
        assert result["returncode"] == 7
    elif family == "versions.feature-gates":
        lanes = observed["versionLanes"]
        assert {lane["rawVersion"] for lane in lanes} == {
            "3.2a",
            "3.3",
            "3.7",
            "3.7a",
        }
        by_raw = {lane["rawVersion"]: lane for lane in lanes}
        assert by_raw["3.7"]["numericVersion"] == by_raw["3.7a"]["numericVersion"]
        assert by_raw["3.7"]["rawVersion"] != by_raw["3.7a"]["rawVersion"]

    for field in OBSERVABLE_FIELDS:
        falsified = copy.deepcopy(expected)
        field_value = falsified[field]
        assert isinstance(field_value, (dict, list))
        if isinstance(field_value, dict):
            falsified[field] = {**field_value, "contractFalsified": True}
        else:
            falsified[field] = [*field_value, {"contractFalsified": True}]
        with pytest.raises(AssertionError):
            _assert_matches_contract(observed, falsified)


@pytest.mark.parametrize(
    ("family", "accessor_owner", "accessor_name"),
    [
        (
            "list.predicate.session.malformed-empty",
            Session,
            "search_windows",
        ),
        (
            "list.predicate.window.malformed-empty",
            Window,
            "search_panes",
        ),
    ],
    ids=("session", "window"),
)
def test_malformed_predicate_leniency_changes_with_accessor_outcome(
    family: str,
    accessor_owner: type[Session | Window],
    accessor_name: str,
    server: Server,
    session: Session,
    control_mode: t.Callable[[], ControlMode],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: pathlib.Path,
) -> None:
    """Malformed-predicate leniency reflects a falsified accessor result.

    Parameters
    ----------
    family : str
        Malformed-predicate family selected by pytest.
    accessor_owner : type[Session | Window]
        Public owner whose search accessor is falsified.
    accessor_name : str
        Search accessor to replace with an empty collection return.
    server : Server
        Isolated live tmux server.
    session : Session
        Live session on ``server``.
    control_mode : Callable[[], ControlMode]
        Factory for a control-mode client.
    monkeypatch : pytest.MonkeyPatch
        Scoped replacement helper for the accessor falsification.
    tmp_path : pathlib.Path
        Temporary directory required by the shared probe context.

    Examples
    --------
    The emitted field must change when the captured outcome changes:

    >>> baseline, falsified = False, True
    >>> baseline != falsified
    True
    """
    context = ProbeContext(
        server=server,
        session=session,
        control_mode=control_mode,
        monkeypatch=monkeypatch,
        tmp_path=tmp_path,
    )
    baseline = observe_inherited_behavior(family, context)

    with monkeypatch.context() as patch:
        patch.setattr(
            accessor_owner,
            accessor_name,
            lambda *_args, **_kwargs: QueryList(),
        )
        falsified = observe_inherited_behavior(family, context)

    assert (
        baseline["listLeniency"]["daemonUnavailableReturnsEmpty"],
        falsified["listLeniency"]["daemonUnavailableReturnsEmpty"],
    ) == (False, True)
