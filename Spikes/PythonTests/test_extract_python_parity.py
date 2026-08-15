"""Tests for the source-derived Python parity manifests."""

from __future__ import annotations

import ast
import copy
import doctest
import importlib.util
import json
import pathlib
import subprocess
import sys
import typing as t

import pytest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
EXTRACTOR_PATH = REPO_ROOT / "swift" / "Scripts" / "extract-python-parity.py"

SPEC = importlib.util.spec_from_file_location("extract_python_parity", EXTRACTOR_PATH)
if SPEC is None or SPEC.loader is None:
    msg = "Unable to load the Python parity extractor"
    raise RuntimeError(msg)
extractor = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = extractor
SPEC.loader.exec_module(extractor)


def _write_fixture_package(tmp_path: pathlib.Path) -> pathlib.Path:
    """Create a package that exercises each public-surface declaration kind."""
    repo = tmp_path / "fixture"
    package = repo / "src" / "sample"
    tests = repo / "tests"
    package.mkdir(parents=True)
    tests.mkdir()
    (repo / "docs" / "project").mkdir(parents=True)

    (package / "__init__.py").write_text(
        (
            "from .api import Exported, PUBLIC_CONSTANT\n"
            "from .exports import included as renamed\n"
            '__all__ = ("Exported", "PUBLIC_CONSTANT", "renamed")\n'
        ),
        encoding="utf-8",
    )
    (package / "api.py").write_text(
        (
            "from __future__ import annotations\n"
            "import dataclasses\n"
            "import enum\n"
            "import typing as t\n"
            "PUBLIC_CONSTANT = 7\n"
            "_PRIVATE_CONSTANT = 8\n"
            "class Marker:\n"
            "    def __get__(self, instance: object, owner: type[object]) -> str:\n"
            '        return "marked"\n'
            "class Choice(enum.Enum):\n"
            '    FIRST = "first"\n'
            '    SECOND = "second"\n'
            "class Pair(t.NamedTuple):\n"
            "    left: str\n"
            "    right: int\n"
            "@dataclasses.dataclass\n"
            "class Base:\n"
            '    inherited_field: str = "base"\n'
            "    @property\n"
            "    def label(self) -> str:\n"
            "        return self.inherited_field\n"
            "    def inherited(self, value: int) -> int:\n"
            "        return value\n"
            "class InitMixin:\n"
            "    def __init__(self, flag: bool = False) -> None:\n"
            "        self.flag = flag\n"
            "@dataclasses.dataclass\n"
            "class Exported(Base, InitMixin):\n"
            "    own_field: int = 1\n"
            "    marker = Marker()\n"
            "    def deprecated_child(self) -> None:\n"
            "        raise DeprecatedError(version='1.0')\n"
            "    @t.overload\n"
            "    def choose(self, value: int) -> int: ...\n"
            "    @t.overload\n"
            "    def choose(self, value: str) -> str: ...\n"
            "    def choose(self, value: int | str) -> int | str:\n"
            "        return value\n"
            "    def _helper(self) -> None:\n"
            "        return None\n"
            "class PublicError(Exception):\n"
            "    pass\n"
            'def public_function(value: str = "x") -> str:\n'
            "    return value\n"
            "def _private_function() -> None:\n"
            "    return None\n"
        ),
        encoding="utf-8",
    )
    (package / "exports.py").write_text(
        ('__all__ = ("included",)\nincluded = 1\nexcluded = 2\n'),
        encoding="utf-8",
    )
    (package / "_private.py").write_text("hidden = 1\n", encoding="utf-8")
    (tests / "test_api.py").write_text(
        "def test_exported_choose():\n    assert True\n",
        encoding="utf-8",
    )
    (repo / "docs" / "project" / "public-api.md").write_text(
        "`from sample.api import Exported`\n",
        encoding="utf-8",
    )
    (repo / "pyproject.toml").write_text(
        '[project]\nname = "sample"\n',
        encoding="utf-8",
    )
    return repo


def _write_format_fixture(repo: pathlib.Path) -> None:
    """Add format declarations with distinct scopes and version lanes."""
    package = repo / "src" / "sample"
    (package / "formats.py").write_text(
        (
            'SESSION_FORMATS = ["session_name"]\n'
            'WINDOW_FORMATS = ["window_name"]\n'
            'PANE_FORMATS = ["pane_id", "pane_flags"]\n'
            'CLIENT_FORMATS = ["client_name"]\n'
        ),
        encoding="utf-8",
    )
    (package / "neo.py").write_text(
        (
            "from __future__ import annotations\n"
            "import dataclasses\n"
            'FIELD_VERSION = {"pane_flags": "3.7", "window_raw": "3.7a"}\n'
            '_SCOPE_OVERRIDES = {"context_value": "context"}\n'
            '_UNIVERSAL_TOKENS = frozenset({"version"})\n'
            '_CONTEXT_ONLY_TOKENS = frozenset({"context_value"})\n'
            "@dataclasses.dataclass\n"
            "class Obj:\n"
            "    session_name: str | None = None\n"
            "    window_name: str | None = None\n"
            "    window_raw: str | None = None\n"
            "    pane_id: str | None = None\n"
            "    pane_flags: str | None = None\n"
            "    client_name: str | None = None\n"
            "    buffer_name: str | None = None\n"
            "    context_value: str | None = None\n"
            "    version: str | None = None\n"
        ),
        encoding="utf-8",
    )


def _entries_by_name(document: dict[str, t.Any]) -> dict[str, dict[str, t.Any]]:
    """Index manifest entries by qualified name."""
    return {entry["qualifiedName"]: entry for entry in document["entries"]}


def test_public_inventory_covers_exports_and_excludes_private_helpers(
    tmp_path: pathlib.Path,
) -> None:
    """A missing declaration kind or ``__all__`` filter breaks the inventory."""
    repo = _write_fixture_package(tmp_path)

    manifest = extractor.extract_public_api(repo, package_name="sample")
    entries = _entries_by_name(manifest)

    assert entries["sample.api"]["kind"] == "module"
    assert entries["sample.api.Exported"]["kind"] == "class"
    assert entries["sample.api.PublicError"]["kind"] == "exception"
    assert entries["sample.api.public_function"]["kind"] == "function"
    assert entries["sample.api.PUBLIC_CONSTANT"]["kind"] == "constant"
    assert entries["sample.renamed"] == {
        **entries["sample.renamed"],
        "kind": "re-export",
        "targetQualifiedName": "sample.exports.included",
    }
    assert "sample.exports.included" in entries
    assert "sample.exports.excluded" not in entries
    assert not any("_private" in name or "_helper" in name for name in entries)


def test_public_inventory_records_descriptors_fields_overloads_and_mro(
    tmp_path: pathlib.Path,
) -> None:
    """Removing runtime enrichment must lose a concrete descriptor or field."""
    repo = _write_fixture_package(tmp_path)

    entries = _entries_by_name(
        extractor.extract_public_api(repo, package_name="sample")
    )

    exported = entries["sample.api.Exported"]

    assert entries["sample.api.Base.label"]["kind"] == "property"
    assert entries["sample.api.Exported.marker"]["kind"] == "descriptor"
    assert entries["sample.api.Pair.left"]["kind"] == "named-tuple-field"
    assert entries["sample.api.Choice.FIRST"]["kind"] == "enum-member"
    assert len(entries["sample.api.Exported.choose"]["overloadSignatures"]) == 2
    assert exported["baseClasses"][:3] == [
        "sample.api.Base",
        "sample.api.InitMixin",
        "builtins.object",
    ]
    assert {item["name"] for item in exported["definedMembers"]} >= {
        "choose",
        "marker",
        "own_field",
    }
    inherited = {item["name"]: item for item in exported["inheritedMembers"]}
    assert inherited["inherited"]["definedBy"] == "sample.api.Base"
    assert inherited["label"]["definedBy"] == "sample.api.Base"
    assert inherited["inherited_field"]["definedBy"] == "sample.api.Base"


def test_child_deprecation_does_not_mark_public_class_python_only(
    tmp_path: pathlib.Path,
) -> None:
    """A deprecated child method does not deprecate its containing class."""
    repo = _write_fixture_package(tmp_path)

    entries = _entries_by_name(
        extractor.extract_public_api(repo, package_name="sample")
    )

    assert entries["sample.api.Exported"]["deprecations"] == []
    assert entries["sample.api.Exported"]["disposition"] == "direct"
    assert entries["sample.api.Exported.deprecated_child"]["deprecations"] == [
        {"marker": "exception", "version": "1.0"}
    ]
    assert (
        entries["sample.api.Exported.deprecated_child"]["disposition"] == "python-only"
    )


def test_ast_inventory_is_complete_before_runtime_validation(
    tmp_path: pathlib.Path,
) -> None:
    """Runtime validation cannot add or alter source-derived parity data."""
    repo = _write_fixture_package(tmp_path)
    test_nodes = extractor._collect_test_nodes(repo)

    entries, class_nodes = extractor._ast_public_entries(
        repo,
        "sample",
        test_nodes,
    )
    expected = {
        "sample.api.Exported.marker",
        "sample.api.Exported.own_field",
        "sample.api.Exported.inherited",
        "sample.api.Exported.inherited_field",
        "sample.api.Exported.label",
        "sample.api.Pair.left",
        "sample.api.Choice.FIRST",
    }

    assert expected <= entries.keys()
    assert entries["sample.api.Marker"]["signature"] == "()"
    assert entries["sample.api.Base"]["signature"] == (
        "(inherited_field: str = 'base') -> None"
    )
    assert entries["sample.api.Exported"]["signature"] == (
        "(inherited_field: str = 'base', own_field: int = 1) -> None"
    )
    assert entries["sample.api.Pair"]["signature"] == "(left: str, right: int)"
    before_runtime = copy.deepcopy(entries)
    extractor._enrich_runtime(
        repo,
        "sample",
        entries,
        class_nodes,
    )
    assert entries == before_runtime


def test_format_inventory_covers_scopes_and_keeps_raw_versions(
    tmp_path: pathlib.Path,
) -> None:
    """Collapsing a source family or 3.7a into 3.7 breaks this fixture."""
    repo = _write_fixture_package(tmp_path)
    _write_format_fixture(repo)

    manifest = extractor.extract_format_fields(repo, package_name="sample")
    entries = _entries_by_name(manifest)

    assert {entry["fieldName"] for entry in manifest["entries"]} == {
        "buffer_name",
        "client_name",
        "context_value",
        "pane_flags",
        "pane_id",
        "session_name",
        "version",
        "window_name",
        "window_raw",
    }
    assert entries["sample.neo.Obj.session_name"]["sourceFamily"] == "list-session"
    assert entries["sample.neo.Obj.window_name"]["sourceFamily"] == "list-window"
    assert entries["sample.neo.Obj.pane_id"]["sourceFamily"] == "list-pane"
    assert entries["sample.neo.Obj.client_name"]["sourceFamily"] == "list-client"
    assert entries["sample.neo.Obj.buffer_name"]["sourceFamily"] == "buffer"
    assert entries["sample.neo.Obj.context_value"]["sourceFamily"] == "context-only"
    assert entries["sample.neo.Obj.pane_flags"]["minimumTmuxVersion"] == "3.7"
    assert entries["sample.neo.Obj.window_raw"]["minimumTmuxVersion"] == "3.7a"


def test_public_format_field_entries_link_defining_and_inherited_fields() -> None:
    """Format-backed public fields carry their exact format-field links."""
    documents = extractor.build_documents(REPO_ROOT)
    entries = _entries_by_name(documents["python-public-api.json"])

    assert entries["libtmux.neo.Obj.pane_id"]["formatFields"] == ["pane_id"]
    assert entries["libtmux.pane.Pane.pane_id"]["formatFields"] == ["pane_id"]


def test_output_is_deterministic_relative_and_content_fingerprinted(
    tmp_path: pathlib.Path,
) -> None:
    """Changing authority bytes changes output without embedding host paths."""
    repo = _write_fixture_package(tmp_path)

    first = extractor.extract_public_api(repo, package_name="sample")
    second = extractor.extract_public_api(repo, package_name="sample")
    first_json = extractor.render_json(first)

    assert first_json == extractor.render_json(second)
    assert str(repo) not in first_json
    original_fingerprint = first["sourceFingerprint"]

    (repo / "untracked.txt").write_text("not an authority input\n", encoding="utf-8")
    assert (
        extractor.extract_public_api(repo, package_name="sample")["sourceFingerprint"]
        == original_fingerprint
    )

    api_path = repo / "src" / "sample" / "api.py"
    api_path.write_text(api_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    changed = extractor.extract_public_api(repo, package_name="sample")
    assert changed["sourceFingerprint"] != original_fingerprint


def test_contract_validation_rejects_unknown_python_test_node(
    tmp_path: pathlib.Path,
) -> None:
    """A contract cannot cite a test absent from the current Python suite."""
    repo = _write_fixture_package(tmp_path)
    public_manifest = extractor.extract_public_api(repo, package_name="sample")
    behavior = {
        "entries": [
            {
                "behaviorFamilyId": "fixture.invalid",
                "pythonSymbols": ["sample.api.Exported"],
                "pythonTestNodes": ["tests/test_api.py::test_missing"],
                "swiftAdaptation": "direct",
            }
        ]
    }

    with pytest.raises(ValueError, match="unknown Python test node"):
        extractor.validate_contracts(
            repo,
            public_manifest,
            {"entries": []},
            behavior,
            {"entries": []},
        )


def test_repository_contracts_are_bidirectional_and_pin_list_error_families() -> None:
    """The repository corpus covers both inventories and the exact policy set."""
    documents = extractor.build_documents(REPO_ROOT)
    behavior = documents["python-behavior-contracts.json"]

    list_error_ids = {
        entry["behaviorFamilyId"]
        for entry in behavior["entries"]
        if entry["contractGroup"] == "list-error"
    }
    assert list_error_ids == set(extractor.LIST_ERROR_FAMILY_IDS)
    extractor.validate_contracts(
        REPO_ROOT,
        documents["python-public-api.json"],
        documents["python-format-fields.json"],
        behavior,
        documents["python-query-contracts.json"],
    )


def test_inherited_query_contract_expected_matches_are_executed() -> None:
    """Mutating a frozen Python query outcome fails behavioral validation."""
    documents = extractor.build_documents(REPO_ROOT)
    query = copy.deepcopy(documents["python-query-contracts.json"])
    inherited = next(
        entry for entry in query["entries"] if entry["inheritance"] == "inherited"
    )
    inherited["expectedMatchIds"] = ["definitely-wrong"]

    with pytest.raises(ValueError, match="query contract behavior mismatch"):
        extractor.validate_contracts(
            REPO_ROOT,
            documents["python-public-api.json"],
            documents["python-format-fields.json"],
            documents["python-behavior-contracts.json"],
            query,
        )


def test_every_inherited_behavior_cites_executable_authority() -> None:
    """Every inherited row must cite the executable outcome comparison."""
    documents = extractor.build_documents(REPO_ROOT)
    behavior = copy.deepcopy(documents["python-behavior-contracts.json"])
    projection = next(
        entry
        for entry in behavior["entries"]
        if entry["behaviorFamilyId"] == "format.projection"
    )
    assert projection["inheritance"] == "inherited"
    projection["pythonTestNodes"] = [
        "tests/test_control_mode.py::test_control_mode_cleanup"
    ]

    with pytest.raises(ValueError, match="does not cite executable behavior authority"):
        extractor.validate_contracts(
            REPO_ROOT,
            documents["python-public-api.json"],
            documents["python-format-fields.json"],
            behavior,
            documents["python-query-contracts.json"],
        )


def test_inherited_behavior_fields_require_structured_authority() -> None:
    """Inherited evidence fields cannot regress to unauthenticated prose.

    Examples
    --------
    The four authority fields are explicit and independently falsifiable:

    >>> authority_fields = {
    ...     "expectedResultShape",
    ...     "exitStderrPolicy",
    ...     "listLeniency",
    ...     "versionLanes",
    ... }
    >>> len(authority_fields)
    4
    """
    documents = extractor.build_documents(REPO_ROOT)
    behavior = copy.deepcopy(documents["python-behavior-contracts.json"])
    inherited = next(
        entry for entry in behavior["entries"] if entry["inheritance"] == "inherited"
    )
    inherited["expectedResultShape"] = "caller-supplied prose"

    with pytest.raises(
        ValueError,
        match="inherited behavior field lacks structured authority",
    ):
        extractor.validate_contracts(
            REPO_ROOT,
            documents["python-public-api.json"],
            documents["python-format-fields.json"],
            behavior,
            documents["python-query-contracts.json"],
        )


def test_noninherited_contracts_require_explicit_normative_status() -> None:
    """Adapted and Swift-schema rows cannot masquerade as Python behavior."""
    documents = extractor.build_documents(REPO_ROOT)
    behavior = copy.deepcopy(documents["python-behavior-contracts.json"])
    adapted = next(
        entry for entry in behavior["entries"] if entry["inheritance"] == "adapted"
    )
    adapted.pop("swiftAdaptation")

    with pytest.raises(ValueError, match="lacks explicit normative status"):
        extractor.validate_contracts(
            REPO_ROOT,
            documents["python-public-api.json"],
            documents["python-format-fields.json"],
            behavior,
            documents["python-query-contracts.json"],
        )

    query = copy.deepcopy(documents["python-query-contracts.json"])
    swift_schema = next(
        entry for entry in query["entries"] if entry["inheritance"] == "swift-schema"
    )
    swift_schema.pop("normativeDifference")

    with pytest.raises(ValueError, match="lacks explicit normative status"):
        extractor.validate_contracts(
            REPO_ROOT,
            documents["python-public-api.json"],
            documents["python-format-fields.json"],
            documents["python-behavior-contracts.json"],
            query,
        )


def test_checked_in_documents_match_fresh_sorted_generation() -> None:
    """Manifest drift or non-sorted JSON must fail the focused parity gate."""
    documents = extractor.build_documents(REPO_ROOT)

    for filename, document in documents.items():
        path = REPO_ROOT / "swift" / "Parity" / filename
        assert path.read_text(encoding="utf-8") == extractor.render_json(document)
        assert json.loads(path.read_text(encoding="utf-8")) == document


def test_every_extractor_function_has_numpy_docstring_and_doctest() -> None:
    """Every extractor function demonstrates behavior, not mere callability."""
    tree = ast.parse(EXTRACTOR_PATH.read_bytes(), filename=str(EXTRACTOR_PATH))
    missing: list[str] = []
    parser = doctest.DocTestParser()

    for node in tree.body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        docstring = ast.get_docstring(node) or ""
        if "Examples\n--------\n" not in docstring or ">>>" not in docstring:
            missing.append(node.name)
        examples = parser.get_examples(docstring)
        direct_calls = [
            call
            for example in examples
            for statement in ast.parse(example.source).body
            for call in ast.walk(statement)
            if isinstance(call, ast.Call)
            and isinstance(call.func, ast.Name)
            and call.func.id == node.name
        ]
        observations = [
            example
            for example in examples
            if example.want or "assert " in example.source
        ]
        if not direct_calls or not observations:
            missing.append(node.name)
        if node.args.args and "Parameters\n----------\n" not in docstring:
            missing.append(node.name)
        if (
            node.returns is not None
            and ast.unparse(node.returns) != "None"
            and "Returns\n-------\n" not in docstring
        ):
            missing.append(node.name)

    assert missing == [], missing


def test_clean_docs_build_has_no_warnings(tmp_path: pathlib.Path) -> None:
    """A first-build Sphinx environment treats every warning as a failure."""
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "sphinx",
            "-W",
            "--keep-going",
            "-b",
            "dirhtml",
            "-d",
            str(tmp_path / "doctrees"),
            str(REPO_ROOT / "docs"),
            str(tmp_path / "html"),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_plan_owned_sdd_workspace_is_not_tracked() -> None:
    """The ignored SDD planning workspace cannot become a deliverable."""
    result = subprocess.run(
        ["git", "ls-files", ".superpowers/sdd"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )

    assert result.stdout == ""
