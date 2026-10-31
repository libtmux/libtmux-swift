#!/usr/bin/env python3
"""Resolve a tmux release, tag, branch or commit, and build tmux from it.

A release keeps the path CI has always taken: its tarball from the tmux
releases page, cached on the version and the runner, because a release tarball
never changes. Anything else, a branch, a tag the manifest does not list or a
bare commit, is resolved to a commit and built from that commit, and cached on
it: a key of `tmux-master` would freeze a lane at whatever the first run built.

    python3 Scripts/tmux_ref.py resolve --source release 3.8
    python3 Scripts/tmux_ref.py resolve --source git master
    python3 Scripts/tmux_ref.py build --source git --ref <commit> --prefix ~/tmux-x
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile

REMOTE = "https://github.com/tmux/tmux.git"
RELEASES = "https://github.com/tmux/tmux/releases/download"

REF_PATTERN = re.compile(r"[A-Za-z0-9._/-]{1,64}")
SHA_PATTERN = re.compile(r"[0-9a-f]{40}")
RELEASE_PATTERN = re.compile(r"\d+\.\d+[a-z]?")


class RefError(Exception):
    """The ref cannot be resolved or built."""


def _check_ref(ref: str) -> None:
    if REF_PATTERN.fullmatch(ref) is None or ref.startswith("-"):
        message = f"tmux ref {ref!r} must match [A-Za-z0-9._/-]{{1,64}}"
        raise RefError(message)


def resolve(ref: str, remote: str = REMOTE) -> str:
    """Return the 40-hex commit that `ref` names on `remote`.

    A full commit names itself. Otherwise a tag beats a branch of the same
    name, and an annotated tag resolves to the commit it marks.
    """
    _check_ref(ref)
    if SHA_PATTERN.fullmatch(ref):
        return ref
    names = (f"refs/tags/{ref}^{{}}", f"refs/tags/{ref}", f"refs/heads/{ref}")
    done = subprocess.run(
        ["git", "ls-remote", remote, *names],
        capture_output=True,
        text=True,
        check=False,
    )
    if done.returncode != 0:
        message = f"git ls-remote {remote} failed: {done.stderr.strip()}"
        raise RefError(message)
    found = {}
    for line in done.stdout.splitlines():
        sha, _, name = line.partition("\t")
        found[name] = sha
    for name in names:
        if name in found:
            return found[name]
    message = (
        f"{remote} has no tag or branch named {ref!r}; "
        "name a commit by its full 40-hex id"
    )
    raise RefError(message)


def cache_key(source: str, ref: str, remote: str = REMOTE) -> dict[str, str]:
    """Return the cache key, and for a commit build the commit itself.

    A release is identified by its version. Anything else by the commit it
    resolves to, which is also what `build` is given.
    """
    if source == "release":
        if RELEASE_PATTERN.fullmatch(ref) is None:
            message = f"{ref!r} is not a tmux release such as 3.8 or 3.7b"
            raise RefError(message)
        return {"key": ref}
    sha = resolve(ref, remote)
    return {"key": f"sha-{sha}", "sha": sha}


def _make(source: pathlib.Path, prefix: pathlib.Path, jobs: int | None) -> None:
    workers = str(jobs or os.cpu_count() or 2)
    for command in (
        ["./configure", f"--prefix={prefix}"],
        ["make", f"-j{workers}"],
        ["make", "install"],
    ):
        subprocess.run(command, cwd=source, check=True)


def _git(source: pathlib.Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "advice.detachedHead=false", "-C", str(source), *args],
        check=True,
    )


def build_release(
    version: str,
    prefix: pathlib.Path,
    work: pathlib.Path,
    base: str = RELEASES,
    jobs: int | None = None,
) -> None:
    """Build the release tarball of `version` and install it under `prefix`."""
    if RELEASE_PATTERN.fullmatch(version) is None:
        message = f"{version!r} is not a tmux release such as 3.8 or 3.7b"
        raise RefError(message)
    work.mkdir(parents=True, exist_ok=True)
    archive = work / f"tmux-{version}.tar.gz"
    subprocess.run(
        [
            "curl",
            "--location",
            "--fail",
            "--silent",
            "--show-error",
            f"{base}/{version}/tmux-{version}.tar.gz",
            "--output",
            str(archive),
        ],
        check=True,
    )
    with tarfile.open(archive) as tar:
        tar.extractall(work, filter="data")
    _make(work / f"tmux-{version}", prefix, jobs)


def build_git(
    sha: str,
    prefix: pathlib.Path,
    work: pathlib.Path,
    remote: str = REMOTE,
    jobs: int | None = None,
) -> None:
    """Fetch exactly commit `sha`, then build and install it under `prefix`."""
    if SHA_PATTERN.fullmatch(sha) is None:
        message = f"build takes a resolved 40-hex commit, not {sha!r}"
        raise RefError(message)
    source = work / f"tmux-{sha}"
    source.mkdir(parents=True, exist_ok=True)
    _git(source, "init", "-q")
    _git(source, "remote", "add", "origin", remote)
    _git(source, "fetch", "-q", "--depth", "1", "origin", sha)
    _git(source, "checkout", "-q", "--detach", "FETCH_HEAD")
    head = subprocess.run(
        ["git", "-C", str(source), "rev-parse", "HEAD"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    if head != sha:
        message = f"fetched {head} when asked for {sha}"
        raise RefError(message)
    subprocess.run(["sh", "autogen.sh"], cwd=source, check=True)
    _make(source, prefix, jobs)


def _run_resolve(args: argparse.Namespace) -> int:
    values = cache_key(args.source, args.ref, args.remote)
    lines = [f"{key}={value}" for key, value in values.items()]
    print("\n".join(lines))
    if args.github_output:
        with pathlib.Path(args.github_output).open("a") as output:
            output.writelines(f"{line}\n" for line in lines)
    return 0


def _run_build(args: argparse.Namespace) -> int:
    work = args.work or pathlib.Path(tempfile.mkdtemp(prefix="tmux-src-"))
    if args.source == "release":
        build_release(args.ref, args.prefix, work, args.releases, args.jobs)
    else:
        build_git(args.ref, args.prefix, work, args.remote, args.jobs)
    return 0


def main(argv: list[str] | None = None) -> int:
    """Resolve a tmux ref, or build tmux from a release or a resolved commit."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remote", default=REMOTE)
    subparsers = parser.add_subparsers(dest="command", required=True)

    resolving = subparsers.add_parser("resolve", help="print the cache key of a ref")
    resolving.add_argument("--source", choices=("release", "git"), required=True)
    resolving.add_argument("ref")
    resolving.add_argument("--github-output", default="")
    resolving.set_defaults(handler=_run_resolve)

    building = subparsers.add_parser("build", help="build and install tmux")
    building.add_argument("--source", choices=("release", "git"), required=True)
    building.add_argument("--ref", required=True)
    building.add_argument("--prefix", type=pathlib.Path, required=True)
    building.add_argument("--work", type=pathlib.Path)
    building.add_argument("--jobs", type=int)
    building.add_argument("--releases", default=RELEASES)
    building.set_defaults(handler=_run_build)

    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except RefError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
