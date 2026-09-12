#!/usr/bin/env python3
"""Verify and compare installed workspace CLIs on owned private servers."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import site
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main():
    """Measure installed commands and validate each resulting workspace."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("--tmux", default="tmux")
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.samples < 2:
        parser.error("at least two samples are required")
    selected_tmux = shutil.which(args.tmux)
    if selected_tmux is None:
        parser.error("the selected tmux executable is unavailable")
    args.tmux = str(Path(selected_tmux).resolve())
    native = [str(args.executable.resolve())]
    reference = [
        args.python,
        "-u",
        "-c",
        "from tmuxp.cli import cli; import sys; cli(sys.argv[1:])",
    ]
    owned = Path("/tmp/libtmux-swift-dev")
    owned.mkdir(exist_ok=True)
    comparison = {}
    with tempfile.TemporaryDirectory(prefix="installed-", dir=owned) as temporary:
        root = Path(temporary)
        socket = root / "tmux"
        config = root / "configs"
        config.mkdir()
        env = dict(
            os.environ,
            HOME=str(root),
            TMUXP_CONFIGDIR=str(config),
            PYTHONUSERBASE=site.getuserbase(),
            NO_COLOR="1",
            EDITOR="/bin/true",
            LIBTMUX_TMUX_BIN=args.tmux,
            TMUX_WORKSPACE_PYTHON=args.python,
        )
        env.pop("TMUX", None)
        env.pop("TMUX_PANE", None)
        env["PATH"] = str(Path(args.tmux).resolve().parent) + os.pathsep + env["PATH"]
        fixture = config / "benchmark.json"
        fixture.write_text(
            json.dumps(
                {
                    "session_name": "benchmark",
                    "start_directory": str(root),
                    "windows": [
                        {"window_name": "editor", "panes": [None, None]},
                        {"window_name": "shell", "panes": [None]},
                    ],
                }
            )
        )
        capture_path = root / "capture.yaml"

        def run(prefix, arguments, expected=0):
            start = time.perf_counter_ns()
            result = subprocess.run(
                [*prefix, *map(str, arguments)],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=20,
                check=False,
            )
            elapsed = (time.perf_counter_ns() - start) / 1e6
            assert result.returncode == expected, (
                arguments,
                result.returncode,
                result.stdout,
                result.stderr,
            )
            return result, elapsed

        def kill():
            subprocess.run(
                [args.tmux, "-S", str(socket), "kill-server"],
                capture_output=True,
                timeout=5,
                check=False,
            )

        def summarize(values):
            return {
                "samples_ms": values,
                "median_ms": statistics.median(values),
                "minimum_ms": min(values),
                "maximum_ms": max(values),
                "stdev_ms": statistics.stdev(values),
            }

        try:
            version, _ = run(
                [args.python],
                [
                    "-c",
                    (
                        "import importlib.metadata; "
                        "print(importlib.metadata.version('tmuxp'))"
                    ),
                ],
            )
            assert version.stdout.strip() == "1.74.0"
            for lane, prefix in (("swift", native), ("tmuxp_1.74.0", reference)):
                measured = {}
                for name, arguments in {
                    "startup_version": ["--version"],
                    "list_one_workspace": ["ls", "--json"],
                    "search_one_workspace": ["search", "benchmark", "--json"],
                }.items():
                    values = []
                    for _ in range(args.samples):
                        result, elapsed = run(prefix, arguments)
                        if name == "list_one_workspace":
                            assert [
                                row["name"]
                                for row in json.loads(result.stdout)["workspaces"]
                            ] == ["benchmark"]
                        elif name == "search_one_workspace":
                            assert [
                                row["name"] for row in json.loads(result.stdout)
                            ] == ["benchmark"]
                        else:
                            assert (
                                result.stdout.strip()
                                and "usage:" not in result.stdout.lower()
                            )
                        values.append(elapsed)
                    measured[name] = summarize(values)
                loads, captures = [], []
                for _ in range(args.samples):
                    kill()
                    _, elapsed = run(
                        prefix,
                        [
                            "load",
                            fixture,
                            "-d",
                            "-S",
                            socket,
                            "-f",
                            "/dev/null",
                            "--no-progress",
                        ],
                    )
                    loads.append(elapsed)
                    state, _ = run(
                        [args.tmux],
                        [
                            "-S",
                            socket,
                            "list-windows",
                            "-t",
                            "=benchmark:",
                            "-F",
                            "#{window_index}:#{window_panes}",
                        ],
                    )
                    assert state.stdout.splitlines() == ["0:2", "1:1"], (
                        lane,
                        state.stdout,
                    )
                    directories, _ = run(
                        [args.tmux],
                        [
                            "-S",
                            socket,
                            "list-panes",
                            "-s",
                            "-t",
                            "=benchmark:",
                            "-F",
                            "#{pane_current_path}",
                        ],
                    )
                    assert directories.stdout.splitlines() == [str(root)] * 3
                    _, elapsed = run(
                        prefix,
                        [
                            "freeze",
                            "benchmark",
                            "-S",
                            socket,
                            "--save-to",
                            capture_path,
                            "--workspace-format",
                            "yaml",
                            "--yes",
                            "--force",
                        ],
                    )
                    captures.append(elapsed)
                    decoded, _ = run(
                        [args.python],
                        [
                            "-c",
                            (
                                "import json,sys,yaml; "
                                "print(json.dumps(yaml.safe_load(open(sys.argv[1]))))"
                            ),
                            capture_path,
                        ],
                    )
                    document = json.loads(decoded.stdout)
                    assert document["session_name"] == "benchmark"
                    assert [
                        window["window_name"] for window in document["windows"]
                    ] == ["editor", "shell"]
                    assert [len(window["panes"]) for window in document["windows"]] == [
                        2,
                        1,
                    ]
                measured["detached_load"] = summarize(loads)
                measured["freeze_yaml_file"] = summarize(captures)
                comparison[lane] = measured
        finally:
            kill()
    args.output.write_text(
        json.dumps(
            {
                "comparison": comparison,
                "samples": args.samples,
                "fixture": "two windows, three blank panes, explicit cwd, "
                "default indexes 0 and 1",
                "timing_boundary": "subprocess start through exit; correctness "
                "excluded; cold private server for load; YAML file output for freeze",
                "limitations": "blank-pane fixture; no command execution, "
                "interactive behavior or complete capture parity measured",
            },
            indent=2,
        )
        + "\n"
    )
    print(
        json.dumps(
            {
                "samples_per_operation": args.samples,
                "operations_per_lane": 5,
                "correctness": "passed",
            }
        )
    )


if __name__ == "__main__":
    main()
