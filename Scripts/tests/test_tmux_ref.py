"""Tests for resolving and building a tmux ref, against local fixtures.

A local repository stands in for github.com/tmux/tmux: it has a lightweight
tag, an annotated tag, a branch, a name shared by a tag and a branch (where
"tag first" decides what a person gets) and a commit no ref names. A local
directory stands in for the releases page.
"""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tarfile
from pathlib import Path
from typing import Any

import pytest


def load(name: str, filename: str) -> Any:
    """Import a script from `Scripts/` under `name`."""
    path = Path(__file__).parents[1] / filename
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


REF = load("tmux_ref", "tmux_ref.py")

AUTOGEN = "cp config.template configure && chmod +x configure\n"
CONFIGURE = """#!/bin/sh
for arg in "$@"; do
  case "$arg" in --prefix=*) prefix="${arg#--prefix=}" ;; esac
done
sed "s|@PREFIX@|$prefix|" Makefile.in > Makefile
"""
MAKEFILE = (
    "all:\n\t@:\n"
    "install:\n\tmkdir -p @PREFIX@/bin\n\tcp tmux.sh @PREFIX@/bin/tmux\n"
    "\tchmod +x @PREFIX@/bin/tmux\n"
)


def git(root: Path, *args: str) -> str:
    """Run git in `root` and return its trimmed output."""
    done = subprocess.run(
        [
            "git",
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.invalid",
            "-C",
            str(root),
            *args,
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return done.stdout.strip()


def run_installed(prefix: Path) -> str:
    """Run the fake tmux a build installed and return what it printed."""
    return subprocess.run(
        [str(prefix / "bin" / "tmux")], capture_output=True, text=True, check=True
    ).stdout.strip()


class Upstream:
    """A repository with known refs, and the commits they name."""

    def __init__(self, root: Path) -> None:
        """Create the repository under `root`."""
        self.path = root / "upstream"
        self.path.mkdir()
        git(self.path, "init", "-q", "-b", "master")
        for name, text in (
            ("autogen.sh", AUTOGEN),
            ("config.template", CONFIGURE),
            ("Makefile.in", MAKEFILE),
        ):
            (self.path / name).write_text(text)
        self.one = self.commit("one")
        git(self.path, "tag", "1.0")
        self.two = self.commit("two")
        git(self.path, "tag", "-a", "2.0", "-m", "annotated")
        self.three = self.commit("three")
        git(self.path, "branch", "topic", self.two)
        git(self.path, "tag", "dual", self.one)
        git(self.path, "branch", "dual", self.three)

    def commit(self, label: str) -> str:
        """Commit a fake tmux that reports `label` and return the commit."""
        (self.path / "tmux.sh").write_text(f"#!/bin/sh\necho {label}\n")
        git(self.path, "add", "-A")
        git(self.path, "commit", "-q", "-m", label)
        return git(self.path, "rev-parse", "HEAD")

    def resolve(self, ref: str) -> str:
        """Resolve `ref` against this repository."""
        return REF.resolve(ref, str(self.path))


@pytest.fixture
def upstream(tmp_path: Path) -> Upstream:
    """Return a fresh stand-in for the tmux repository."""
    return Upstream(tmp_path)


@pytest.fixture
def releases(tmp_path: Path) -> str:
    """Return a stand-in for the releases page holding tmux 1.0."""
    source = tmp_path / "source" / "tmux-1.0"
    source.mkdir(parents=True)
    (source / "configure").write_text(CONFIGURE)
    (source / "configure").chmod(0o755)
    (source / "Makefile.in").write_text(MAKEFILE)
    (source / "tmux.sh").write_text("#!/bin/sh\necho release\n")
    page = tmp_path / "page" / "1.0"
    page.mkdir(parents=True)
    with tarfile.open(page / "tmux-1.0.tar.gz", "w:gz") as tar:
        tar.add(source, arcname="tmux-1.0")
    return f"file://{tmp_path / 'page'}"


def test_a_tag_names_its_commit(upstream: Upstream) -> None:
    """A release tag resolves to the commit it marks."""
    assert upstream.resolve("1.0") == upstream.one


def test_an_annotated_tag_resolves_to_the_commit(upstream: Upstream) -> None:
    """The tag object's own id is not a commit to build."""
    tag_object = git(upstream.path, "rev-parse", "2.0")
    assert tag_object != upstream.two
    assert upstream.resolve("2.0") == upstream.two


def test_a_branch_names_its_tip(upstream: Upstream) -> None:
    """A branch resolves to where it points now."""
    assert upstream.resolve("topic") == upstream.two
    assert upstream.resolve("master") == upstream.three


def test_a_tag_beats_a_branch_of_the_same_name(upstream: Upstream) -> None:
    """The released tag is what a version number means."""
    assert upstream.one != upstream.three
    assert upstream.resolve("dual") == upstream.one


def test_a_full_commit_names_itself(upstream: Upstream) -> None:
    """No network is needed to resolve a 40-hex commit."""
    assert REF.resolve(upstream.two, "/nonexistent") == upstream.two


@pytest.mark.parametrize("ref", ["9.9", "abcdef1"])
def test_an_unknown_or_abbreviated_ref_is_an_error(
    upstream: Upstream, ref: str
) -> None:
    """A ref that matches nothing never yields an empty cache key."""
    with pytest.raises(REF.RefError):
        upstream.resolve(ref)


@pytest.mark.parametrize("ref", ["--upload-pack=x", "a b", "x;id", "", "y" * 65])
def test_a_malformed_ref_is_an_error(upstream: Upstream, ref: str) -> None:
    """Nothing outside the allowed characters reaches git."""
    with pytest.raises(REF.RefError):
        upstream.resolve(ref)


def test_a_release_is_keyed_by_its_version() -> None:
    """A tarball never changes, so the version is the whole key."""
    assert REF.cache_key("release", "3.8") == {"key": "3.8"}
    assert REF.cache_key("release", "3.7b") == {"key": "3.7b"}


@pytest.mark.parametrize("ref", ["master", "../3.8", "3.8/x", "v3.8"])
def test_only_a_release_name_is_a_release(ref: str) -> None:
    """A path or a branch cannot be smuggled in as a release."""
    with pytest.raises(REF.RefError):
        REF.cache_key("release", ref)


def test_anything_else_is_keyed_by_its_commit(upstream: Upstream) -> None:
    """A branch name in the key would freeze the lane."""
    assert REF.cache_key("git", "master", str(upstream.path)) == {
        "key": f"sha-{upstream.three}",
        "sha": upstream.three,
    }


def test_build_release_installs_the_tarball(tmp_path: Path, releases: str) -> None:
    """A release builds from its tarball."""
    prefix = tmp_path / "prefix"
    REF.build_release("1.0", prefix, tmp_path / "work", releases, jobs=1)
    assert run_installed(prefix) == "release"


def test_build_release_refuses_a_missing_release(tmp_path: Path, releases: str) -> None:
    """A release that does not exist fails the build."""
    with pytest.raises(subprocess.CalledProcessError):
        REF.build_release("9.9", tmp_path / "p", tmp_path / "work", releases, jobs=1)


def test_build_git_installs_the_tagged_commit(
    tmp_path: Path, upstream: Upstream
) -> None:
    """A commit builds its own tree even though master has moved on."""
    prefix = tmp_path / "prefix"
    REF.build_git(upstream.one, prefix, tmp_path / "work", str(upstream.path), jobs=1)
    assert run_installed(prefix) == "one"


def test_build_git_installs_a_commit_no_ref_names(
    tmp_path: Path, upstream: Upstream
) -> None:
    """A bare commit builds the same way as a tag."""
    git(upstream.path, "branch", "-D", "topic")
    git(upstream.path, "tag", "-d", "2.0")
    prefix = tmp_path / "prefix"
    REF.build_git(upstream.two, prefix, tmp_path / "work", str(upstream.path), jobs=1)
    assert run_installed(prefix) == "two"


def test_build_git_takes_only_a_resolved_commit(
    tmp_path: Path, upstream: Upstream
) -> None:
    """A name must be resolved first, so the cache key and the build agree."""
    with pytest.raises(REF.RefError):
        REF.build_git("1.0", tmp_path / "p", tmp_path / "w", str(upstream.path))


def test_resolve_writes_github_output(tmp_path: Path, upstream: Upstream) -> None:
    """The workflow reads the key and the commit from the step output."""
    output = tmp_path / "out"
    status = REF.main(
        [
            "--remote",
            str(upstream.path),
            "resolve",
            "--source",
            "git",
            "1.0",
            "--github-output",
            str(output),
        ]
    )
    assert status == 0
    assert output.read_text() == f"key=sha-{upstream.one}\nsha={upstream.one}\n"


def test_resolve_failure_exits_nonzero(upstream: Upstream) -> None:
    """An unresolvable ref fails the step."""
    arguments = ["--remote", str(upstream.path), "resolve", "--source", "git", "9.9"]
    assert REF.main(arguments) == 1
