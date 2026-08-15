"""Runtime-derived outcomes for inherited Python behavior contracts."""

from __future__ import annotations

import dataclasses
import functools
import pathlib
import stat
import subprocess  # noqa: F401  # executable doctest namespace
import sys
import tempfile  # noqa: F401  # temporary-directory doctest namespace
import typing as t

import libtmux
import libtmux.neo
import libtmux.server
import libtmux.session
import libtmux.window
import pytest
from libtmux import exc
from libtmux._internal.query_list import QueryList
from libtmux._internal.sparse_array import SparseArray
from libtmux.client import Client
from libtmux.common import (
    get_version,
    get_version_str,
    has_gte_version,
    has_version,
    raise_if_stderr,
    tmux_cmd,
)
from libtmux.formats import FORMAT_SEPARATOR
from libtmux.neo import get_output_format, parse_output
from libtmux.options import convert_values
from libtmux.pane import Pane
from libtmux.server import Server
from libtmux.session import Session
from libtmux.window import Window

if t.TYPE_CHECKING:
    from collections.abc import Callable

    from libtmux._internal.control_mode import ControlMode

JsonValue = t.Any
Observation = dict[str, JsonValue]

OBSERVABLE_FIELDS = (
    "expectedResultShape",
    "exitStderrPolicy",
    "listLeniency",
    "versionLanes",
)

NOT_APPLICABLE: dict[str, JsonValue] = {"status": "NOT_APPLICABLE"}
NEEDS_CONTEXT: dict[str, JsonValue] = {"status": "NEEDS_CONTEXT"}

INHERITED_FAMILIES = frozenset(
    {
        "format.projection",
        "lifecycle.cleanup",
        "list.liveness.is-alive",
        "list.liveness.require-alive",
        "list.predicate.server.malformed-empty",
        "list.predicate.session.malformed-empty",
        "list.predicate.window.malformed-empty",
        "list.server.clients.any-error-empty",
        "list.server.panes.daemon-unavailable-empty",
        "list.server.search-panes.daemon-unavailable-empty",
        "list.server.search-sessions.daemon-unavailable-empty",
        "list.server.search-windows.daemon-unavailable-empty",
        "list.server.sessions.any-error-empty",
        "list.server.windows.daemon-unavailable-empty",
        "list.session.active-pane.optional",
        "list.session.active-window.cardinality",
        "list.session.panes.propagate",
        "list.session.search-panes.propagate",
        "list.session.search-windows.propagate",
        "list.session.windows.propagate",
        "list.window.linked-sessions.either-source-empty-deduplicated",
        "list.window.panes.propagate",
        "list.window.search-panes.propagate",
        "public.surface",
        "refresh.client",
        "refresh.pane",
        "refresh.session",
        "refresh.stale-object",
        "refresh.window",
        "state.environments",
        "state.hooks",
        "state.options",
        "state.sparse-arrays",
        "transport.cmd.invalid-bytes",
        "transport.cmd.nonzero",
        "transport.cmd.result",
        "transport.has-session",
        "versions.feature-gates",
    }
)


@dataclasses.dataclass(frozen=True)
class ProbeContext:
    """Live fixtures available to every parity behavior observation.

    Attributes
    ----------
    server : Server
        Isolated live tmux server.
    session : Session
        Live session on ``server``.
    control_mode : Callable[[], ControlMode]
        Factory for an attached control-mode client.
    monkeypatch : pytest.MonkeyPatch
        Scoped replacement helper for deterministic error branches.
    tmp_path : pathlib.Path
        Temporary directory for executable byte and version fixtures.
    """

    server: Server
    session: Session
    control_mode: Callable[[], ControlMode]
    monkeypatch: pytest.MonkeyPatch
    tmp_path: pathlib.Path


def _qualified_type(value: object) -> str:
    """Return the stable qualified Python type of a runtime value.

    Parameters
    ----------
    value : object
        Runtime value whose type is being observed.

    Returns
    -------
    str
        Module-qualified type name.

    Examples
    --------
    >>> _qualified_type(QueryList())
    'libtmux._internal.query_list.QueryList'
    >>> _qualified_type(None)
    'builtins.NoneType'
    """
    cls = type(value)
    return f"{cls.__module__}.{cls.__qualname__}"


def _describe(value: object) -> dict[str, JsonValue]:
    """Describe a runtime return value without caller-authored prose.

    Parameters
    ----------
    value : object
        Runtime value returned by the operation under observation.

    Returns
    -------
    dict[str, JsonValue]
        JSON-safe type, size, and scalar-value evidence.

    Examples
    --------
    >>> described = _describe(QueryList(["one", "two"]))
    >>> described["count"], described["itemTypes"], described["values"]
    (2, ['builtins.str'], ['one', 'two'])
    >>> _describe(None)
    {'pythonType': 'builtins.NoneType', 'value': None}
    """
    result: dict[str, JsonValue] = {"pythonType": _qualified_type(value)}
    if value is None or isinstance(value, (bool, int, float, str)):
        result["value"] = value
        return result
    if isinstance(value, dict):
        result["count"] = len(value)
        result["keys"] = [str(key) for key in value]
        result["valueTypes"] = sorted(
            {_qualified_type(item) for item in value.values()}
        )
        return result
    if isinstance(value, (list, tuple, set, frozenset)):
        items = list(value)
        result["count"] = len(items)
        result["itemTypes"] = sorted({_qualified_type(item) for item in items})
        if len(items) <= 12 and all(
            item is None or isinstance(item, (bool, int, float, str)) for item in items
        ):
            result["values"] = [
                t.cast("bool | int | float | str | None", item) for item in items
            ]
        return result
    return result


def _collection_shape(value: object) -> dict[str, JsonValue]:
    """Describe collection element types without fixture-dependent counts.

    Parameters
    ----------
    value : object
        Runtime collection returned by the public accessor.

    Returns
    -------
    dict[str, JsonValue]
        Qualified collection type plus observed key, value, or item types.

    Examples
    --------
    >>> rows = QueryList([Session(server=Server(), session_id="$1")])
    >>> _collection_shape(rows)["itemTypes"]
    ['libtmux.session.Session']
    >>> mapping = _collection_shape({"one": 1})
    >>> mapping["keyTypes"], mapping["valueTypes"]
    (['builtins.str'], ['builtins.int'])
    """
    result: dict[str, JsonValue] = {"pythonType": _qualified_type(value)}
    if isinstance(value, dict):
        result["keyTypes"] = sorted({_qualified_type(key) for key in value})
        result["valueTypes"] = sorted(
            {_qualified_type(item) for item in value.values()}
        )
        return result
    if isinstance(value, (list, tuple, set, frozenset)):
        result["itemTypes"] = sorted({_qualified_type(item) for item in value})
        return result
    return result


def _capture(operation: Callable[[], object]) -> dict[str, JsonValue]:
    """Execute an operation and describe its return or raised exception.

    Parameters
    ----------
    operation : Callable[[], object]
        Zero-argument behavior to execute.

    Returns
    -------
    dict[str, JsonValue]
        Structured return or exception evidence.

    Examples
    --------
    >>> returned = _capture(lambda: QueryList())
    >>> returned["outcome"], returned["count"], returned["values"]
    ('return', 0, [])
    >>> _capture(lambda: (_ for _ in ()).throw(ValueError("bad")))
    {'outcome': 'raise', 'exception': 'builtins.ValueError'}
    """
    try:
        value = operation()
    except Exception as error:  # noqa: BLE001  # type is the observation
        result: dict[str, JsonValue] = {
            "outcome": "raise",
            "exception": _qualified_type(error),
        }
        subcommand = getattr(error, "subcommand", None)
        if isinstance(subcommand, str):
            result["subcommand"] = subcommand
        count = getattr(error, "count", None)
        if isinstance(count, int):
            result["count"] = count
        return result
    return {"outcome": "return", **_describe(value)}


def _raise_lib_error(*_: object, message: str, **__: object) -> t.NoReturn:
    """Raise a deterministic libtmux-layer listing error.

    Parameters
    ----------
    *_ : object
        Ignored positional arguments accepted from listing functions.
    message : str
        Stable error message used to select the owning error branch.
    **__ : object
        Ignored keyword arguments accepted from listing functions.

    Raises
    ------
    libtmux.exc.LibTmuxException
        Always, with ``message``.

    Examples
    --------
    >>> _capture(functools.partial(_raise_lib_error, message="probe failure"))
    {'outcome': 'raise', 'exception': 'libtmux.exc.LibTmuxException'}
    """
    raise exc.LibTmuxException(message)


def _linked_session_rows(
    *,
    list_cmd: str,
    fail_source: str | None = None,
    **_: object,
) -> list[dict[str, str]]:
    """Return duplicated holder rows or fail one linked-session source.

    Parameters
    ----------
    list_cmd : str
        Listing command requested by :attr:`Window.linked_sessions`.
    fail_source : str, optional
        Command name that should raise instead of returning rows.
    **_ : object
        Remaining listing arguments ignored by the controlled boundary.

    Returns
    -------
    list[dict[str, str]]
        Controlled window or session rows.

    Raises
    ------
    libtmux.exc.LibTmuxException
        When ``list_cmd`` equals ``fail_source``.

    Examples
    --------
    >>> rows = _linked_session_rows(list_cmd="list-windows")
    >>> [row["session_id"] for row in rows]
    ['$probe', '$probe']
    >>> failed = functools.partial(
    ...     _linked_session_rows,
    ...     list_cmd="list-sessions",
    ...     fail_source="list-sessions",
    ... )
    >>> _capture(failed)["exception"]
    'libtmux.exc.LibTmuxException'
    """
    if list_cmd == fail_source:
        msg = "controlled linked-session source failure"
        raise exc.LibTmuxException(msg)
    if list_cmd == "list-windows":
        return [
            {"window_id": "@probe", "session_id": "$probe"},
            {"window_id": "@probe", "session_id": "$probe"},
        ]
    return [{"session_id": "$probe", "session_name": "probe"}]


def _write_tmux_version_binary(root: pathlib.Path, raw_version: str) -> pathlib.Path:
    """Create an executable that reports one raw tmux version token.

    Parameters
    ----------
    root : pathlib.Path
        Directory that owns the controlled executable.
    raw_version : str
        Raw version token printed for ``-V``.

    Returns
    -------
    pathlib.Path
        Executable path accepted by libtmux's version helpers.

    Examples
    --------
    >>> with tempfile.TemporaryDirectory() as directory:
    ...     binary = _write_tmux_version_binary(pathlib.Path(directory), "3.7a")
    ...     result = subprocess.run(
    ...         [str(binary), "-V"], check=True, capture_output=True, text=True
    ...     )
    ...     result.stdout.strip()
    'tmux 3.7a'
    """
    binary = root / f"tmux-{raw_version}"
    binary.write_text(f"#!/bin/sh\nprintf 'tmux {raw_version}\\n'\n", encoding="utf-8")
    binary.chmod(binary.stat().st_mode | stat.S_IXUSR)
    return binary


def _version_lanes(root: pathlib.Path) -> list[JsonValue]:
    """Execute numeric and raw version helpers across required lane tokens.

    Parameters
    ----------
    root : pathlib.Path
        Directory for controlled version-reporting executables.

    Returns
    -------
    list[JsonValue]
        Raw, normalized, equality, and minimum-predicate outcomes per lane.

    Examples
    --------
    >>> with tempfile.TemporaryDirectory() as directory:
    ...     lanes = _version_lanes(pathlib.Path(directory))
    >>> [lane["rawVersion"] for lane in lanes]
    ['3.2a', '3.3', '3.7', '3.7a']
    >>> lanes[-2]["numericVersion"] == lanes[-1]["numericVersion"]
    True
    """
    lanes: list[JsonValue] = []
    for raw_version in ("3.2a", "3.3", "3.7", "3.7a"):
        binary = str(_write_tmux_version_binary(root, raw_version))
        get_version.cache_clear()
        get_version_str.cache_clear()
        lanes.append(
            {
                "rawVersion": get_version_str(tmux_bin=binary),
                "numericVersion": str(get_version(tmux_bin=binary)),
                "matchesRawPredicate": has_version(raw_version, tmux_bin=binary),
                "meets3_3Minimum": has_gte_version("3.3", tmux_bin=binary),
            }
        )
    get_version.cache_clear()
    get_version_str.cache_clear()
    return lanes


def observe_inherited_behavior(family: str, context: ProbeContext) -> Observation:
    """Execute one inherited family and return only runtime-derived outcomes.

    Parameters
    ----------
    family : str
        Stable inherited behavior family ID.
    context : ProbeContext
        Live and controlled resources used by the operation.

    Returns
    -------
    Observation
        Structured values for the four contract fields.

    Raises
    ------
    KeyError
        When ``family`` has no inherited observer.

    Examples
    --------
    Unknown families fail closed instead of fabricating evidence:

    >>> try:
    ...     observe_inherited_behavior("missing.family", t.cast("ProbeContext", None))
    ... except KeyError as error:
    ...     error.args[0]
    'missing.family'
    """
    if family not in INHERITED_FAMILIES:
        raise KeyError(family)

    accessor: Callable[[], t.Any]
    failure: t.Any
    live: t.Any
    malformed: t.Any
    missing: t.Any
    missing_identity: t.Any
    missing_live: t.Any
    module: t.Any
    no_active: t.Any
    scalar: t.Any
    sparse: t.Any
    success: t.Any
    target: t.Any

    if family == "format.projection":
        fields, format_string = get_output_format("list-sessions", "3.7a")
        values = [""] * len(fields)
        values[fields.index("session_id")] = "$probe"
        values[fields.index("window_id")] = "@probe"
        parsed = parse_output(
            FORMAT_SEPARATOR.join(values) + FORMAT_SEPARATOR,
            "list-sessions",
            "3.7a",
        )
        lanes: list[JsonValue] = []
        for version in ("3.2a", "3.3", "3.7", "3.7a"):
            lane_fields, _ = get_output_format("list-panes", version)
            lanes.append(
                {
                    "rawVersion": version,
                    "fieldCount": len(lane_fields),
                    "hasPaneDeadSignal": "pane_dead_signal" in lane_fields,
                    "hasPaneFlags": "pane_flags" in lane_fields,
                }
            )
        return {
            "expectedResultShape": {
                "fields": _describe(fields),
                "formatSeparatorCount": format_string.count(FORMAT_SEPARATOR),
                "parsed": _describe(parsed),
            },
            "exitStderrPolicy": dict(NEEDS_CONTEXT),
            "listLeniency": dict(NEEDS_CONTEXT),
            "versionLanes": lanes,
        }

    if family == "lifecycle.cleanup":
        window = context.session.new_window(window_name="parity-pane-cleanup")
        pane = window.split()
        pane_id = pane.pane_id
        with pane:
            assert pane_id in {item.pane_id for item in window.panes}
        pane_reaped = pane_id not in {item.pane_id for item in window.panes}

        owned_window = context.session.new_window(window_name="parity-window-cleanup")
        window_id = owned_window.window_id
        with owned_window:
            assert window_id in {item.window_id for item in context.session.windows}
        window_reaped = window_id not in {
            item.window_id for item in context.session.windows
        }

        owned_session = context.server.new_session(
            session_name="parity-session-cleanup"
        )
        session_id = owned_session.session_id
        with owned_session:
            assert session_id in {item.session_id for item in context.server.sessions}
        session_reaped = session_id not in {
            item.session_id for item in context.server.sessions
        }

        owned_server = Server(socket_name=f"{context.server.socket_name}-cleanup")
        with owned_server:
            owned_server.new_session(session_name="owned")
            assert owned_server.is_alive()
        server_reaped = not owned_server.is_alive()

        with context.control_mode():
            clients_inside = len(context.server.clients)
        clients_after = len(context.server.clients)

        marker = RuntimeError("controlled operation failure")
        caught: RuntimeError | None = None
        try:
            with context.server.new_session(session_name="parity-error-cleanup"):
                raise marker
        except RuntimeError as error:
            caught = error

        return {
            "expectedResultShape": {
                "paneReaped": pane_reaped,
                "windowReaped": window_reaped,
                "sessionReaped": session_reaped,
                "serverReaped": server_reaped,
                "controlClientsInside": clients_inside,
                "controlClientsAfter": clients_after,
            },
            "exitStderrPolicy": {
                "exception": _qualified_type(caught),
                "sameExceptionInstance": caught is marker,
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "list.liveness.is-alive":
        missing = Server(socket_name=f"{context.server.socket_name}-missing")
        missing_binary = Server(tmux_bin=str(context.tmp_path / "missing-tmux"))
        with context.monkeypatch.context() as patch:
            patch.setattr(
                Server,
                "cmd",
                lambda *_args, **_kwargs: (_ for _ in ()).throw(
                    RuntimeError("controlled command failure")
                ),
            )
            command_failure = context.server.is_alive()
        return {
            "expectedResultShape": {
                "live": context.server.is_alive(),
                "deadSocket": missing.is_alive(),
            },
            "exitStderrPolicy": {
                "commandException": command_failure,
                "missingExecutable": missing_binary.is_alive(),
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "list.liveness.require-alive":
        dead = Server(socket_name=f"{context.server.socket_name}-missing")
        missing_binary = Server(tmux_bin=str(context.tmp_path / "missing-tmux"))
        return {
            "expectedResultShape": {"live": _capture(context.server.raise_if_dead)},
            "exitStderrPolicy": {
                "deadSocket": _capture(dead.raise_if_dead),
                "missingExecutable": _capture(missing_binary.raise_if_dead),
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family.startswith("list.predicate."):
        if family == "list.predicate.server.malformed-empty":
            malformed = context.server.search_sessions(filter="#{not_closed")
            module = libtmux.server
            accessor = functools.partial(
                context.server.search_sessions,
                filter="#{session_id}",
            )
        elif family == "list.predicate.session.malformed-empty":
            malformed = context.session.search_windows(filter="#{not_closed")
            module = libtmux.session
            accessor = functools.partial(
                context.session.search_windows,
                filter="#{window_id}",
            )
        else:
            window = context.session.active_window
            malformed = window.search_panes(filter="#{not_closed")
            module = libtmux.window
            accessor = functools.partial(window.search_panes, filter="#{pane_id}")
        with context.monkeypatch.context() as patch:
            patch.setattr(
                module,
                "fetch_objs",
                functools.partial(
                    _raise_lib_error,
                    message="no server running on controlled socket",
                ),
            )
            daemon_failure = _capture(accessor)
        with context.monkeypatch.context() as patch:
            patch.setattr(
                module,
                "fetch_objs",
                functools.partial(
                    _raise_lib_error,
                    message="controlled non-daemon failure",
                ),
            )
            other_failure = _capture(accessor)
        return {
            "expectedResultShape": _describe(malformed),
            "exitStderrPolicy": {
                "daemonUnavailable": daemon_failure,
                "otherLibTmuxException": other_failure,
            },
            "listLeniency": {
                "daemonUnavailableReturnsEmpty": (
                    daemon_failure.get("outcome") == "return"
                    and daemon_failure.get("count") == 0
                ),
                "otherErrorPropagates": other_failure.get("outcome") == "raise",
            },
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family in {
        "list.server.clients.any-error-empty",
        "list.server.sessions.any-error-empty",
    }:
        accessor = (
            (lambda: context.server.clients)
            if family == "list.server.clients.any-error-empty"
            else (lambda: context.server.sessions)
        )
        if family == "list.server.clients.any-error-empty":
            with context.control_mode():
                success = accessor()
        else:
            success = accessor()
        with context.monkeypatch.context() as patch:
            patch.setattr(
                libtmux.server,
                "fetch_objs",
                functools.partial(
                    _raise_lib_error,
                    message="controlled libtmux failure",
                ),
            )
            failure = _capture(accessor)
        return {
            "expectedResultShape": _collection_shape(success),
            "exitStderrPolicy": {"libtmuxException": failure},
            "listLeniency": {"libtmuxException": failure},
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family in {
        "list.server.panes.daemon-unavailable-empty",
        "list.server.search-panes.daemon-unavailable-empty",
        "list.server.search-sessions.daemon-unavailable-empty",
        "list.server.search-windows.daemon-unavailable-empty",
        "list.server.windows.daemon-unavailable-empty",
    }:
        if family == "list.server.panes.daemon-unavailable-empty":
            accessor = functools.partial(getattr, context.server, "panes")
        elif family == "list.server.windows.daemon-unavailable-empty":
            accessor = functools.partial(getattr, context.server, "windows")
        elif family == "list.server.search-panes.daemon-unavailable-empty":
            pane_id = context.session.active_pane.pane_id  # type: ignore[union-attr]
            accessor = functools.partial(
                context.server.search_panes,
                filter=f"#{{m:{pane_id},#{{pane_id}}}}",
            )
        elif family == "list.server.search-sessions.daemon-unavailable-empty":
            accessor = functools.partial(
                context.server.search_sessions,
                filter=f"#{{m:{context.session.session_id},#{{session_id}}}}",
            )
        else:
            window_id = context.session.active_window.window_id
            accessor = functools.partial(
                context.server.search_windows,
                filter=f"#{{m:{window_id},#{{window_id}}}}",
            )
        success = accessor()
        with context.monkeypatch.context() as patch:
            patch.setattr(
                libtmux.server,
                "fetch_objs",
                functools.partial(
                    _raise_lib_error,
                    message="no server running on controlled socket",
                ),
            )
            daemon_failure = _capture(accessor)
        with context.monkeypatch.context() as patch:
            patch.setattr(
                libtmux.server,
                "fetch_objs",
                functools.partial(
                    _raise_lib_error,
                    message="controlled non-daemon failure",
                ),
            )
            other_failure = _capture(accessor)
        return {
            "expectedResultShape": _collection_shape(success),
            "exitStderrPolicy": {
                "daemonUnavailable": daemon_failure,
                "otherLibTmuxException": other_failure,
            },
            "listLeniency": {
                "daemonUnavailable": daemon_failure,
                "otherLibTmuxException": other_failure,
            },
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "list.session.active-pane.optional":
        active_window = context.session.active_window
        live = context.session.active_pane
        with context.monkeypatch.context() as patch:
            patch.setattr(Window, "panes", property(lambda _: QueryList()))
            no_active = context.session.active_pane
        with context.monkeypatch.context() as patch:
            patch.setattr(
                Session,
                "active_window",
                property(
                    lambda _: (_ for _ in ()).throw(
                        exc.LibTmuxException("controlled listing failure")
                    )
                ),
            )
            listing_failure = _capture(lambda: context.session.active_pane)
        return {
            "expectedResultShape": {
                "live": _describe(live),
                "noActivePane": _describe(no_active),
                "window": _describe(active_window),
            },
            "exitStderrPolicy": {"listingFailure": listing_failure},
            "listLeniency": {"listingFailure": listing_failure},
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "list.session.active-window.cardinality":
        live = context.session.active_window
        with context.monkeypatch.context() as patch:
            patch.setattr(Session, "windows", property(lambda _: QueryList()))
            no_active = _capture(lambda: context.session.active_window)
        active = QueryList(
            [
                Window(
                    server=context.server,
                    window_active="1",
                    window_id="@probe-one",
                ),
                Window(
                    server=context.server,
                    window_active="1",
                    window_id="@probe-two",
                ),
            ]
        )
        with context.monkeypatch.context() as patch:
            patch.setattr(Session, "windows", property(lambda _: active))
            multiple = _capture(lambda: context.session.active_window)
        with context.monkeypatch.context() as patch:
            patch.setattr(
                Session,
                "windows",
                property(
                    lambda _: (_ for _ in ()).throw(
                        exc.LibTmuxException("controlled listing failure")
                    )
                ),
            )
            listing_failure = _capture(lambda: context.session.active_window)
        return {
            "expectedResultShape": _describe(live),
            "exitStderrPolicy": {
                "noActive": no_active,
                "multipleActive": multiple,
            },
            "listLeniency": {"listingFailure": listing_failure},
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family in {
        "list.session.panes.propagate",
        "list.session.search-panes.propagate",
        "list.session.search-windows.propagate",
        "list.session.windows.propagate",
        "list.window.panes.propagate",
        "list.window.search-panes.propagate",
    }:
        if family == "list.session.panes.propagate":
            module = libtmux.session
            accessor = functools.partial(getattr, context.session, "panes")
        elif family == "list.session.windows.propagate":
            module = libtmux.session
            accessor = functools.partial(getattr, context.session, "windows")
        elif family == "list.session.search-panes.propagate":
            module = libtmux.session
            pane_id = context.session.active_pane.pane_id  # type: ignore[union-attr]
            accessor = functools.partial(
                context.session.search_panes,
                filter=f"#{{m:{pane_id},#{{pane_id}}}}",
            )
        elif family == "list.session.search-windows.propagate":
            module = libtmux.session
            window_id = context.session.active_window.window_id
            accessor = functools.partial(
                context.session.search_windows,
                filter=f"#{{m:{window_id},#{{window_id}}}}",
            )
        elif family == "list.window.panes.propagate":
            module = libtmux.window
            window = context.session.active_window
            accessor = functools.partial(getattr, window, "panes")
        else:
            module = libtmux.window
            window = context.session.active_window
            pane_id = context.session.active_pane.pane_id  # type: ignore[union-attr]
            accessor = functools.partial(
                window.search_panes,
                filter=f"#{{m:{pane_id},#{{pane_id}}}}",
            )
        success = accessor()
        with context.monkeypatch.context() as patch:
            patch.setattr(
                module,
                "fetch_objs",
                functools.partial(
                    _raise_lib_error,
                    message="controlled listing failure",
                ),
            )
            failure = _capture(accessor)
        return {
            "expectedResultShape": _collection_shape(success),
            "exitStderrPolicy": {"listingFailure": failure},
            "listLeniency": {"listingFailure": failure},
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "list.window.linked-sessions.either-source-empty-deduplicated":
        window = Window(server=context.server, window_id="@probe")
        with context.monkeypatch.context() as patch:
            patch.setattr(libtmux.window, "fetch_objs", _linked_session_rows)
            holders = window.linked_sessions
        failures: dict[str, JsonValue] = {}
        for source in ("list-windows", "list-sessions"):
            with context.monkeypatch.context() as patch:
                patch.setattr(
                    libtmux.window,
                    "fetch_objs",
                    functools.partial(_linked_session_rows, fail_source=source),
                )
                failures[source] = _capture(lambda: window.linked_sessions)
        return {
            "expectedResultShape": {
                **_collection_shape(holders),
                "count": len(holders),
                "sessionIds": [item.session_id for item in holders],
            },
            "exitStderrPolicy": failures,
            "listLeniency": failures,
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "public.surface":
        return {
            "expectedResultShape": dict(NEEDS_CONTEXT),
            "exitStderrPolicy": dict(NOT_APPLICABLE),
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family in {
        "refresh.client",
        "refresh.pane",
        "refresh.session",
        "refresh.window",
    }:
        if family == "refresh.client":
            missing_identity = Client(server=context.server)
            missing_live = Client(server=context.server, client_name="/missing-client")
            with context.control_mode():
                target = context.server.clients[0]
                before_id = id(target)
                target.refresh()
                success = {
                    "pythonType": _qualified_type(target),
                    "sameInstance": id(target) == before_id,
                }
        elif family == "refresh.pane":
            missing_identity = Pane(server=context.server)
            missing_live = Pane(server=context.server, pane_id="%999999")
            target = t.cast("Pane", context.session.active_pane)
            before_id = id(target)
            target.refresh()
            success = {
                "pythonType": _qualified_type(target),
                "sameInstance": id(target) == before_id,
            }
        elif family == "refresh.session":
            missing_identity = Session(server=context.server)
            missing_live = Session(server=context.server, session_id="$999999")
            target = context.session
            before_id = id(target)
            target.refresh()
            success = {
                "pythonType": _qualified_type(target),
                "sameInstance": id(target) == before_id,
            }
        else:
            missing_identity = Window(server=context.server)
            missing_live = Window(server=context.server, window_id="@999999")
            target = context.session.active_window
            before_id = id(target)
            target.refresh()
            success = {
                "pythonType": _qualified_type(target),
                "sameInstance": id(target) == before_id,
            }
        identity_failure = _capture(missing_identity.refresh)
        missing_failure = _capture(missing_live.refresh)
        with context.monkeypatch.context() as patch:
            patch.setattr(
                libtmux.neo,
                "fetch_obj",
                functools.partial(
                    _raise_lib_error,
                    message="controlled refresh failure",
                ),
            )
            listing_failure = _capture(target.refresh)
        return {
            "expectedResultShape": success,
            "exitStderrPolicy": {
                "missingIdentity": identity_failure,
                "missingLiveObject": missing_failure,
            },
            "listLeniency": {"listingFailure": listing_failure},
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "refresh.stale-object":
        pane = context.session.active_window.split()
        pane_id = pane.pane_id
        pane.kill()
        failure = _capture(pane.refresh)
        return {
            "expectedResultShape": {
                "pythonType": _qualified_type(pane),
                "identityPreserved": pane.pane_id == pane_id,
            },
            "exitStderrPolicy": {"refreshAfterKill": failure},
            "listLeniency": {"refreshAfterKill": failure},
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "state.environments":
        context.session.set_environment("LIBTMUX_PARITY_EMPTY", "")
        empty_value = context.session.getenv("LIBTMUX_PARITY_EMPTY")
        context.session.set_environment("LIBTMUX_PARITY_UNSET", "value")
        context.session.unset_environment("LIBTMUX_PARITY_UNSET")
        unset_value = context.session.getenv("LIBTMUX_PARITY_UNSET")
        context.session.set_environment(
            "LIBTMUX_PARITY_HIDDEN",
            "hidden-value",
            hidden=True,
        )
        hidden_value = context.session.getenv("LIBTMUX_PARITY_HIDDEN")
        invalid_set = _capture(
            functools.partial(context.session.set_environment, "", "value")
        )
        gone = context.server.new_session(session_name="parity-gone-environment")
        gone.kill()
        missing_target = _capture(gone.show_environment)
        return {
            "expectedResultShape": {
                "empty": _describe(empty_value),
                "unset": _describe(unset_value),
                "hidden": _describe(hidden_value),
            },
            "exitStderrPolicy": {
                "invalidSet": invalid_set,
                "missingTargetShow": missing_target,
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "state.hooks":
        context.session.set_hook("after-new-window", "display-message scalar")
        scalar = context.session.show_hook("after-new-window")
        context.session.set_hook("session-renamed[5]", "display-message fifth")
        context.session.set_hook("session-renamed[0]", "display-message zeroth")
        sparse = context.session.show_hook("session-renamed")
        invalid = _capture(
            functools.partial(
                context.session.set_hook,
                "definitely-not-a-hook",
                "display-message invalid",
            )
        )
        return {
            "expectedResultShape": {
                "scalar": {
                    **_collection_shape(scalar),
                    "indices": [
                        str(key) for key in t.cast("dict[object, object]", scalar)
                    ],
                },
                "sparse": {
                    **_collection_shape(sparse),
                    "indices": [
                        str(key) for key in t.cast("dict[object, object]", sparse)
                    ],
                },
            },
            "exitStderrPolicy": {"invalidHook": invalid},
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "state.options":
        context.session.set_option("status", "off")
        flag = context.session.show_option("status")
        scalar = context.server.show_option("buffer-limit")
        context.session.set_option("status-style", "fg=red")
        style = context.session.show_option("status-style")
        array = context.server.show_option("command-alias")
        sparse = context.session.show_option("status-format", global_=True)
        invalid = _capture(
            functools.partial(
                context.session.show_option,
                "definitely-not-an-option",
            )
        )
        ambiguous = _capture(functools.partial(context.session.show_option, "window-"))
        return {
            "expectedResultShape": {
                "flag": _describe(flag),
                "scalar": _describe(scalar),
                "style": _describe(style),
                "array": _collection_shape(array),
                "sparse": _collection_shape(sparse),
            },
            "exitStderrPolicy": {
                "invalid": invalid,
                "ambiguous": ambiguous,
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "state.sparse-arrays":
        sparse_values: SparseArray[str] = SparseArray()
        sparse_values.add(0, "on")
        sparse_values.add(5, "off")
        sparse_values.add(99, "100")
        converted = convert_values(sparse_values)
        return {
            "expectedResultShape": {
                **_collection_shape(converted),
                "indices": [
                    str(key) for key in t.cast("dict[object, object]", converted)
                ],
                "values": list(t.cast("dict[object, JsonValue]", converted).values()),
            },
            "exitStderrPolicy": dict(NEEDS_CONTEXT),
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "transport.cmd.invalid-bytes":
        result = tmux_cmd(
            "-c",
            "import os,sys; os.write(1,b'\\xffout\\n'); "
            "os.write(2,b'\\xfeerr\\n'); sys.exit(7)",
            tmux_bin=sys.executable,
        )
        return {
            "expectedResultShape": {
                "pythonType": _qualified_type(result),
                "stdout": result.stdout,
                "stderr": result.stderr,
                "returncode": result.returncode,
            },
            "exitStderrPolicy": {
                "stdoutOwned": result.stdout == ["\\xffout"],
                "stderrOwned": result.stderr == ["\\xfeerr"],
                "statusPreserved": result.returncode == 7,
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "transport.cmd.nonzero":
        result = context.server.cmd("list-clients", "-t", "$missing-parity-probe")
        raised = _capture(functools.partial(raise_if_stderr, result, "list-clients"))
        return {
            "expectedResultShape": {
                "pythonType": _qualified_type(result),
                "stdout": result.stdout,
                "stderrCount": len(result.stderr),
                "returncode": result.returncode,
            },
            "exitStderrPolicy": {"raiseIfStderr": raised},
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "transport.cmd.result":
        success = context.server.cmd("display-message", "-p", "parity-probe")
        failure = context.server.cmd("list-clients", "-t", "$missing-parity-probe")
        return {
            "expectedResultShape": {
                "success": {
                    "stdout": success.stdout,
                    "stderr": success.stderr,
                    "returncode": success.returncode,
                },
                "nonzero": {
                    "stdout": failure.stdout,
                    "stderrCount": len(failure.stderr),
                    "returncode": failure.returncode,
                },
            },
            "exitStderrPolicy": {
                "rawNonzeroReturn": _describe(failure),
                "raisedByRawCommand": False,
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "transport.has-session":
        name = t.cast("str", context.session.session_name)
        existing = context.server.has_session(name)
        missing = context.server.has_session("missing-parity-probe")
        raw_missing = context.server.cmd(
            "has-session",
            target="=missing-parity-probe",
        )
        return {
            "expectedResultShape": {
                "existing": _describe(existing),
                "missing": _describe(missing),
            },
            "exitStderrPolicy": {
                "rawStdout": raw_missing.stdout,
                "rawStderr": raw_missing.stderr,
                "mirrored": raw_missing.stdout == raw_missing.stderr[:1],
                "returncode": raw_missing.returncode,
            },
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": dict(NEEDS_CONTEXT),
        }

    if family == "versions.feature-gates":
        return {
            "expectedResultShape": {
                "laneResultType": _qualified_type(
                    has_version("3.2a", tmux_bin=context.server.tmux_bin)
                )
            },
            "exitStderrPolicy": dict(NEEDS_CONTEXT),
            "listLeniency": dict(NOT_APPLICABLE),
            "versionLanes": _version_lanes(context.tmp_path),
        }

    msg = f"unreachable inherited family: {family}"
    raise AssertionError(msg)
