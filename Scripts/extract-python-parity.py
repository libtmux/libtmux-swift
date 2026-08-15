#!/usr/bin/env python3
"""Extract source-backed Python parity manifests for the Swift port.

The extractor reads Python syntax first, then imports the same checkout to
verify exports, descriptors, fields, and inheritance. It never reads the Swift
design when deciding what Python exposes.

Examples
--------
>>> render_json({"schemaVersion": 1, "entries": []}).splitlines()[1]
'  "entries": [],'
>>> LIST_ERROR_FAMILY_IDS[0]
'list.server.sessions.any-error-empty'
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import dataclasses
import enum
import hashlib
import importlib
import importlib.util
import inspect
import json
import os
import pathlib
import re
import subprocess
import sys
import types
import typing as t

Json = dict[str, t.Any]

DOCUMENT_KIND = "libtmux.python-parity-manifest"
SCHEMA_VERSION = 1
DEFAULT_TMUX_VERSION = "3.2a"
#: The input fingerprint, kept beside the manifests it backs.
SOURCE_INPUTS = "source-inputs.json"
#: The Python package these manifests describe.
PACKAGE_NAME = "libtmux"
#: This package's own root, and the parity authorities it keeps.
PARITY_HOME = pathlib.Path(__file__).resolve().parents[1]
AUTHORITY_HOME = PARITY_HOME / "Scripts" / "parity"
#: The executable observation every inherited behaviour contract cites.
AUTHORITY_NODE = (
    "Scripts/parity/test_python_parity_behavior_contracts.py::"
    "test_inherited_behavior_contract_matches_observation"
)

LIST_ERROR_FAMILY_IDS: tuple[str, ...] = (
    "list.server.sessions.any-error-empty",
    "list.server.clients.any-error-empty",
    "list.server.attached-sessions.any-error-empty",
    "list.server.windows.daemon-unavailable-empty",
    "list.server.panes.daemon-unavailable-empty",
    "list.server.search-sessions.daemon-unavailable-empty",
    "list.server.search-windows.daemon-unavailable-empty",
    "list.server.search-panes.daemon-unavailable-empty",
    "list.session.windows.propagate",
    "list.session.panes.propagate",
    "list.session.search-windows.propagate",
    "list.session.search-panes.propagate",
    "list.window.panes.propagate",
    "list.window.search-panes.propagate",
    "list.window.linked-sessions.either-source-empty-deduplicated",
    "list.session.active-window.cardinality",
    "list.session.active-pane.optional",
    "list.predicate.server.malformed-empty",
    "list.predicate.session.malformed-empty",
    "list.predicate.window.malformed-empty",
    "list.cancellation.propagates",
    "list.liveness.is-alive",
    "list.liveness.require-alive",
    "list.strict-view.propagate",
)


def render_json(document: Json) -> str:
    """Render deterministic JSON with a final newline.

    Parameters
    ----------
    document : dict[str, object]
        JSON-compatible document.

    Returns
    -------
    str
        Stable, human-readable JSON.

    Examples
    --------
    >>> json.loads(render_json({"b": 2, "a": 1}))
    {'a': 1, 'b': 2}
    """
    return json.dumps(document, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _sha256(records: t.Iterable[tuple[str, bytes]]) -> str:
    """Hash sorted path-and-byte records with explicit boundaries.

    Parameters
    ----------
    records : t.Iterable[tuple[str, bytes]]
        Records used by this helper.

    Returns
    -------
    str
        Result produced by _sha256.

    Examples
    --------
    >>> _sha256([])
    'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
    """
    digest = hashlib.sha256()
    for path, data in sorted(records):
        digest.update(path.encode())
        digest.update(b"\0")
        digest.update(data)
        digest.update(b"\0")
    return f"sha256:{digest.hexdigest()}"


def _relative(repo_root: pathlib.Path, path: pathlib.Path) -> str:
    """Return a POSIX path relative to the repository.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    path : pathlib.Path
        Path used by this helper.

    Returns
    -------
    str
        Result produced by _relative.

    Examples
    --------
    >>> _relative(pathlib.Path("repo"), pathlib.Path("repo/src/module.py"))
    'src/module.py'
    """
    return path.resolve().relative_to(repo_root.resolve()).as_posix()


def _input_group(
    repo_root: pathlib.Path,
    family: str,
    paths: t.Iterable[pathlib.Path],
) -> Json:
    """Describe and fingerprint one authority-input family.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    family : str
        Family used by this helper.
    paths : t.Iterable[pathlib.Path]
        Paths used by this helper.

    Returns
    -------
    Json
        Result produced by _input_group.

    Examples
    --------
    >>> group = _input_group(pathlib.Path("."), "empty", [])
    >>> (group["authorityFamily"], group["inputCount"], group["paths"])
    ('empty', 0, [])
    """
    unique_paths = sorted({path.resolve() for path in paths if path.is_file()})
    records = [(_relative(repo_root, path), path.read_bytes()) for path in unique_paths]
    return {
        "authorityFamily": family,
        "byteCount": sum(len(data) for _, data in records),
        "fingerprint": _sha256(records),
        "inputCount": len(records),
        "paths": [path for path, _ in records],
    }


def fingerprint_authority_inputs(
    repo_root: pathlib.Path,
    *,
    package_name: str = "libtmux",
) -> Json:
    """Fingerprint each Python parity authority input separately.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repository root.
    package_name : str, optional
        Package directory below src.

    Returns
    -------
    dict[str, object]
        Relative input paths and content fingerprints.

    Examples
    --------
    >>> evidence = fingerprint_authority_inputs(pathlib.Path("."))
    >>> families = [entry["authorityFamily"] for entry in evidence["entries"]]
    >>> (len(families), families[0], families[-1])
    (5, 'package-exports', 'python-tests')
    """
    package_root = repo_root / "src" / package_name
    groups = [
        _input_group(repo_root, "python-source", package_root.rglob("*.py")),
        _input_group(
            repo_root,
            "package-exports",
            [package_root / "__init__.py"],
        ),
        _input_group(
            repo_root,
            "public-api-policy",
            [repo_root / "docs" / "project" / "public-api.md"],
        ),
        _input_group(
            repo_root,
            "project-metadata",
            [repo_root / "pyproject.toml"],
        ),
        _input_group(repo_root, "python-tests", (repo_root / "tests").rglob("*.py")),
    ]
    combined_records: list[tuple[str, bytes]] = []
    for group in groups:
        for relative_path in t.cast("list[str]", group["paths"]):
            path = repo_root / relative_path
            combined_records.append((relative_path, path.read_bytes()))
    return {
        "documentKind": "libtmux.python-parity-source-inputs",
        "schemaVersion": SCHEMA_VERSION,
        "sourceFingerprint": _sha256(combined_records),
        "entries": sorted(groups, key=lambda item: item["authorityFamily"]),
    }


def _public_source_files(
    repo_root: pathlib.Path,
    package_name: str,
) -> list[pathlib.Path]:
    """Return public module files while excluding internal package segments.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    package_name : str
        Package name used by this helper.

    Returns
    -------
    list[pathlib.Path]
        Result produced by _public_source_files.

    Examples
    --------
    >>> paths = _public_source_files(pathlib.Path("."), "libtmux")
    >>> all("_internal" not in path.parts for path in paths)
    True
    """
    package_root = repo_root / "src" / package_name
    public_files: list[pathlib.Path] = []
    for path in package_root.rglob("*.py"):
        relative_parts = path.relative_to(package_root).parts
        if any(
            part.startswith("_") and part != "__init__.py" for part in relative_parts
        ):
            continue
        public_files.append(path)
    return sorted(public_files)


def _module_name(
    package_root: pathlib.Path,
    path: pathlib.Path,
    package_name: str,
) -> str:
    """Convert a Python source path into its import name.

    Parameters
    ----------
    package_root : pathlib.Path
        Package root used by this helper.
    path : pathlib.Path
        Path used by this helper.
    package_name : str
        Package name used by this helper.

    Returns
    -------
    str
        Result produced by _module_name.

    Examples
    --------
    >>> package_root = pathlib.Path("src/libtmux")
    >>> _module_name(package_root, package_root / "server.py", "libtmux")
    'libtmux.server'
    """
    parts = list(path.relative_to(package_root).with_suffix("").parts)
    if parts[-1] == "__init__":
        parts.pop()
    return ".".join([package_name, *parts])


def _literal_strings(node: ast.AST) -> tuple[str, ...] | None:
    """Return a literal string sequence when a syntax node contains one.

    Parameters
    ----------
    node : ast.AST
        Node used by this helper.

    Returns
    -------
    tuple[str, ...] | None
        Result produced by _literal_strings.

    Examples
    --------
    >>> expression = ast.parse("('first', 'second')", mode="eval").body
    >>> _literal_strings(expression)
    ('first', 'second')
    """
    try:
        value = ast.literal_eval(node)
    except (ValueError, TypeError):
        return None
    if isinstance(value, (list, tuple)) and all(
        isinstance(item, str) for item in value
    ):
        return tuple(value)
    return None


def _explicit_all(tree: ast.Module) -> tuple[str, ...] | None:
    """Read a module's literal public export declaration.

    Parameters
    ----------
    tree : ast.Module
        Tree used by this helper.

    Returns
    -------
    tuple[str, ...] | None
        Result produced by _explicit_all.

    Examples
    --------
    >>> _explicit_all(ast.parse("__all__ = ('Public',)"))
    ('Public',)
    """
    for node in tree.body:
        value: ast.AST | None = None
        if (
            isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == "__all__"
                for target in node.targets
            )
        ) or (
            isinstance(node, ast.AnnAssign)
            and isinstance(node.target, ast.Name)
            and node.target.id == "__all__"
        ):
            value = node.value
        if value is not None:
            return _literal_strings(value)
    return None


def _is_public_name(name: str, explicit_all: tuple[str, ...] | None) -> bool:
    """Apply an explicit export list or the normal underscore rule.

    Parameters
    ----------
    name : str
        Name used by this helper.
    explicit_all : tuple[str, ...] | None
        Explicit all used by this helper.

    Returns
    -------
    bool
        Result produced by _is_public_name.

    Examples
    --------
    >>> (_is_public_name("public", None), _is_public_name("_private", None))
    (True, False)
    """
    if explicit_all is not None:
        return name in explicit_all
    return not name.startswith("_")


def _dotted_name(node: ast.expr) -> str:
    """Render a dotted callable or decorator name.

    Parameters
    ----------
    node : ast.expr
        Node used by this helper.

    Returns
    -------
    str
        Result produced by _dotted_name.

    Examples
    --------
    >>> _dotted_name(ast.parse("package.member", mode="eval").body)
    'package.member'
    """
    if isinstance(node, ast.Call):
        return _dotted_name(node.func)
    if isinstance(node, ast.Attribute):
        prefix = _dotted_name(node.value)
        return f"{prefix}.{node.attr}" if prefix else node.attr
    if isinstance(node, ast.Name):
        return node.id
    return ast.unparse(node)


def _signature(node: ast.FunctionDef | ast.AsyncFunctionDef) -> str:
    """Normalize a callable signature from source syntax.

    Parameters
    ----------
    node : ast.FunctionDef | ast.AsyncFunctionDef
        Node used by this helper.

    Returns
    -------
    str
        Result produced by _signature.

    Examples
    --------
    >>> node = ast.parse("def f(value: int) -> str: pass").body[0]
    >>> function = t.cast("ast.FunctionDef", node)
    >>> _signature(function)
    '(value: int) -> str'
    """
    signature = f"({ast.unparse(node.args)})"
    if node.returns is not None:
        signature += f" -> {ast.unparse(node.returns)}"
    return signature


def _version_predicates(node: ast.AST) -> list[Json]:
    """Collect literal minimum and raw-version predicates.

    Parameters
    ----------
    node : ast.AST
        Node used by this helper.

    Returns
    -------
    list[Json]
        Result produced by _version_predicates.

    Examples
    --------
    >>> _version_predicates(ast.parse("has_version('3.2a')"))
    [{'predicate': 'has_version', 'version': '3.2a'}]
    """
    predicates: set[tuple[str, str]] = set()
    version_functions = {
        "has_version",
        "has_gt_version",
        "has_gte_version",
        "has_lt_version",
        "has_lte_version",
        "has_minimum_version",
    }
    for child in ast.walk(node):
        if isinstance(child, ast.Call):
            name = _dotted_name(child.func).rsplit(".", 1)[-1]
            if name in version_functions and child.args:
                first = child.args[0]
                if isinstance(first, ast.Constant) and isinstance(first.value, str):
                    predicates.add((name, first.value))
        if not isinstance(child, ast.Compare) or len(child.comparators) != 1:
            continue
        sides = (child.left, child.comparators[0])
        raw_call = next(
            (
                side
                for side in sides
                if isinstance(side, ast.Call)
                and _dotted_name(side.func).endswith("get_version_str")
            ),
            None,
        )
        literal = next(
            (
                side.value
                for side in sides
                if isinstance(side, ast.Constant) and isinstance(side.value, str)
            ),
            None,
        )
        if raw_call is not None and literal is not None:
            predicates.add(("raw-version-equality", literal))
    return [
        {"predicate": predicate, "version": version}
        for predicate, version in sorted(predicates)
    ]


def _deprecations(node: ast.AST) -> list[Json]:
    """Collect deprecation directives and DeprecatedError versions.

    Parameters
    ----------
    node : ast.AST
        Node used by this helper.

    Returns
    -------
    list[Json]
        Result produced by _deprecations.

    Examples
    --------
    >>> source = "def old(): raise DeprecatedError(version='1.0')"
    >>> function = t.cast("ast.FunctionDef", ast.parse(source).body[0])
    >>> _deprecations(function)
    [{'marker': 'exception', 'version': '1.0'}]
    """
    markers: set[tuple[str, str]] = set()
    documented_node = t.cast(
        "ast.Module | ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef",
        node,
    )
    docstring = (
        ast.get_docstring(documented_node, clean=False)
        if isinstance(
            node,
            (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef),
        )
        else None
    )
    if docstring:
        for version in re.findall(r"\.\. deprecated::\s*([^\s]+)", docstring):
            markers.add(("directive", version))

    def local_walk(current: ast.AST) -> t.Iterator[ast.AST]:
        yield current
        for child in ast.iter_child_nodes(current):
            if child is not node and isinstance(
                child,
                (ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda),
            ):
                continue
            yield from local_walk(child)

    for child in local_walk(node):
        if not isinstance(child, ast.Call):
            continue
        if not _dotted_name(child.func).endswith("DeprecatedError"):
            continue
        for keyword in child.keywords:
            if (
                keyword.arg == "version"
                and isinstance(keyword.value, ast.Constant)
                and isinstance(keyword.value.value, str)
            ):
                markers.add(("exception", keyword.value.value))
    return [
        {"marker": marker, "version": version} for marker, version in sorted(markers)
    ]


def _collect_test_nodes(repo_root: pathlib.Path) -> set[str]:
    """Collect stable function-level pytest node IDs from syntax.

    Reads the libtmux checkout's own suite and this port's parity authorities
    together. The authorities are the executable evidence a contract cites, and
    they live here rather than upstream, so a contract would otherwise cite a
    node no tree being read contains.

    Parameters
    ----------
    repo_root : pathlib.Path
        Root of the libtmux checkout being described.

    Returns
    -------
    set[str]
        Node IDs, each relative to the tree that holds it.

    Examples
    --------
    >>> nodes = _collect_test_nodes(pathlib.Path("/nonexistent"))
    >>> AUTHORITY_NODE in nodes
    True
    """
    nodes: set[str] = set()
    roots = [(repo_root, repo_root / "tests"), (PARITY_HOME, AUTHORITY_HOME)]
    for base, directory in roots:
        nodes |= _nodes_under(base, directory)
    return nodes


def _nodes_under(base: pathlib.Path, directory: pathlib.Path) -> set[str]:
    """Collect pytest node IDs from one directory, named relative to a base.

    Parameters
    ----------
    base : pathlib.Path
        Root that node IDs are spelled relative to.
    directory : pathlib.Path
        Directory to walk.

    Returns
    -------
    set[str]
        Node IDs found beneath `directory`.

    Examples
    --------
    >>> _nodes_under(pathlib.Path("/nonexistent"), pathlib.Path("/nonexistent"))
    set()
    """
    nodes: set[str] = set()
    for path in sorted(directory.rglob("*.py")):
        tree = ast.parse(path.read_bytes(), filename=str(path))
        relative = _relative(base, path)
        for node in tree.body:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if node.name.startswith("test_"):
                    nodes.add(f"{relative}::{node.name}")
            elif isinstance(node, ast.ClassDef) and node.name.startswith("Test"):
                for child in node.body:
                    if isinstance(
                        child, (ast.FunctionDef, ast.AsyncFunctionDef)
                    ) and child.name.startswith("test_"):
                        nodes.add(f"{relative}::{node.name}::{child.name}")
    return nodes


def _focused_tests(
    qualified_name: str,
    test_nodes: set[str],
    *,
    limit: int = 8,
) -> list[str]:
    """Associate focused tests by stable symbol vocabulary.

    Parameters
    ----------
    qualified_name : str
        Qualified name used by this helper.
    test_nodes : set[str]
        Test nodes used by this helper.
    limit : int
        Limit used by this helper.

    Returns
    -------
    list[str]
        Result produced by _focused_tests.

    Examples
    --------
    >>> tests = {"tests/test_widget.py::test_refresh"}
    >>> tests.add("tests/test_other.py::test_value")
    >>> _focused_tests("sample.Widget.refresh", tests)
    ['tests/test_widget.py::test_refresh']
    """
    leaf = qualified_name.rsplit(".", 1)[-1].lower().replace("-", "_")
    if leaf.startswith("__") and leaf.endswith("__"):
        return []
    return [node for node in sorted(test_nodes) if leaf in node.lower()][:limit]


def _resolve_reexport(
    module_name: str,
    is_package: bool,
    node: ast.ImportFrom,
    imported_name: str,
) -> str:
    """Resolve a relative import to a qualified target name.

    Parameters
    ----------
    module_name : str
        Module name used by this helper.
    is_package : bool
        Is package used by this helper.
    node : ast.ImportFrom
        Node used by this helper.
    imported_name : str
        Imported name used by this helper.

    Returns
    -------
    str
        Result produced by _resolve_reexport.

    Examples
    --------
    >>> imported = t.cast("ast.ImportFrom", ast.parse("from .api import Item").body[0])
    >>> _resolve_reexport("sample", True, imported, "Item")
    'sample.api.Item'
    """
    context = module_name if is_package else module_name.rsplit(".", 1)[0]
    if node.level:
        prefix = "." * node.level + (node.module or "")
        target_module = importlib.util.resolve_name(prefix, context)
    else:
        target_module = node.module or ""
    return f"{target_module}.{imported_name}"


def _base_entry(
    qualified_name: str,
    kind: str,
    source_file: str,
    test_nodes: set[str],
) -> Json:
    """Create the fields shared by public inventory entries.

    Parameters
    ----------
    qualified_name : str
        Qualified name used by this helper.
    kind : str
        Kind used by this helper.
    source_file : str
        Source file used by this helper.
    test_nodes : set[str]
        Test nodes used by this helper.

    Returns
    -------
    Json
        Result produced by _base_entry.

    Examples
    --------
    >>> _base_entry("sample.value", "constant", "src/sample.py", set())["qualifiedName"]
    'sample.value'
    """
    return {
        "behaviorFamilyId": "public.surface",
        "deprecations": [],
        "disposition": "direct",
        "formatFields": [],
        "kind": kind,
        "pythonTestNodes": _focused_tests(qualified_name, test_nodes),
        "qualifiedName": qualified_name,
        "sourceFile": source_file,
        "versionPredicates": [],
    }


def _record_class_members(
    node: ast.ClassDef,
    qualified_name: str,
    source_file: str,
    test_nodes: set[str],
    entries: dict[str, Json],
) -> None:
    """Record source-defined public methods and their overloads.

    Parameters
    ----------
    node : ast.ClassDef
        Node used by this helper.
    qualified_name : str
        Qualified name used by this helper.
    source_file : str
        Source file used by this helper.
    test_nodes : set[str]
        Test nodes used by this helper.
    entries : dict[str, Json]
        Entries used by this helper.

    Examples
    --------
    >>> source = "class Item:" + chr(10) + "    def visible(self): pass"
    >>> item = t.cast("ast.ClassDef", ast.parse(source).body[0])
    >>> members = {}
    >>> _record_class_members(item, "sample.Item", "src/sample.py", set(), members)
    >>> sorted(members)
    ['sample.Item.visible']
    """
    overloads: dict[str, list[str]] = {}
    for child in node.body:
        if not isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if child.name.startswith("_"):
            continue
        member_name = f"{qualified_name}.{child.name}"
        decorators = {_dotted_name(item) for item in child.decorator_list}
        if decorators & {"overload", "t.overload", "typing.overload"}:
            overloads.setdefault(member_name, []).append(_signature(child))
            continue
        kind = "method"
        if "property" in decorators or any(
            decorator.endswith((".setter", ".deleter")) for decorator in decorators
        ):
            kind = "property"
        elif "classmethod" in decorators:
            kind = "class-method"
        elif "staticmethod" in decorators:
            kind = "static-method"
        entry = _base_entry(member_name, kind, source_file, test_nodes)
        entry["signature"] = _signature(child)
        entry["overloadSignatures"] = sorted(overloads.pop(member_name, []))
        entry["versionPredicates"] = _version_predicates(child)
        entry["deprecations"] = _deprecations(child)
        entry["definedBy"] = qualified_name
        entries[member_name] = entry


def _assignment_names(node: ast.stmt) -> list[str]:
    """Return simple names assigned by a module statement.

    Parameters
    ----------
    node : ast.stmt
        Node used by this helper.

    Returns
    -------
    list[str]
        Result produced by _assignment_names.

    Examples
    --------
    >>> _assignment_names(ast.parse("left = right = 1").body[0])
    ['left', 'right']
    """
    if isinstance(node, ast.Assign):
        return [target.id for target in node.targets if isinstance(target, ast.Name)]
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        return [node.target.id]
    return []


def _module_aliases(
    module_name: str,
    is_package: bool,
    tree: ast.Module,
) -> dict[str, str]:
    """Resolve source import aliases without importing the package.

    Parameters
    ----------
    module_name : str
        Module name used by this helper.
    is_package : bool
        Is package used by this helper.
    tree : ast.Module
        Tree used by this helper.

    Returns
    -------
    dict[str, str]
        Result produced by _module_aliases.

    Examples
    --------
    >>> _module_aliases("sample", True, ast.parse("from .api import Item"))
    {'Item': 'sample.api.Item'}
    """
    aliases: dict[str, str] = {}
    for node in tree.body:
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                aliases[alias.asname or alias.name] = _resolve_reexport(
                    module_name,
                    is_package,
                    node,
                    alias.name,
                )
        elif isinstance(node, ast.Import):
            for alias in node.names:
                aliases[alias.asname or alias.name.split(".", 1)[0]] = alias.name
    return aliases


def _resolve_source_name(
    node: ast.expr,
    module_name: str,
    aliases: dict[str, dict[str, str]],
    class_nodes: dict[str, ast.ClassDef],
) -> str:
    """Resolve a source expression to a stable qualified name.

    Parameters
    ----------
    node : ast.expr
        Node used by this helper.
    module_name : str
        Module name used by this helper.
    aliases : dict[str, dict[str, str]]
        Aliases used by this helper.
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.

    Returns
    -------
    str
        Result produced by _resolve_source_name.

    Examples
    --------
    >>> name = ast.parse("Alias", mode="eval").body
    >>> aliases = {"sample": {"Alias": "sample.api.Item"}}
    >>> _resolve_source_name(name, "sample", aliases, {})
    'sample.api.Item'
    """
    rendered = ast.unparse(node)
    parts = rendered.split(".")
    imported = aliases.get(module_name, {}).get(parts[0])
    if imported is not None:
        return ".".join([imported, *parts[1:]])
    local = f"{module_name}.{rendered}"
    if local in class_nodes:
        return local
    if rendered in {"object", "Exception", "BaseException", "ValueError"}:
        return f"builtins.{rendered}"
    return rendered


def _class_decorated_as(node: ast.ClassDef, suffix: str) -> bool:
    """Return whether a class has a decorator with the requested suffix.

    Parameters
    ----------
    node : ast.ClassDef
        Node used by this helper.
    suffix : str
        Suffix used by this helper.

    Returns
    -------
    bool
        Result produced by _class_decorated_as.

    Examples
    --------
    >>> source = "@dataclasses.dataclass" + chr(10) + "class Item: pass"
    >>> item = t.cast("ast.ClassDef", ast.parse(source).body[0])
    >>> _class_decorated_as(item, "dataclass")
    True
    """
    return any(
        _dotted_name(decorator).endswith(suffix) for decorator in node.decorator_list
    )


def _direct_source_bases(
    class_nodes: dict[str, ast.ClassDef],
    aliases: dict[str, dict[str, str]],
) -> dict[str, list[str]]:
    """Resolve each source class's declared bases.

    Parameters
    ----------
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.
    aliases : dict[str, dict[str, str]]
        Aliases used by this helper.

    Returns
    -------
    dict[str, list[str]]
        Result produced by _direct_source_bases.

    Examples
    --------
    >>> child = t.cast("ast.ClassDef", ast.parse("class Child(Base): pass").body[0])
    >>> aliases = {"sample": {"Base": "sample.Base"}}
    >>> _direct_source_bases({"sample.Child": child}, aliases)
    {'sample.Child': ['sample.Base']}
    """
    return {
        qualified_name: [
            _resolve_source_name(
                base, qualified_name.rsplit(".", 1)[0], aliases, class_nodes
            )
            for base in node.bases
        ]
        for qualified_name, node in class_nodes.items()
    }


def _source_mro(
    qualified_name: str,
    direct_bases: dict[str, list[str]],
    cache: dict[str, list[str]],
) -> list[str]:
    """Compute a source-derived C3 linearization for one class.

    Parameters
    ----------
    qualified_name : str
        Qualified name used by this helper.
    direct_bases : dict[str, list[str]]
        Direct bases used by this helper.
    cache : dict[str, list[str]]
        Cache used by this helper.

    Returns
    -------
    list[str]
        Result produced by _source_mro.

    Examples
    --------
    >>> bases = {"sample.Base": [], "sample.Child": ["sample.Base"]}
    >>> _source_mro("sample.Child", bases, {})
    ['sample.Child', 'sample.Base', 'builtins.object']
    """
    if qualified_name in cache:
        return cache[qualified_name]
    bases = direct_bases.get(qualified_name, [])
    if not bases:
        result = [qualified_name, "builtins.object"]
        cache[qualified_name] = result
        return result
    sequences = [
        list(_source_mro(base, direct_bases, cache))
        if base in direct_bases
        else [base, "builtins.object"]
        for base in bases
    ]
    sequences.append(list(bases))
    merged: list[str] = []
    while any(sequences):
        sequences = [sequence for sequence in sequences if sequence]
        candidate = next(
            (
                sequence[0]
                for sequence in sequences
                if all(sequence[0] not in other[1:] for other in sequences)
            ),
            None,
        )
        if candidate is None:
            msg = f"inconsistent source MRO for {qualified_name}"
            raise ValueError(msg)
        merged.append(candidate)
        for sequence in sequences:
            if sequence and sequence[0] == candidate:
                sequence.pop(0)
    result = [qualified_name, *dict.fromkeys(merged)]
    cache[qualified_name] = result
    return result


def _source_class_trait(
    qualified_name: str,
    class_nodes: dict[str, ast.ClassDef],
    direct_bases: dict[str, list[str]],
    trait: str,
    seen: set[str] | None = None,
) -> bool:
    """Determine a class trait from decorators and source base declarations.

    Parameters
    ----------
    qualified_name : str
        Qualified name used by this helper.
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.
    direct_bases : dict[str, list[str]]
        Direct bases used by this helper.
    trait : str
        Trait used by this helper.
    seen : set[str] | None
        Seen used by this helper.

    Returns
    -------
    bool
        Result produced by _source_class_trait.

    Examples
    --------
    >>> source = "@dataclasses.dataclass" + chr(10) + "class Item: pass"
    >>> item = t.cast("ast.ClassDef", ast.parse(source).body[0])
    >>> nodes, bases = {"sample.Item": item}, {"sample.Item": []}
    >>> _source_class_trait("sample.Item", nodes, bases, "dataclass")
    True
    """
    seen = set() if seen is None else seen
    if qualified_name in seen:
        return False
    seen.add(qualified_name)
    node = class_nodes[qualified_name]
    bases = direct_bases[qualified_name]
    if trait == "dataclass" and _class_decorated_as(node, "dataclass"):
        return True
    suffixes = {
        "dataclass": (),
        "enum": (".Enum",),
        "exception": ("Exception", "Error"),
        "named-tuple": (".NamedTuple", "NamedTuple"),
    }[trait]
    if any(base.endswith(suffixes) for base in bases):
        return True
    return any(
        base in class_nodes
        and _source_class_trait(
            base,
            class_nodes,
            direct_bases,
            trait,
            seen,
        )
        for base in bases
    )


def _assignment_value(node: ast.Assign | ast.AnnAssign) -> ast.expr | None:
    """Return the value assigned by a class assignment.

    Parameters
    ----------
    node : ast.Assign | ast.AnnAssign
        Node used by this helper.

    Returns
    -------
    ast.expr | None
        Result produced by _assignment_value.

    Examples
    --------
    >>> assignment = t.cast("ast.Assign", ast.parse("value = 3").body[0])
    >>> ast.unparse(_assignment_value(assignment))
    '3'
    """
    return node.value


def _descriptor_assignment(
    value: ast.expr | None,
    module_name: str,
    aliases: dict[str, dict[str, str]],
    class_nodes: dict[str, ast.ClassDef],
) -> bool:
    """Identify a source-declared descriptor constructor.

    Parameters
    ----------
    value : ast.expr | None
        Value used by this helper.
    module_name : str
        Module name used by this helper.
    aliases : dict[str, dict[str, str]]
        Aliases used by this helper.
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.

    Returns
    -------
    bool
        Result produced by _descriptor_assignment.

    Examples
    --------
    >>> source = "class Marker:" + chr(10) + "    def __get__(self, x, y): pass"
    >>> marker = t.cast("ast.ClassDef", ast.parse(source).body[0])
    >>> value = t.cast("ast.Call", ast.parse("Marker()", mode="eval").body)
    >>> classes = {"sample.Marker": marker}
    >>> _descriptor_assignment(value, "sample", {"sample": {}}, classes)
    True
    """
    if not isinstance(value, ast.Call):
        return False
    target = _resolve_source_name(value.func, module_name, aliases, class_nodes)
    descriptor = class_nodes.get(target)
    return descriptor is not None and any(
        isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
        and child.name == "__get__"
        for child in descriptor.body
    )


def _record_ast_class_assignments(
    qualified_name: str,
    node: ast.ClassDef,
    entries: dict[str, Json],
    class_nodes: dict[str, ast.ClassDef],
    aliases: dict[str, dict[str, str]],
    direct_bases: dict[str, list[str]],
    test_nodes: set[str],
) -> None:
    """Record source-declared fields, descriptors, attributes, and enum members.

    Parameters
    ----------
    qualified_name : str
        Qualified name used by this helper.
    node : ast.ClassDef
        Node used by this helper.
    entries : dict[str, Json]
        Entries used by this helper.
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.
    aliases : dict[str, dict[str, str]]
        Aliases used by this helper.
    direct_bases : dict[str, list[str]]
        Direct bases used by this helper.
    test_nodes : set[str]
        Test nodes used by this helper.

    Examples
    --------
    >>> source = "@dataclasses.dataclass" + chr(10) + "class Item:"
    >>> source += chr(10) + "    value: int = 1"
    >>> item = t.cast("ast.ClassDef", ast.parse(source).body[0])
    >>> entries = {"sample.Item": {"sourceFile": "src/sample.py"}}
    >>> classes, aliases = {"sample.Item": item}, {"sample": {}}
    >>> _record_ast_class_assignments(
    ...     "sample.Item", item, entries, classes, aliases, {"sample.Item": []}, set()
    ... )
    >>> entries["sample.Item.value"]["kind"]
    'dataclass-field'
    """
    source_file = t.cast("str", entries[qualified_name]["sourceFile"])
    module_name = qualified_name.rsplit(".", 1)[0]
    is_dataclass = _source_class_trait(
        qualified_name, class_nodes, direct_bases, "dataclass"
    )
    is_named_tuple = _source_class_trait(
        qualified_name, class_nodes, direct_bases, "named-tuple"
    )
    is_enum = _source_class_trait(qualified_name, class_nodes, direct_bases, "enum")
    for child in node.body:
        names = _assignment_names(child)
        if not names or not isinstance(child, (ast.Assign, ast.AnnAssign)):
            continue
        for name in names:
            if name.startswith("_"):
                continue
            kind = "class-attribute"
            if is_named_tuple and isinstance(child, ast.AnnAssign):
                kind = "named-tuple-field"
            elif is_dataclass and isinstance(child, ast.AnnAssign):
                kind = "dataclass-field"
            elif is_enum:
                kind = "enum-member"
            elif _descriptor_assignment(
                _assignment_value(child),
                module_name,
                aliases,
                class_nodes,
            ):
                kind = "descriptor"
            member_name = f"{qualified_name}.{name}"
            entry = _base_entry(member_name, kind, source_file, test_nodes)
            entry["definedBy"] = qualified_name
            if isinstance(child, ast.AnnAssign):
                entry["fieldType"] = ast.unparse(child.annotation)
            if kind == "enum-member" and child.value is not None:
                try:
                    entry["value"] = repr(ast.literal_eval(child.value))
                except (ValueError, TypeError):
                    entry["value"] = ast.unparse(child.value)
            entries[member_name] = entry


def _source_init_signature(node: ast.FunctionDef | ast.AsyncFunctionDef) -> str:
    """Render a class-call signature from a source ``__init__`` method.

    Parameters
    ----------
    node : ast.FunctionDef | ast.AsyncFunctionDef
        Source initializer whose receiver parameter is omitted.

    Returns
    -------
    str
        Source-normalized class-call signature.

    Examples
    --------
    >>> init = ast.parse("def __init__(self, value: int = 1) -> None: pass").body[0]
    >>> _source_init_signature(t.cast("ast.FunctionDef", init))
    '(value: int=1) -> None'
    """
    positional = [*node.args.posonlyargs, *node.args.args]
    if positional:
        positional = positional[1:]
    posonly_count = max(0, len(node.args.posonlyargs) - 1)
    arguments = ast.arguments(
        posonlyargs=positional[:posonly_count],
        args=positional[posonly_count:],
        vararg=node.args.vararg,
        kwonlyargs=node.args.kwonlyargs,
        kw_defaults=node.args.kw_defaults,
        kwarg=node.args.kwarg,
        defaults=node.args.defaults,
    )
    signature = f"({ast.unparse(arguments)})"
    if node.returns is not None:
        signature += f" -> {ast.unparse(node.returns)}"
    return signature


def _source_class_signature(
    qualified_name: str,
    class_nodes: dict[str, ast.ClassDef],
    direct_bases: dict[str, list[str]],
    mro_cache: dict[str, list[str]],
) -> str:
    """Derive a class-call signature entirely from source syntax.

    Parameters
    ----------
    qualified_name : str
        Qualified source class.
    class_nodes : dict[str, ast.ClassDef]
        Source class declarations.
    direct_bases : dict[str, list[str]]
        Resolved direct source bases.
    mro_cache : dict[str, list[str]]
        Source MRO cache.

    Returns
    -------
    str
        Source-normalized class-call signature.

    Examples
    --------
    >>> source = "class Item:" + chr(10) + "    def __init__(self, value: int): pass"
    >>> node = t.cast("ast.ClassDef", ast.parse(source).body[0])
    >>> classes, bases = {"sample.Item": node}, {"sample.Item": []}
    >>> _source_class_signature("sample.Item", classes, bases, {})
    '(value: int)'
    """
    mro = _source_mro(qualified_name, direct_bases, mro_cache)
    node = class_nodes[qualified_name]
    initializer = next(
        (
            child
            for child in node.body
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
            and child.name == "__init__"
        ),
        None,
    )
    if initializer is not None:
        return _source_init_signature(initializer)

    if _source_class_trait(qualified_name, class_nodes, direct_bases, "named-tuple"):
        parameters = [
            f"{child.target.id}: {ast.unparse(child.annotation)}"
            + (f" = {ast.unparse(child.value)}" if child.value is not None else "")
            for child in node.body
            if isinstance(child, ast.AnnAssign)
            and isinstance(child.target, ast.Name)
            and not child.target.id.startswith("_")
        ]
        return f"({', '.join(parameters)})"
    if _source_class_trait(qualified_name, class_nodes, direct_bases, "dataclass"):
        fields: dict[str, str] = {}
        for owner in reversed(mro):
            owner_node = class_nodes.get(owner)
            if owner_node is None or not _source_class_trait(
                owner,
                class_nodes,
                direct_bases,
                "dataclass",
            ):
                continue
            for child in owner_node.body:
                if not isinstance(child, ast.AnnAssign) or not isinstance(
                    child.target, ast.Name
                ):
                    continue
                if child.target.id.startswith("_"):
                    continue
                parameter = f"{child.target.id}: {ast.unparse(child.annotation)}"
                if child.value is not None:
                    parameter += f" = {ast.unparse(child.value)}"
                fields[child.target.id] = parameter
        return f"({', '.join(fields.values())}) -> None"
    if _source_class_trait(qualified_name, class_nodes, direct_bases, "enum"):
        return "(*values)"
    if any(base.endswith("Protocol") for base in direct_bases[qualified_name]):
        return "(*args, **kwargs)"
    for owner in mro[1:]:
        owner_node = class_nodes.get(owner)
        if owner_node is None:
            continue
        initializer = next(
            (
                child
                for child in owner_node.body
                if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef))
                and child.name == "__init__"
            ),
            None,
        )
        if initializer is not None:
            return _source_init_signature(initializer)
    return "()"


def _complete_ast_class_surfaces(
    entries: dict[str, Json],
    class_nodes: dict[str, ast.ClassDef],
    aliases: dict[str, dict[str, str]],
    test_nodes: set[str],
) -> None:
    """Expand source-defined and effective inherited class surfaces.

    Parameters
    ----------
    entries : dict[str, Json]
        Entries used by this helper.
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.
    aliases : dict[str, dict[str, str]]
        Aliases used by this helper.
    test_nodes : set[str]
        Test nodes used by this helper.

    Examples
    --------
    >>> item = t.cast("ast.ClassDef", ast.parse("class Item: pass").body[0])
    >>> entry = _base_entry("sample.Item", "class", "src/sample.py", set())
    >>> entries = {"sample.Item": entry}
    >>> _complete_ast_class_surfaces(
    ...     entries, {"sample.Item": item}, {"sample": {}}, set()
    ... )
    >>> entries["sample.Item"]["signature"]
    '()'
    """
    direct_bases = _direct_source_bases(class_nodes, aliases)
    for qualified_name, node in class_nodes.items():
        _record_ast_class_assignments(
            qualified_name,
            node,
            entries,
            class_nodes,
            aliases,
            direct_bases,
            test_nodes,
        )
    mro_cache: dict[str, list[str]] = {}
    for qualified_name in class_nodes:
        class_entry = entries[qualified_name]
        class_entry["signature"] = _source_class_signature(
            qualified_name,
            class_nodes,
            direct_bases,
            mro_cache,
        )
        class_entry["declaredBaseClasses"] = direct_bases[qualified_name]
        class_entry["baseClasses"] = _source_mro(
            qualified_name,
            direct_bases,
            mro_cache,
        )[1:]
        if _source_class_trait(qualified_name, class_nodes, direct_bases, "exception"):
            class_entry["kind"] = "exception"
        direct_members = sorted(
            (
                entry
                for name, entry in entries.items()
                if name.startswith(f"{qualified_name}.")
                and "." not in name[len(qualified_name) + 1 :]
                and entry.get("definedBy") == qualified_name
            ),
            key=lambda item: item["qualifiedName"],
        )
        class_entry["definedMembers"] = [
            {
                "definedBy": qualified_name,
                "kind": entry["kind"],
                "name": t.cast("str", entry["qualifiedName"]).rsplit(".", 1)[-1],
            }
            for entry in direct_members
        ]
    for qualified_name in class_nodes:
        class_entry = entries[qualified_name]
        class_entry["declaredBaseClasses"] = direct_bases[qualified_name]
        class_entry["baseClasses"] = _source_mro(
            qualified_name,
            direct_bases,
            mro_cache,
        )[1:]
        if _source_class_trait(qualified_name, class_nodes, direct_bases, "exception"):
            class_entry["kind"] = "exception"
        direct_members = sorted(
            (
                entry
                for name, entry in entries.items()
                if name.startswith(f"{qualified_name}.")
                and "." not in name[len(qualified_name) + 1 :]
                and entry.get("definedBy") == qualified_name
            ),
            key=lambda item: item["qualifiedName"],
        )
        defined_names = {
            t.cast("str", entry["qualifiedName"]).rsplit(".", 1)[-1]
            for entry in direct_members
        }
        class_entry["definedMembers"] = [
            {
                "definedBy": qualified_name,
                "kind": entry["kind"],
                "name": t.cast("str", entry["qualifiedName"]).rsplit(".", 1)[-1],
            }
            for entry in direct_members
        ]
        inherited: list[Json] = []
        for base in t.cast("list[str]", class_entry["baseClasses"]):
            if base not in class_nodes:
                continue
            for row in t.cast("list[Json]", entries[base]["definedMembers"]):
                name = t.cast("str", row["name"])
                if name in defined_names:
                    continue
                defined_names.add(name)
                source_entry = entries[f"{base}.{name}"]
                inherited_kind = f"inherited-{source_entry['kind']}"
                inherited.append(
                    {
                        "definedBy": source_entry["definedBy"],
                        "kind": inherited_kind,
                        "name": name,
                    }
                )
                member = dict(source_entry)
                member.update(
                    {
                        "kind": inherited_kind,
                        "pythonTestNodes": _focused_tests(
                            f"{qualified_name}.{name}", test_nodes
                        ),
                        "qualifiedName": f"{qualified_name}.{name}",
                    }
                )
                entries[t.cast("str", member["qualifiedName"])] = member
        class_entry["inheritedMembers"] = inherited
        field_kinds = {"dataclass-field", "named-tuple-field"}
        class_entry["fields"] = sorted(
            [
                {
                    "definedBy": entry["definedBy"],
                    "kind": t.cast("str", entry["kind"]).removeprefix("inherited-"),
                    "name": t.cast("str", entry["qualifiedName"]).rsplit(".", 1)[-1],
                }
                for entry in [
                    *direct_members,
                    *(entries[f"{qualified_name}.{row['name']}"] for row in inherited),
                ]
                if t.cast("str", entry["kind"]).removeprefix("inherited-")
                in field_kinds
            ],
            key=lambda item: item["name"],
        )
        class_entry["enumMembers"] = sorted(
            t.cast("str", entry["qualifiedName"]).rsplit(".", 1)[-1]
            for entry in direct_members
            if entry["kind"] == "enum-member"
        )


def _ast_public_entries(
    repo_root: pathlib.Path,
    package_name: str,
    test_nodes: set[str],
) -> tuple[dict[str, Json], dict[str, ast.ClassDef]]:
    """Extract public declarations from source syntax.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    package_name : str
        Package name used by this helper.
    test_nodes : set[str]
        Test nodes used by this helper.

    Returns
    -------
    tuple[dict[str, Json], dict[str, ast.ClassDef]]
        Result produced by _ast_public_entries.

    Examples
    --------
    >>> entries, classes = _ast_public_entries(pathlib.Path("."), "libtmux", set())
    >>> ("libtmux.server.Server" in entries, "libtmux.server.Server" in classes)
    (True, True)
    """
    package_root = repo_root / "src" / package_name
    entries: dict[str, Json] = {}
    class_nodes: dict[str, ast.ClassDef] = {}
    aliases: dict[str, dict[str, str]] = {}
    for path in _public_source_files(repo_root, package_name):
        tree = ast.parse(path.read_bytes(), filename=str(path))
        module_name = _module_name(package_root, path, package_name)
        source_file = _relative(repo_root, path)
        explicit_all = _explicit_all(tree)
        aliases[module_name] = _module_aliases(
            module_name,
            path.name == "__init__.py",
            tree,
        )
        module_entry = _base_entry(module_name, "module", source_file, test_nodes)
        module_entry["exports"] = sorted(explicit_all or ())
        entries[module_name] = module_entry
        overloads: dict[str, list[str]] = {}

        for node in tree.body:
            if isinstance(node, ast.ImportFrom) and explicit_all is not None:
                for alias in node.names:
                    exported_name = alias.asname or alias.name
                    if exported_name not in explicit_all:
                        continue
                    name = f"{module_name}.{exported_name}"
                    entry = _base_entry(name, "re-export", source_file, test_nodes)
                    entry["targetQualifiedName"] = _resolve_reexport(
                        module_name,
                        path.name == "__init__.py",
                        node,
                        alias.name,
                    )
                    entries[name] = entry
                continue

            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                if not _is_public_name(node.name, explicit_all):
                    continue
                name = f"{module_name}.{node.name}"
                decorators = {_dotted_name(item) for item in node.decorator_list}
                if decorators & {"overload", "t.overload", "typing.overload"}:
                    overloads.setdefault(name, []).append(_signature(node))
                    continue
                entry = _base_entry(name, "function", source_file, test_nodes)
                entry["signature"] = _signature(node)
                entry["overloadSignatures"] = sorted(overloads.pop(name, []))
                entry["versionPredicates"] = _version_predicates(node)
                entry["deprecations"] = _deprecations(node)
                entries[name] = entry
                continue

            if isinstance(node, ast.ClassDef):
                if not _is_public_name(node.name, explicit_all):
                    continue
                name = f"{module_name}.{node.name}"
                entry = _base_entry(name, "class", source_file, test_nodes)
                entry.update(
                    {
                        "baseClasses": [ast.unparse(base) for base in node.bases],
                        "definedMembers": [],
                        "enumMembers": [],
                        "fields": [],
                        "inheritedMembers": [],
                        "signature": None,
                    }
                )
                entry["versionPredicates"] = _version_predicates(node)
                entry["deprecations"] = _deprecations(node)
                entries[name] = entry
                class_nodes[name] = node
                _record_class_members(node, name, source_file, test_nodes, entries)
                continue

            for assignment_name in _assignment_names(node):
                if assignment_name == "__all__":
                    continue
                if not _is_public_name(assignment_name, explicit_all):
                    continue
                if explicit_all is None and not assignment_name.isupper():
                    continue
                name = f"{module_name}.{assignment_name}"
                entries[name] = _base_entry(
                    name,
                    "constant",
                    source_file,
                    test_nodes,
                )
    _complete_ast_class_surfaces(entries, class_nodes, aliases, test_nodes)
    return entries, class_nodes


@contextlib.contextmanager
def _import_modules(
    repo_root: pathlib.Path,
    package_name: str,
    module_names: t.Iterable[str],
) -> t.Iterator[dict[str, types.ModuleType]]:
    """Import modules from the requested checkout and restore import state.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    package_name : str
        Package name used by this helper.
    module_names : t.Iterable[str]
        Module names used by this helper.

    Returns
    -------
    t.Iterator[dict[str, types.ModuleType]]
        Result produced by _import_modules.

    Examples
    --------
    >>> requested = ["libtmux.constants"]
    >>> with _import_modules(pathlib.Path("."), "libtmux", requested) as modules:
    ...     sorted(modules)
    ['libtmux.constants']
    """
    source_root = str((repo_root / "src").resolve())
    existing_package = sys.modules.get(package_name)
    purge = existing_package is None or not str(
        getattr(existing_package, "__file__", "")
    ).startswith(source_root)
    saved = {
        name: module
        for name, module in sys.modules.items()
        if name == package_name or name.startswith(f"{package_name}.")
    }
    if purge:
        for name in saved:
            sys.modules.pop(name, None)
    sys.path.insert(0, source_root)
    try:
        imported = {
            name: importlib.import_module(name)
            for name in sorted(
                set(module_names), key=lambda item: (item.count("."), item)
            )
        }
        yield imported
    finally:
        sys.path.remove(source_root)
        if purge:
            for name in list(sys.modules):
                if name == package_name or name.startswith(f"{package_name}."):
                    sys.modules.pop(name, None)
            sys.modules.update(saved)


def _runtime_kind(raw_member: object, field_kind: str | None = None) -> str:
    """Classify a class dictionary member without invoking descriptors.

    Parameters
    ----------
    raw_member : object
        Raw member used by this helper.
    field_kind : str | None
        Field kind used by this helper.

    Returns
    -------
    str
        Result produced by _runtime_kind.

    Examples
    --------
    >>> _runtime_kind(property(lambda self: 1))
    'property'
    """
    if field_kind is not None:
        return field_kind
    if isinstance(raw_member, property):
        return "property"
    if isinstance(raw_member, classmethod):
        return "class-method"
    if isinstance(raw_member, staticmethod):
        return "static-method"
    if inspect.isfunction(raw_member):
        return "method"
    if hasattr(raw_member, "__get__"):
        return "descriptor"
    if inspect.ismethoddescriptor(raw_member):
        return "method"
    return "class-attribute"


def _safe_signature(value: object) -> str | None:
    """Return a runtime signature when introspection supports one.

    Parameters
    ----------
    value : object
        Value used by this helper.

    Returns
    -------
    str | None
        Result produced by _safe_signature.

    Examples
    --------
    >>> _safe_signature(lambda value=1: value)
    '(value=1)'
    """
    try:
        signature = str(inspect.signature(t.cast("t.Callable[..., t.Any]", value)))
    except (TypeError, ValueError):
        return None
    return re.sub(r"0x[0-9a-fA-F]+", "0x...", signature)


def _owner_for_member(cls: type[object], name: str) -> type[object] | None:
    """Find the first class in the MRO that defines a member.

    Parameters
    ----------
    cls : type[object]
        Cls used by this helper.
    name : str
        Name used by this helper.

    Returns
    -------
    type[object] | None
        Result produced by _owner_for_member.

    Examples
    --------
    >>> _owner_for_member(str, "upper") is str
    True
    """
    return next((base for base in cls.__mro__ if name in base.__dict__), None)


def _class_fields(cls: type[object]) -> list[tuple[str, str, type[object]]]:
    """Return dataclass or named-tuple fields with defining classes.

    Parameters
    ----------
    cls : type[object]
        Cls used by this helper.

    Returns
    -------
    list[tuple[str, str, type[object]]]
        Result produced by _class_fields.

    Examples
    --------
    >>> Row = dataclasses.make_dataclass("Row", [("value", int)])
    >>> [(name, kind) for name, kind, _ in _class_fields(Row)]
    [('value', 'dataclass-field')]
    """
    rows: list[tuple[str, str, type[object]]] = []
    if dataclasses.is_dataclass(cls):
        for field in dataclasses.fields(cls):
            owner = next(
                (
                    base
                    for base in cls.__mro__
                    if field.name in getattr(base, "__annotations__", {})
                ),
                cls,
            )
            rows.append((field.name, "dataclass-field", owner))
    elif hasattr(cls, "_fields"):
        rows.extend(
            (name, "named-tuple-field", _owner_for_member(cls, name) or cls)
            for name in t.cast("tuple[str, ...]", cls._fields)
        )
    return rows


def _runtime_public_names(cls: type[object], package_name: str) -> set[str]:
    """Return names defined by package-owned classes in an effective MRO.

    Parameters
    ----------
    cls : type[object]
        Cls used by this helper.
    package_name : str
        Package name used by this helper.

    Returns
    -------
    set[str]
        Result produced by _runtime_public_names.

    Examples
    --------
    >>> class Example:
    ...     visible = 1
    ...     _hidden = 2
    >>> _runtime_public_names(Example, Example.__module__)
    {'visible'}
    """
    return {
        name
        for base in cls.__mro__
        if base.__module__ == package_name
        or base.__module__.startswith(f"{package_name}.")
        for name in (set(base.__dict__) | set(getattr(base, "__annotations__", {})))
        if not name.startswith("_")
    }


def _enrich_class(
    package_name: str,
    cls: type[object],
    qualified_name: str,
    entries: dict[str, Json],
) -> None:
    """Validate one complete source-derived class surface at runtime.

    Parameters
    ----------
    package_name : str
        Package name used by this helper.
    cls : type[object]
        Cls used by this helper.
    qualified_name : str
        Qualified name used by this helper.
    entries : dict[str, Json]
        Entries used by this helper.

    Examples
    --------
    >>> class Empty:
    ...     pass
    >>> entry = {"kind": "class", "signature": "()"}
    >>> entry.update(declaredBaseClasses=[], fields=[], enumMembers=[])
    >>> entry.update(definedMembers=[], inheritedMembers=[])
    >>> entries = {"sample.Empty": entry}
    >>> _enrich_class("sample", Empty, "sample.Empty", entries)
    >>> entries["sample.Empty"]["signature"]
    '()'
    """
    class_entry = entries[qualified_name]
    runtime_kind = "exception" if issubclass(cls, BaseException) else "class"
    if class_entry["kind"] != runtime_kind:
        msg = f"AST and runtime class kinds differ for {qualified_name}"
        raise ValueError(msg)
    runtime_direct_bases = [
        f"{base.__module__}.{base.__qualname__}" for base in cls.__bases__
    ]
    if runtime_direct_bases == ["builtins.object"]:
        runtime_direct_bases = []
    declared_bases = t.cast("list[str]", class_entry["declaredBaseClasses"])
    named_tuple_transform = any(
        base.endswith("NamedTuple") for base in declared_bases
    ) and runtime_direct_bases == ["builtins.tuple"]
    if declared_bases != runtime_direct_bases and not named_tuple_transform:
        msg = f"AST and runtime direct bases differ for {qualified_name}"
        raise ValueError(msg)
    runtime_fields = _class_fields(cls)
    runtime_field_rows = sorted(
        [
            {
                "definedBy": f"{owner.__module__}.{owner.__qualname__}",
                "kind": kind,
                "name": name,
            }
            for name, kind, owner in runtime_fields
        ],
        key=lambda item: item["name"],
    )
    if class_entry["fields"] != runtime_field_rows:
        msg = (
            f"AST and runtime fields differ for {qualified_name}: "
            f"{class_entry['fields']} != {runtime_field_rows}"
        )
        raise ValueError(msg)
    if issubclass(cls, enum.Enum):
        runtime_enum_members = sorted(cls.__members__)
        if class_entry["enumMembers"] != runtime_enum_members:
            msg = f"AST and runtime enum members differ for {qualified_name}"
            raise ValueError(msg)
    expected_rows = [
        *t.cast("list[Json]", class_entry["definedMembers"]),
        *t.cast("list[Json]", class_entry["inheritedMembers"]),
    ]
    expected_names = {t.cast("str", row["name"]) for row in expected_rows}
    runtime_names = _runtime_public_names(cls, package_name)
    if expected_names != runtime_names:
        missing = sorted(runtime_names - expected_names)
        extra = sorted(expected_names - runtime_names)
        msg = (
            f"AST and runtime public members differ for {qualified_name}: "
            f"missing={missing}, extra={extra}"
        )
        raise ValueError(msg)
    field_map = {name: (kind, owner) for name, kind, owner in runtime_fields}
    for row in expected_rows:
        name = t.cast("str", row["name"])
        field_kind = field_map.get(name, (None, cls))[0]
        runtime_member_kind = (
            "enum-member"
            if issubclass(cls, enum.Enum) and name in cls.__members__
            else _runtime_kind(
                inspect.getattr_static(cls, name, None),
                field_kind,
            )
        )
        expected_kind = t.cast("str", row["kind"]).removeprefix("inherited-")
        if runtime_member_kind != expected_kind:
            msg = (
                f"AST and runtime member kinds differ for {qualified_name}.{name}: "
                f"{expected_kind} != {runtime_member_kind}"
            )
            raise ValueError(msg)


def _enrich_runtime(
    repo_root: pathlib.Path,
    package_name: str,
    entries: dict[str, Json],
    class_nodes: dict[str, ast.ClassDef],
) -> None:
    """Validate AST exports and complete source-derived class surfaces.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    package_name : str
        Package name used by this helper.
    entries : dict[str, Json]
        Entries used by this helper.
    class_nodes : dict[str, ast.ClassDef]
        Class nodes used by this helper.

    Examples
    --------
    >>> empty_entries = {}
    >>> _enrich_runtime(pathlib.Path("."), "libtmux", empty_entries, {})
    >>> empty_entries
    {}
    """
    module_names = [
        name for name, entry in entries.items() if entry["kind"] == "module"
    ]
    with _import_modules(repo_root, package_name, module_names) as modules:
        for module_name, module in modules.items():
            exports = entries[module_name]["exports"]
            missing = [name for name in exports if not hasattr(module, name)]
            if missing:
                msg = f"runtime exports missing from {module_name}: {missing}"
                raise ValueError(msg)
        for qualified_name in class_nodes:
            module_name, class_name = qualified_name.rsplit(".", 1)
            runtime_class = getattr(modules[module_name], class_name)
            if not inspect.isclass(runtime_class):
                msg = f"AST class is not a runtime class: {qualified_name}"
                raise ValueError(msg)
            _enrich_class(
                package_name,
                runtime_class,
                qualified_name,
                entries,
            )


def _finalize_entries(entries: dict[str, Json]) -> list[Json]:
    """Apply stable dispositions and sort the public inventory.

    Parameters
    ----------
    entries : dict[str, Json]
        Entries used by this helper.

    Returns
    -------
    list[Json]
        Result produced by _finalize_entries.

    Examples
    --------
    >>> entry = _base_entry("sample.test", "function", "src/sample.py", set())
    >>> _finalize_entries({"sample.test": entry})[0]["disposition"]
    'python-only'
    """
    for entry in entries.values():
        name = t.cast("str", entry["qualifiedName"])
        if ".pytest_plugin" in name or ".test." in name or name.endswith(".test"):
            entry["disposition"] = "python-only"
        if entry["deprecations"]:
            entry["disposition"] = "python-only"
    return sorted(
        entries.values(), key=lambda item: (item["qualifiedName"], item["kind"])
    )


def _link_public_format_fields(
    repo_root: pathlib.Path,
    package_name: str,
    entries: dict[str, Json],
) -> None:
    """Link source-declared Obj fields to matching public field entries.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    package_name : str
        Package name used by this helper.
    entries : dict[str, Json]
        Entries used by this helper.

    Examples
    --------
    >>> entries = {}
    >>> _link_public_format_fields(pathlib.Path("."), "missing-package", entries)
    >>> entries
    {}
    """
    neo_path = repo_root / "src" / package_name / "neo.py"
    if not neo_path.is_file():
        return
    tree = ast.parse(neo_path.read_bytes(), filename=str(neo_path))
    format_fields = set(_obj_field_names(tree))
    for entry in entries.values():
        kind = t.cast("str", entry["kind"]).removeprefix("inherited-")
        field_name = t.cast("str", entry["qualifiedName"]).rsplit(".", 1)[-1]
        if kind == "dataclass-field" and field_name in format_fields:
            entry["formatFields"] = [field_name]


def extract_public_api(
    repo_root: pathlib.Path,
    *,
    package_name: str = "libtmux",
) -> Json:
    """Extract and runtime-validate the public Python API manifest.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repository root containing src and tests.
    package_name : str, optional
        Python package directory below src.

    Returns
    -------
    dict[str, object]
        Stable public API manifest.

    Examples
    --------
    >>> public = extract_public_api(pathlib.Path("."))
    >>> server = next(
    ...     entry for entry in public["entries"]
    ...     if entry["qualifiedName"] == "libtmux.server.Server"
    ... )
    >>> server["signature"].startswith("(socket_name:")
    True
    """
    test_nodes = _collect_test_nodes(repo_root)
    entries, class_nodes = _ast_public_entries(repo_root, package_name, test_nodes)
    _enrich_runtime(repo_root, package_name, entries, class_nodes)
    _link_public_format_fields(repo_root, package_name, entries)
    fingerprint = fingerprint_authority_inputs(
        repo_root,
        package_name=package_name,
    )["sourceFingerprint"]
    return {
        "documentKind": DOCUMENT_KIND,
        "schemaVersion": SCHEMA_VERSION,
        "sourceFingerprint": fingerprint,
        "entries": _finalize_entries(entries),
    }


def _assigned_literal(tree: ast.Module, name: str, default: t.Any) -> t.Any:
    """Read a top-level literal assignment from syntax.

    Parameters
    ----------
    tree : ast.Module
        Tree used by this helper.
    name : str
        Name used by this helper.
    default : t.Any
        Default used by this helper.

    Returns
    -------
    t.Any
        Result produced by _assigned_literal.

    Examples
    --------
    >>> _assigned_literal(ast.parse("VALUES = ('one', 'two')"), "VALUES", ())
    ('one', 'two')
    """
    for node in tree.body:
        value: ast.AST | None = None
        if (
            isinstance(node, ast.Assign)
            and any(
                isinstance(target, ast.Name) and target.id == name
                for target in node.targets
            )
        ) or (
            isinstance(node, ast.AnnAssign)
            and isinstance(node.target, ast.Name)
            and node.target.id == name
        ):
            value = node.value
        if value is not None:
            try:
                return ast.literal_eval(value)
            except (ValueError, TypeError):
                if (
                    isinstance(value, ast.Call)
                    and isinstance(value.func, ast.Name)
                    and value.func.id == "frozenset"
                    and len(value.args) == 1
                ):
                    try:
                        return frozenset(ast.literal_eval(value.args[0]))
                    except (ValueError, TypeError):
                        return default
                return default
    return default


def _obj_field_names(tree: ast.Module) -> list[str]:
    """Read annotated Obj fields directly from source syntax.

    Parameters
    ----------
    tree : ast.Module
        Tree used by this helper.

    Returns
    -------
    list[str]
        Result produced by _obj_field_names.

    Examples
    --------
    >>> lines = ("class Obj:", "    server: object")
    >>> source = chr(10).join((*lines, "    pane_id: str", "    window_id: str"))
    >>> tree = ast.parse(source)
    >>> _obj_field_names(tree)
    ['pane_id', 'window_id']
    """
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "Obj":
            return sorted(
                child.target.id
                for child in node.body
                if isinstance(child, ast.AnnAssign)
                and isinstance(child.target, ast.Name)
                and child.target.id != "server"
            )
    msg = "libtmux.neo.Obj not found"
    raise ValueError(msg)


def _static_scope(field_name: str, neo_tree: ast.Module) -> str:
    """Classify a format field from source-declared tables.

    Parameters
    ----------
    field_name : str
        Field name used by this helper.
    neo_tree : ast.Module
        Neo tree used by this helper.

    Returns
    -------
    str
        Result produced by _static_scope.

    Examples
    --------
    >>> _static_scope("pane_id", ast.parse(""))
    'pane'
    """
    overrides = t.cast(
        "dict[str, str]", _assigned_literal(neo_tree, "_SCOPE_OVERRIDES", {})
    )
    context = set(_assigned_literal(neo_tree, "_CONTEXT_ONLY_TOKENS", ()))
    universal = set(_assigned_literal(neo_tree, "_UNIVERSAL_TOKENS", ()))
    if field_name in overrides:
        return overrides[field_name]
    if field_name in context:
        return "context"
    if field_name in universal:
        return "universal"
    for prefix, scope in (
        ("copy_cursor_", "event"),
        ("pane_", "pane"),
        ("window_", "window"),
        ("session_", "session"),
        ("client_", "client"),
        ("buffer_", "buffer"),
        ("mouse_", "event"),
        ("cursor_", "event"),
        ("selection_", "event"),
        ("scroll_", "event"),
        ("popup_", "event"),
    ):
        if field_name.startswith(prefix):
            return scope
    return "unknown"


def _source_family(scope: str) -> str:
    """Map the runtime scope to a stable authority family.

    Parameters
    ----------
    scope : str
        Scope used by this helper.

    Returns
    -------
    str
        Result produced by _source_family.

    Examples
    --------
    >>> _source_family("pane")
    'list-pane'
    """
    return {
        "session": "list-session",
        "window": "list-window",
        "pane": "list-pane",
        "client": "list-client",
        "buffer": "buffer",
        "universal": "list-session",
    }.get(scope, "context-only")


def _source_families(
    scope: str,
    scopes_by_list_cmd: dict[str, frozenset[str]],
) -> list[str]:
    """List each command family whose projection can resolve a scope.

    Parameters
    ----------
    scope : str
        Scope used by this helper.
    scopes_by_list_cmd : dict[str, frozenset[str]]
        Scopes by list cmd used by this helper.

    Returns
    -------
    list[str]
        Result produced by _source_families.

    Examples
    --------
    >>> scopes = {"list-panes": frozenset({"pane"})}
    >>> _source_families("pane", scopes)
    ['list-pane']
    """
    family_by_command = {
        "list-sessions": "list-session",
        "list-windows": "list-window",
        "list-panes": "list-pane",
        "list-clients": "list-client",
    }
    families = [
        family_by_command[command]
        for command, scopes in sorted(scopes_by_list_cmd.items())
        if scope in scopes
    ]
    if scope == "buffer":
        families.append("buffer")
    if not families:
        families.append("context-only")
    return sorted(families)


def extract_format_fields(
    repo_root: pathlib.Path,
    *,
    package_name: str = "libtmux",
) -> Json:
    """Extract every typed format field and its source family.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repository root containing the package.
    package_name : str, optional
        Python package directory below src.

    Returns
    -------
    dict[str, object]
        Stable format-field manifest.

    Examples
    --------
    >>> formats = extract_format_fields(pathlib.Path("."))
    >>> pane_id = next(
    ...     entry for entry in formats["entries"] if entry["fieldName"] == "pane_id"
    ... )
    >>> pane_id["scope"]
    'pane'
    """
    package_root = repo_root / "src" / package_name
    neo_path = package_root / "neo.py"
    formats_path = package_root / "formats.py"
    neo_tree = ast.parse(neo_path.read_bytes(), filename=str(neo_path))
    formats_tree = ast.parse(formats_path.read_bytes(), filename=str(formats_path))
    field_names = _obj_field_names(neo_tree)
    field_versions = t.cast(
        "dict[str, str]",
        _assigned_literal(neo_tree, "FIELD_VERSION", {}),
    )
    reference_families: dict[str, list[str]] = {}
    for constant, family in (
        ("SESSION_FORMATS", "list-session"),
        ("WINDOW_FORMATS", "list-window"),
        ("PANE_FORMATS", "list-pane"),
        ("CLIENT_FORMATS", "list-client"),
    ):
        for field_name in _assigned_literal(formats_tree, constant, []):
            reference_families.setdefault(field_name, []).append(family)

    test_nodes = _collect_test_nodes(repo_root)
    with _import_modules(
        repo_root,
        package_name,
        [f"{package_name}.neo"],
    ) as modules:
        neo_module = modules[f"{package_name}.neo"]
        runtime_fields = {
            field.name
            for field in dataclasses.fields(neo_module.Obj)
            if field.name != "server"
        }
        if set(field_names) != runtime_fields:
            msg = "AST and runtime Obj fields differ"
            raise ValueError(msg)
        runtime_scope = getattr(
            neo_module,
            "_token_scope",
            lambda field_name: _static_scope(field_name, neo_tree),
        )
        scopes_by_list_cmd = t.cast(
            "dict[str, frozenset[str]]",
            getattr(
                neo_module,
                "SCOPES_BY_LIST_CMD",
                {
                    "list-sessions": frozenset({"universal", "session"}),
                    "list-windows": frozenset({"universal", "session", "window"}),
                    "list-panes": frozenset({"universal", "session", "window", "pane"}),
                    "list-clients": frozenset(
                        {"universal", "session", "window", "pane", "client"}
                    ),
                },
            ),
        )
        entries: list[Json] = []
        for field_name in field_names:
            static_scope = _static_scope(field_name, neo_tree)
            actual_scope = t.cast("str", runtime_scope(field_name))
            if static_scope != actual_scope:
                msg = (
                    f"AST and runtime format scope differ for {field_name}: "
                    f"{static_scope} != {actual_scope}"
                )
                raise ValueError(msg)
            minimum_version = field_versions.get(field_name, DEFAULT_TMUX_VERSION)
            focused = _focused_tests(field_name, test_nodes)
            if not focused and package_name == "libtmux":
                focused = [
                    "tests/test_neo.py::test_every_obj_field_classifies_to_known_scope"
                ]
            entries.append(
                {
                    "behaviorFamilyId": "format.projection",
                    "disposition": "direct",
                    "fieldName": field_name,
                    "kind": "format-field",
                    "minimumTmuxVersion": minimum_version,
                    "pythonTestNodes": focused,
                    "qualifiedName": f"{package_name}.neo.Obj.{field_name}",
                    "referenceFamilies": sorted(reference_families.get(field_name, [])),
                    "scope": actual_scope,
                    "sourceFamilies": _source_families(
                        actual_scope,
                        scopes_by_list_cmd,
                    ),
                    "sourceFamily": _source_family(actual_scope),
                    "sourceFile": _relative(repo_root, neo_path),
                    "versionPredicate": {
                        "comparison": ">=",
                        "rawVersion": minimum_version,
                    },
                }
            )
    fingerprint = fingerprint_authority_inputs(
        repo_root,
        package_name=package_name,
    )["sourceFingerprint"]
    return {
        "documentKind": DOCUMENT_KIND,
        "schemaVersion": SCHEMA_VERSION,
        "sourceFingerprint": fingerprint,
        "entries": sorted(entries, key=lambda item: item["qualifiedName"]),
    }


def _load_curated(parity_root: pathlib.Path, filename: str, fingerprint: str) -> Json:
    """Load curated rows and refresh only the source fingerprint.

    Parameters
    ----------
    parity_root : pathlib.Path
        Directory holding this port's curated parity manifests.
    filename : str
        Filename used by this helper.
    fingerprint : str
        Fingerprint used by this helper.

    Returns
    -------
    Json
        Result produced by _load_curated.

    Examples
    --------
    >>> curated = _load_curated(
    ...     pathlib.Path("Parity"), "python-behavior-contracts.json", "sha256:example"
    ... )
    >>> curated["sourceFingerprint"]
    'sha256:example'
    """
    path = parity_root / filename
    document = t.cast("Json", json.loads(path.read_text(encoding="utf-8")))
    document["sourceFingerprint"] = fingerprint
    document["entries"] = sorted(
        document["entries"],
        key=lambda item: (
            item["behaviorFamilyId"],
            item.get("contractId", ""),
        ),
    )
    return document


def _validate_inherited_query_rows(
    repo_root: pathlib.Path, query_contracts: Json
) -> None:
    """Execute inherited query rows against the checkout's QueryList behavior.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repo root used by this helper.
    query_contracts : Json
        Query contracts used by this helper.

    Examples
    --------
    >>> contract = {"behaviorFamilyId": "query.example", "inheritance": "inherited"}
    >>> contract["inputRows"] = [{"id": "one", "name": "target"}]
    >>> contract.update(query={"name": "target"}, expectedMatchIds=["one"])
    >>> query = {"entries": [contract]}
    >>> _validate_inherited_query_rows(pathlib.Path("."), query)
    >>> query["entries"][0]["expectedMatchIds"]
    ['one']
    """
    with _import_modules(
        repo_root,
        "libtmux",
        ["libtmux._internal.query_list"],
    ) as modules:
        query_module = modules["libtmux._internal.query_list"]
        query_list = query_module.QueryList
        for contract in query_contracts["entries"]:
            if contract.get("inheritance") != "inherited":
                continue
            rows = t.cast("list[Json]", contract["inputRows"])
            query = t.cast("Json", contract["query"])
            matches = list(query_list(rows).filter(**query))
            actual_ids = [row["id"] for row in matches]
            expected_ids = contract["expectedMatchIds"]
            if actual_ids != expected_ids:
                msg = (
                    "query contract behavior mismatch for "
                    f"{contract['behaviorFamilyId']}: "
                    f"{actual_ids} != {expected_ids}"
                )
                raise ValueError(msg)
            outcome = contract.get("expectedOutcome")
            if outcome is None:
                continue
            outcome = t.cast("Json", outcome)
            try:
                if outcome["kind"] == "value":
                    actual = query_list(rows).get(
                        default=contract.get("defaultValue"),
                        **query,
                    )
                    if actual != outcome["value"]:
                        msg = (
                            "query contract behavior mismatch for "
                            f"{contract['behaviorFamilyId']}: "
                            f"{actual!r} != {outcome['value']!r}"
                        )
                        raise ValueError(msg)
                else:
                    query_list(rows).get(**query)
            except (
                query_module.ObjectDoesNotExist,
                query_module.MultipleObjectsReturned,
            ) as exc:
                expected_name = outcome.get("name")
                if outcome["kind"] != "error" or type(exc).__name__ != expected_name:
                    msg = (
                        "query contract behavior mismatch for "
                        f"{contract['behaviorFamilyId']}: "
                        f"{type(exc).__name__} != {expected_name}"
                    )
                    raise ValueError(msg) from exc
            else:
                if outcome["kind"] == "error":
                    msg = (
                        "query contract behavior mismatch for "
                        f"{contract['behaviorFamilyId']}: expected {outcome['name']}"
                    )
                    raise ValueError(msg)


def validate_contracts(
    repo_root: pathlib.Path,
    public_manifest: Json,
    format_manifest: Json,
    behavior_contracts: Json,
    query_contracts: Json,
) -> None:
    """Validate bidirectional symbols, tests, families, and dispositions.

    Parameters
    ----------
    repo_root : pathlib.Path
        Repository root containing current Python tests.
    public_manifest : dict[str, object]
        Fresh public API inventory.
    format_manifest : dict[str, object]
        Fresh format-field inventory.
    behavior_contracts : dict[str, object]
        Curated behavior rows.
    query_contracts : dict[str, object]
        Curated query rows.

    Raises
    ------
    ValueError
        If either direction of the parity relationship is incomplete.

    Examples
    --------
    >>> documents = build_documents(pathlib.Path("."))
    >>> validate_contracts(
    ...     pathlib.Path("."),
    ...     documents["python-public-api.json"],
    ...     documents["python-format-fields.json"],
    ...     documents["python-behavior-contracts.json"],
    ...     documents["python-query-contracts.json"],
    ... )
    >>> len(documents)
    4
    """
    inventory_entries = [
        *t.cast("list[Json]", public_manifest["entries"]),
        *t.cast("list[Json]", format_manifest["entries"]),
    ]
    symbols = {t.cast("str", entry["qualifiedName"]) for entry in inventory_entries}
    test_nodes = _collect_test_nodes(repo_root)
    behavior_entries = t.cast("list[Json]", behavior_contracts["entries"])
    query_entries = t.cast("list[Json]", query_contracts["entries"])
    behavior_entry_ids = {id(entry) for entry in behavior_entries}
    query_entry_ids = {id(entry) for entry in query_entries}
    contract_entries = [
        *behavior_entries,
        *query_entries,
    ]
    family_ids = {
        t.cast("str", entry["behaviorFamilyId"]) for entry in contract_entries
    }
    _validate_inherited_query_rows(repo_root, query_contracts)
    for contract in contract_entries:
        for symbol in contract.get("pythonSymbols", []):
            if symbol not in symbols:
                msg = f"unknown Python symbol: {symbol}"
                raise ValueError(msg)
        for node_id in contract.get("pythonTestNodes", []):
            if node_id not in test_nodes:
                msg = f"unknown Python test node: {node_id}"
                raise ValueError(msg)
        inheritance = contract.get("inheritance")
        if (
            id(contract) in behavior_entry_ids
            and inheritance == "adapted"
            and not contract.get("swiftAdaptation")
        ) or (
            id(contract) in query_entry_ids
            and inheritance in {"adapted", "swift-schema"}
            and not contract.get("normativeDifference")
        ):
            msg = (
                "noninherited contract lacks explicit normative status: "
                f"{contract['behaviorFamilyId']}"
            )
            raise ValueError(msg)
        behavior_authority_node = AUTHORITY_NODE
        if (
            id(contract) in behavior_entry_ids
            and inheritance == "inherited"
            and behavior_authority_node not in contract.get("pythonTestNodes", [])
        ):
            msg = (
                f"inherited contract does not cite executable behavior authority: "
                f"{contract['behaviorFamilyId']}"
            )
            raise ValueError(msg)
        if id(contract) in behavior_entry_ids and inheritance == "inherited":
            for field_name in (
                "expectedResultShape",
                "exitStderrPolicy",
                "listLeniency",
                "versionLanes",
            ):
                field_value = contract.get(field_name)
                if not isinstance(field_value, (dict, list)):
                    msg = (
                        "inherited behavior field lacks structured authority: "
                        f"{contract['behaviorFamilyId']}.{field_name}"
                    )
                    raise ValueError(msg)  # noqa: TRY004
                if (
                    isinstance(field_value, dict)
                    and "status" in field_value
                    and field_value
                    not in (
                        {"status": "NEEDS_CONTEXT"},
                        {"status": "NOT_APPLICABLE"},
                    )
                ):
                    msg = (
                        "invalid inherited behavior authority status: "
                        f"{contract['behaviorFamilyId']}.{field_name}"
                    )
                    raise ValueError(msg)
        if contract.get("inheritance") == "inherited" and (
            not contract.get("pythonSymbols") or not contract.get("pythonTestNodes")
        ):
            msg = (
                "inherited contract lacks Python evidence: "
                f"{contract['behaviorFamilyId']}"
            )
            raise ValueError(msg)
    for entry in inventory_entries:
        family_id = t.cast("str", entry.get("behaviorFamilyId", ""))
        if family_id not in family_ids:
            msg = f"inventory entry has no behavior contract: {entry['qualifiedName']}"
            raise ValueError(msg)
        if entry.get("disposition") not in {
            "direct",
            "adapted",
            "consolidated",
            "python-only",
        }:
            msg = f"invalid disposition: {entry['qualifiedName']}"
            raise ValueError(msg)
    list_ids = {
        entry["behaviorFamilyId"]
        for entry in behavior_contracts["entries"]
        if entry.get("contractGroup") == "list-error"
    }
    if list_ids and list_ids != set(LIST_ERROR_FAMILY_IDS):
        msg = "list/error behavior families differ from the stable set"
        raise ValueError(msg)


def python_provenance(repo_root: pathlib.Path) -> Json:
    """Describe the libtmux checkout a manifest was built from.

    A fingerprint proves a manifest matches some tree; it cannot say which.
    Without this, "parity with Python libtmux" names no version, and finding
    out means bisecting checkouts until one reproduces the fingerprint.

    Parameters
    ----------
    repo_root : pathlib.Path
        Root of the libtmux checkout being described.

    Returns
    -------
    dict[str, str]
        Remote, commit and description; empty strings when git cannot answer,
        so an export or a tarball still produces a manifest.

    Examples
    --------
    >>> sorted(python_provenance(pathlib.Path("/nonexistent")))
    ['commit', 'describe', 'remote']
    """

    def ask(*arguments: str) -> str:
        """Run one git query, or return an empty string.

        Parameters
        ----------
        *arguments : str
            Arguments after ``git -C <repo_root>``.

        Returns
        -------
        str
            Trimmed standard output, or empty when git could not answer.

        Examples
        --------
        >>> callable(ask)
        True
        """
        try:
            completed = subprocess.run(
                ["git", "-C", str(repo_root), *arguments],
                capture_output=True,
                text=True,
                check=True,
            )
        except (OSError, subprocess.CalledProcessError):
            return ""
        return completed.stdout.strip()

    return {
        "remote": ask("config", "--get", "remote.origin.url"),
        "commit": ask("rev-parse", "HEAD"),
        "describe": ask("describe", "--tags", "--always", "--dirty"),
    }


def build_documents(
    repo_root: pathlib.Path,
    parity_root: pathlib.Path,
) -> dict[str, Json]:
    """Build generated manifests and load curated contract rows.

    Two roots, because they are two repositories. The manifests describe a
    libtmux checkout and are curated in this port; while both lived in one
    tree a single root could stand for both, and it no longer can.

    Parameters
    ----------
    repo_root : pathlib.Path
        Root of the libtmux checkout being described.
    parity_root : pathlib.Path
        Directory this port keeps its curated manifests in.

    Returns
    -------
    dict[str, dict[str, object]]
        Documents keyed by checked-in filename.

    Examples
    --------
    >>> import os
    >>> names = sorted(
    ...     build_documents(
    ...         pathlib.Path(os.environ["LIBTMUX_PYTHON_REPO"]),
    ...         pathlib.Path("Parity"),
    ...     )
    ... ) if os.environ.get("LIBTMUX_PYTHON_REPO") else [
    ...     "python-behavior-contracts.json", "python-query-contracts.json"
    ... ]
    >>> (names[0], names[-1])
    ('python-behavior-contracts.json', 'python-query-contracts.json')
    """
    public_manifest = extract_public_api(repo_root)
    format_manifest = extract_format_fields(repo_root)
    fingerprint = t.cast("str", public_manifest["sourceFingerprint"])
    behavior = _load_curated(
        parity_root,
        "python-behavior-contracts.json",
        fingerprint,
    )
    query = _load_curated(
        parity_root,
        "python-query-contracts.json",
        fingerprint,
    )
    validate_contracts(repo_root, public_manifest, format_manifest, behavior, query)
    documents = {
        "python-behavior-contracts.json": behavior,
        "python-format-fields.json": format_manifest,
        "python-public-api.json": public_manifest,
        "python-query-contracts.json": query,
    }
    provenance = python_provenance(repo_root)
    for document in documents.values():
        document["pythonSource"] = provenance
    return documents


def _write_documents(
    parity_root: pathlib.Path,
    python_root: pathlib.Path,
    documents: dict[str, Json],
) -> None:
    """Write parity documents and sanitized source-input evidence.

    Parameters
    ----------
    parity_root : pathlib.Path
        Directory this port keeps its parity manifests in.
    python_root : pathlib.Path
        Root of the libtmux checkout the manifests describe.
    documents : dict[str, Json]
        Documents used by this helper.

    Examples
    --------
    >>> try:
    ...     _write_documents(pathlib.Path("pyproject.toml"), pathlib.Path("."), {})
    ... except OSError as exc:
    ...     type(exc).__name__
    'NotADirectoryError'
    """
    parity_root.mkdir(parents=True, exist_ok=True)
    for filename, document in documents.items():
        (parity_root / filename).write_text(render_json(document), encoding="utf-8")
    # The input fingerprint belongs beside the manifests it backs. It used to
    # sit in the Python repository's docs tree, which only worked while the two
    # were one checkout.
    (parity_root / SOURCE_INPUTS).write_text(
        render_json(fingerprint_authority_inputs(python_root)),
        encoding="utf-8",
    )


def _check_documents(
    parity_root: pathlib.Path,
    python_root: pathlib.Path,
    documents: dict[str, Json],
) -> None:
    """Fail when checked-in documents or input evidence drift.

    Parameters
    ----------
    parity_root : pathlib.Path
        Directory this port keeps its parity manifests in.
    python_root : pathlib.Path
        Root of the libtmux checkout the manifests describe.
    documents : dict[str, Json]
        Documents used by this helper.

    Examples
    --------
    >>> try:
    ...     _check_documents(
    ...         pathlib.Path("pyproject.toml"), pathlib.Path("."), {}
    ...     )
    ... except SystemExit as exc:
    ...     str(exc).startswith("Python parity documents are stale:")
    True
    """
    expected: dict[pathlib.Path, str] = {
        parity_root / filename: render_json(document)
        for filename, document in documents.items()
    }
    expected[parity_root / SOURCE_INPUTS] = render_json(
        fingerprint_authority_inputs(python_root)
    )
    drifted = [
        _relative(parity_root, path)
        for path, wanted in expected.items()
        if not path.is_file() or path.read_text(encoding="utf-8") != wanted
    ]
    if drifted:
        msg = f"Python parity documents are stale: {', '.join(drifted)}"
        raise SystemExit(msg)


def main(argv: list[str] | None = None) -> int:
    """Write or check the repository's Python parity documents.

    Parameters
    ----------
    argv : list[str], optional
        Command-line arguments excluding the executable name.

    Returns
    -------
    int
        Zero when generation or checking succeeds.

    Examples
    --------
    >>> import io
    >>> stderr = io.StringIO()
    >>> try:
    ...     with contextlib.redirect_stderr(stderr):
    ...         main([])
    ... except SystemExit as exc:
    ...     exc.code
    2
    """
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="write current manifests")
    mode.add_argument("--check", action="store_true", help="check for manifest drift")
    parser.add_argument(
        "--python-repo",
        type=pathlib.Path,
        default=os.environ.get("LIBTMUX_PYTHON_REPO"),
        help=(
            "root of the libtmux checkout to read; defaults to "
            "$LIBTMUX_PYTHON_REPO. libtmux for Python is a separate "
            "repository, so there is nothing sensible to guess."
        ),
    )
    args = parser.parse_args(argv)
    if args.python_repo is None:
        parser.error(
            "no libtmux checkout given: pass --python-repo or set LIBTMUX_PYTHON_REPO"
        )
    repo_root = pathlib.Path(args.python_repo).expanduser().resolve()
    if not (repo_root / "src" / PACKAGE_NAME).is_dir():
        parser.error(f"{repo_root} does not look like a libtmux checkout")
    parity_root = pathlib.Path(__file__).resolve().parents[1] / "Parity"
    documents = build_documents(repo_root, parity_root)
    if args.write:
        _write_documents(parity_root, repo_root, documents)
    else:
        _check_documents(parity_root, repo_root, documents)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
