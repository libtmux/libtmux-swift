"""Executable behavior probes referenced by the Swift parity corpus."""

from __future__ import annotations

import asyncio
import typing as t

import libtmux.neo
import pytest
from libtmux import exc
from libtmux._internal.query_list import QueryList
from libtmux.server import Server
from libtmux.session import Session


def test_list_cancellation_propagates(
    server: Server,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Verify cancellation is not absorbed by a list accessor.

    Monkeypatching is required because a real subprocess cancellation cannot
    be induced safely through the synchronous tmux fixture.
    """

    def cancel(*args: t.Any, **kwargs: t.Any) -> t.NoReturn:
        raise asyncio.CancelledError

    monkeypatch.setattr(libtmux.neo, "tmux_cmd", cancel)

    with pytest.raises(asyncio.CancelledError):
        _ = server.sessions


def test_server_malformed_native_filter_is_empty(session: Session) -> None:
    """Verify a malformed server predicate expands false."""
    assert session.server.search_sessions(filter="#{not_closed") == []


def test_session_malformed_native_filter_is_empty(session: Session) -> None:
    """Verify a malformed session predicate expands false."""
    assert session.search_windows(filter="#{not_closed") == []


def test_window_malformed_native_filter_is_empty(session: Session) -> None:
    """Verify a malformed window predicate expands false."""
    assert session.active_window.search_panes(filter="#{not_closed") == []


def test_query_get_no_match_raises_from_real_lookup() -> None:
    """Verify a real no-match query raises with its lookup criteria."""
    rows = QueryList([{"id": "a", "name": "apple"}])

    with pytest.raises(exc.ObjectDoesNotExist) as caught:
        rows.get(name="pear")

    assert caught.value.query == {"name": "pear"}
