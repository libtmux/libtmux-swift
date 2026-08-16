#!/usr/bin/env python3
"""Measure the Swift surface against Python libtmux's recorded API.

`Parity/python-public-api.json` records what Python libtmux exposes and marks
each entry `direct` (should have a Swift counterpart) or `python-only`. Nothing
compared the two, so "parity" was a number somebody remembered rather than one
anybody could check.

Matching is by name, normalised across the two languages' conventions
(`new_session` / `newSession`), which is approximate on purpose: it is a map of
where to look, not a proof of equivalence. A name that matches may still differ
in behaviour, and a genuine counterpart under a different name reads here as a
gap — see the `RENAMES` table for the ones already accounted for.

Every entry lands in one of three buckets. *Covered* is a counterpart that
exists, under whatever name. *Declined* is a member this port will not have, with
the reason. *Pending* is everything else, and is the only bucket that is a queue.
The percentage is over covered and pending, because counting the declined ones
against the total makes the number fall as decisions are made.

    python3 Scripts/parity_report.py            # summary
    python3 Scripts/parity_report.py --missing  # and what is still pending
"""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Parity" / "python-public-api.json"
SOURCES = ROOT / "Sources"

# Kinds that describe behaviour a caller invokes.
BEHAVIOUR_KINDS = {
    "method",
    "inherited-method",
    "class-method",
    "property",
    "function",
    "class",
    "exception",
    "enum-member",
    "constant",
    "class-attribute",
    "inherited-class-attribute",
}
# Kinds that describe tmux format fields surfaced as attributes. Swift exposes a
# curated subset by design, so these are counted apart from behaviour.
FIELD_KINDS = {"dataclass-field", "inherited-dataclass-field"}

# What a group's number does and does not mean. Without this the format-field
# share reads as a backlog, when the uncounted fields are reachable and only
# the listed ones are worth a stored property.
GROUP_NOTES = {
    "format fields": (
        "counted = carried on a type; the rest are reachable through "
        "Server.format(_:for:)"
    ),
}

# Counterparts this port gives a different name, with the reason. Anything here
# is deliberate; anything not here and missing is a gap or a decision nobody has
# written down yet.
RENAMES = {
    "list_sessions": "sessions",
    "list_windows": "windows",
    "list_panes": "panes",
    "list_buffers": "buffers",
    "list_clients": "clients",
    "show_buffer": "buffer",
    "cmd": "run",
    "new_session": "newsession",
    "new_window": "newwindow",
    "split_window": "splitwindow",
    "kill_session": "kill",
    "kill_window": "kill",
    "kill_pane": "kill",
    "kill_server": "kill",
    "rename_session": "rename",
    "rename_window": "rename",
    "send_keys": "sendkeys",
    "capture_pane": "capture",
    "select_window": "select",
    "select_pane": "select",
    "set_option": "setoption",
    "show_option": "option",
    "show_options": "options",
    "set_hook": "sethook",
    "show_hooks": "hooks",
    "is_alive": "isrunning",
    "raise_if_dead": "requirerunning",
    "detach_client": "detach",
    "detach_all_clients": "detachclients",
    "move_window": "move",
    "next_window": "selectnextwindow",
    "previous_window": "selectpreviouswindow",
    "last_window": "selectlastwindow",
    "clear": "clearhistory",
    "split": "splitwindow",
    "new_pane": "splitwindow",
    "paste_buffer": "paste",
    "set_height": "resize",
    "set_width": "resize",
    "title": "settitle",
    "get_version": "version",
    "show_environment": "environment",
    "getenv": "environmentvalue",
    "set_environment": "setenvironment",
    "unset_environment": "unsetenvironment",
    "remove_environment": "removeenvironment",
    "get_version_str": "version",
    "wait_for": "wait",
    # Types, for the enum cases matched by their owner. `before` and `after`
    # are positions in an ordering rather than directions, and a resize names
    # where a boundary goes rather than adjusting an abstract quantity.
    "WindowDirection": "WindowPlacement",
    "ResizeAdjustmentDirection": "ResizeDirection",
}


# Members this port answers by other means. Recorded so they read as decided
# rather than pending: the report should distinguish "nobody has done this" from
# "this is done, differently, on purpose".
ANSWERED_DIFFERENTLY = {
    "from_session_id": "sessions().first { $0.id == id } — results are plain arrays",
    "from_window_id": "windows().first { $0.id == id }",
    "from_pane_id": "panes().first { $0.id == id }",
    "from_client_name": "clients().first { $0.name == name }",
    "from_env": "TmuxContext.current()",
    "attached_session": "Snapshot.session(of: client)",
    "attached_window": "Snapshot.windows(of: session).first(where: \\.isActive)",
    "attached_pane": "Snapshot.panes(of: window).first(where: \\.isActive)",
    "attached_panes": "Snapshot.panes(of: session).filter(\\.isActive)",
    "attached_windows": "Snapshot.windows(of: session).filter(\\.isActive)",
    "refresh": "read again — a value is what the server said when asked",
    "show_hook": "hooks(scope).first { $0.name == name }",
    "set_hooks": "setHook per name — tmux sets one hook per command",
    "attached_sessions": "sessions().filter(\\.isAttached)",
    "active_window": "Snapshot.windows(of: session).first(where: \\.isActive)",
    "active_pane": "Snapshot.panes(of: window).first(where: \\.isActive)",
    "linked_sessions": "windows().filter { $0.id == window.id } — one row per session",
    "search_sessions": "sessions().filter(FilterExpr<Session>)",
    "search_windows": "windows().filter(FilterExpr<Window>)",
    "search_panes": "panes().filter(FilterExpr<Pane>)",
    "display_message": "format(_:for:) — the value, not a message on a client",
    "socket_name": "endpoint — a name and a path are one addressable thing",
    "has_version": "version() and TmuxVersion: Comparable",
    "has_gt_version": "version() > TmuxVersion(major:minor:)",
    "has_gte_version": "version() >= TmuxVersion(major:minor:)",
    "has_lt_version": "version() < TmuxVersion(major:minor:)",
    "has_lte_version": "version() <= TmuxVersion(major:minor:)",
    "has_minimum_version": "version() >= TmuxVersion(major:minor:)",
    "find_window": "windows().first { $0.id == pane.windowID }",
    # Python keeps each enum's tmux flags in a table beside it. Swift keeps them
    # on the case, so there is no table to expose and no way for the two to
    # drift apart.
    "PANE_DIRECTION_FLAG_MAP": "PaneDirection knows its own flags",
    "WINDOW_DIRECTION_FLAG_MAP": "WindowPlacement knows its own flag",
    "RESIZE_ADJUSTMENT_DIRECTION_FLAG_MAP": "ResizeDirection knows its own flag",
    "OPTION_SCOPE_FLAG_MAP": "OptionScope knows its own flag",
    "HOOK_SCOPE_FLAG_MAP": "HookScope knows its own flag",
    "DEFAULT_OPTION_SCOPE": "a default argument, not a sentinel to compare against",
    "default_option_scope": "a default argument on the call that takes a scope",
    "default_hook_scope": "a default argument on the call that takes a scope",
    # Python composes behaviour onto its objects with mixins. Swift extends the
    # concrete type, so the calls are on `Server` and there is nothing to mix.
    "CmdMixin": "run(_:) is on the type; there is nothing to mix in",
    "CmdProtocol": "run(_:) is on the type; there is nothing to mix in",
    "EnvironmentMixin": "environment(...) on Server, scoped by EnvironmentScope",
    "OptionsMixin": "options(...) on Server, scoped by OptionScope",
    "HooksMixin": "hooks(...) on Server, scoped by HookScope",
    "tmux_cmd": "TmuxCommand goes out, TmuxReply comes back",
    "raise_if_stderr": "a rejected command throws where it was sent",
    # Reading tmux's own spelling of an option value is what `Options` does; how
    # it does it is not something a caller reaches for.
    "convert_value": "Options decodes what tmux prints",
    "convert_values": "Options decodes what tmux prints",
    "explode_arrays": "Options decodes what tmux prints",
    "explode_complex": "Options decodes what tmux prints",
    "parse_options_to_dict": "Options decodes what tmux prints",
    "handle_option_error": "TmuxError — one typed error, from every call",
    "child_id_attribute": "each type names its own id field in its projection",
    "formatter_prefix": "FormatField names the field, with nothing to strip",
    "tmux_bin": "Server(socketPath:tmuxExecutable:) — a binary is part of addressing",
}

# Whole Python modules this port answers with one thing. Recorded by module
# because listing an exception hierarchy member by member would say the same
# sentence for every one of them.
#
# Behaviour only. `libtmux.neo.Obj` also carries every tmux format field, and
# counting those as covered because the module they live in is answered would
# turn "a curated subset is stored, the rest is reachable" into a parity claim.
MODULE_ANSWERS = {
    "libtmux.exc": "TmuxError — one typed error, thrown by every call that throws",
    "libtmux.neo": "FormatProjection — reading and decoding tmux formats",
    "libtmux.formats": "FormatField — a field names itself rather than a constant",
}

ATTACHING = (
    "attaching wants a terminal; connected(attachingTo:) is how a program attaches"
)

# Members this port will not have, and why. A decision belongs here so it can be
# argued with; without it a decision is indistinguishable from an oversight.
DECLINED = {
    "attach_session": ATTACHING,
    "attach": ATTACHING,
    "command_prompt": "prompts a client this library never has",
    "confirm_before": "prompts a client this library never has",
    "display_menu": "draws on a client this library never has",
    "display_popup": "draws on a client this library never has",
    "display_panes": "draws on a client this library never has",
    "choose_buffer": "draws on a client this library never has",
    "choose_client": "draws on a client this library never has",
    "choose_tree": "draws on a client this library never has",
    "copy_mode": "a mode of a client this library never has",
    "clock_mode": "a mode of a client this library never has",
    "customize_mode": "a mode of a client this library never has",
    "clear_prompt_history": "a client's prompt history, and there is no client",
    "show_prompt_history": "a client's prompt history, and there is no client",
    "send_prefix": "the prefix is a client's key table, not a server operation",
    "bind_key": "bindings fire in a client this library never has",
    "unbind_key": "bindings fire in a client this library never has",
    "list_keys": "bindings fire in a client this library never has",
}


def normalise(name: str) -> str:
    """Fold a Python or Swift member name to a comparable key."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def swift_surface() -> tuple[set[str], set[str]]:
    """Collect what Sources declares: public names, and enum cases by owner.

    Cases are kept apart, qualified by the enum that owns them, because a bare
    `left` says nothing about which enum it came from — matching it by name
    alone would let a split direction answer for a resize adjustment.
    """
    names: set[str] = set()
    cases: set[str] = set()
    decl = re.compile(
        r"^\s*public\s+(?:static\s+|nonisolated\s+)*"
        r"(?:func|var|let|struct|enum|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"
    )
    enum_decl = re.compile(r"^\s*(public\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)")
    ends_enum = re.compile(
        r"^\s*(?:public\s+)?(?:struct|actor|class|protocol|extension)\b"
    )
    # An enum's cases carry no access modifier of their own — they are as public
    # as the enum — so the declaration pattern above cannot see them, and every
    # `PaneDirection.Above` in Python reads as a gap next to a Swift enum that
    # has exactly that case. Anchored on the name coming first, which a `switch`
    # arm never does: those are written `case .above:` or `case let .cells(n):`.
    case = re.compile(
        r"^\s*case\s+([A-Za-z_][A-Za-z0-9_]*"
        r"(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*(?:\(|=|$)"
    )
    for path in SOURCES.rglob("*.swift"):
        owner: str | None = None
        for line in path.read_text().splitlines():
            if found := enum_decl.match(line):
                owner = found.group(2) if found.group(1) else None
            elif ends_enum.match(line):
                owner = None
            if found := decl.match(line):
                names.add(normalise(found.group(1)))
            elif owner and (found := case.match(line)):
                cases.update(
                    f"{normalise(owner)}.{normalise(name)}"
                    for name in found.group(1).split(",")
                )
    return names, cases


def python_entries() -> list[dict]:
    """Every manifest entry this port is supposed to have a counterpart for."""
    manifest = json.loads(MANIFEST.read_text())
    return [e for e in manifest["entries"] if e.get("disposition") == "direct"]


def member_of(qualified: str) -> str:
    """Take the bare member name — `Server.kill_session` is `kill_session`."""
    return qualified.rsplit(".", 1)[-1]


def module_of(qualified: str) -> str:
    """Take the module an entry belongs to — `libtmux.server`, `libtmux.exc`."""
    return ".".join(qualified.split(".")[:2])


def verdict(entry: dict, surface: set[str], cases: set[str]) -> str:
    """Whether this entry is `covered`, `declined`, or still `pending`."""
    member = member_of(entry["qualifiedName"])
    if member.startswith("_"):
        return "covered"  # Private in Python; nothing to port.
    if member in DECLINED:
        return "declined"
    if member in ANSWERED_DIFFERENTLY:
        return "covered"
    if (
        entry["kind"] not in FIELD_KINDS
        and module_of(entry["qualifiedName"]) in MODULE_ANSWERS
    ):
        return "covered"
    if entry["kind"] == "enum-member":
        owner = entry["qualifiedName"].split(".")[-2]
        owner = RENAMES.get(owner, owner)
        return (
            "covered"
            if f"{normalise(owner)}.{normalise(member)}" in cases
            else "pending"
        )
    key = normalise(RENAMES.get(member, member))
    # Swift's API guidelines put booleans in the assertive: Python's `at_top`
    # and `attached` are `isAtTop` and `isAttached` here. Without this the tool
    # reports a convention as a gap.
    if key in surface or f"is{key}" in surface:
        return "covered"
    return "pending"


def main() -> int:
    """Print the report, and optionally the pending queue behind it."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--missing", action="store_true", help="list what is still pending"
    )
    args = parser.parse_args()

    if not MANIFEST.exists():
        print(f"no manifest at {MANIFEST}", file=sys.stderr)
        return 1

    surface, cases = swift_surface()
    entries = python_entries()
    verdicts = {e["qualifiedName"]: verdict(e, surface, cases) for e in entries}

    groups = {"behaviour": BEHAVIOUR_KINDS, "format fields": FIELD_KINDS}
    print(f"Swift public names: {len(surface)}, enum cases: {len(cases)}")
    print(f"Python entries marked direct: {len(entries)}")
    print()

    for label, kinds in groups.items():
        subset = [e for e in entries if e["kind"] in kinds]
        if not subset:
            continue
        tally = collections.Counter(verdicts[e["qualifiedName"]] for e in subset)
        intended = tally["covered"] + tally["pending"]
        share = 100 * tally["covered"] / intended if intended else 100.0
        print(
            f"{label:14} {tally['covered']:4}/{intended:4}  {share:5.1f}%"
            f"    declined {tally['declined']}"
        )
        if label in GROUP_NOTES:
            print(f"{'':14} {GROUP_NOTES[label]}")
        if args.missing:
            pending = sorted(
                e["qualifiedName"]
                for e in subset
                if verdicts[e["qualifiedName"]] == "pending"
            )
            # Grouped by module: a gap in `libtmux.common` is usually Python's
            # own plumbing, and a gap in `libtmux.server` usually is not.
            by_module: dict[str, list[str]] = {}
            for gap in pending:
                by_module.setdefault(module_of(gap), []).append(gap)
            for module, members in sorted(
                by_module.items(), key=lambda kv: -len(kv[1])
            ):
                print(f"    {module}  ({len(members)})")
                for member in members:
                    print(f"        {member.split('.', 2)[-1]}")
            print()

    other = [
        e
        for e in entries
        if e["kind"] not in BEHAVIOUR_KINDS and e["kind"] not in FIELD_KINDS
    ]
    if other:
        print(
            f"{'uncounted':14} {len(other):4}       kinds: "
            f"{sorted({e['kind'] for e in other})}"
        )

    named = sorted(
        {
            member_of(e["qualifiedName"])
            for e in entries
            if member_of(e["qualifiedName"]) in ANSWERED_DIFFERENTLY
        }
    )
    if named:
        print()
        print(f"answered by other means ({len(named)}):")
        for name in named:
            print(f"    {name:22} {ANSWERED_DIFFERENTLY[name]}")

    wholesale = sorted(
        {module_of(e["qualifiedName"]) for e in entries} & set(MODULE_ANSWERS)
    )
    if wholesale:
        print()
        print("answered a module at a time:")
        for module in wholesale:
            print(f"    {module:22} {MODULE_ANSWERS[module]}")

    refused = sorted(
        {
            member_of(e["qualifiedName"])
            for e in entries
            if verdicts[e["qualifiedName"]] == "declined"
        }
    )
    if refused:
        print()
        print(f"declined ({len(refused)}):")
        for name in refused:
            print(f"    {name:22} {DECLINED[name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
