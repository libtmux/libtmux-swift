# libtmux Swift bakeoffs

Disposable experiment infrastructure. When a design question has more than one
credible answer — how to own a tmux process, how to lower a filter to the wire,
which transport to spawn through — the contenders are built here as real code
with contract tests between them, and the one that wins is what gets written
into the library. What is left behind is the evidence, not the deliverable.

This is not part of a release. `.gitattributes` marks `dev/` `export-ignore`,
so a published version carries none of it, and nothing in the library's
`Package.swift` refers to anything under here.

## Layout

| Path | What is in it |
| --- | --- |
| `Sources/SpikeSupport/` | Shared harness: fixtures, leases, probes, the tmux matrix |
| `Sources/*Bakeoff/` | The contenders for one question, side by side |
| `Sources/*Probe/` | Small executables that answer one question about the platform |
| `Tests/` | The contract tests that decide a bakeoff |
| `Scripts/` | The harness runners |
| `PythonTests/` | Parity authorities, run by CI against a real Python libtmux |

## Running it

The toolchain is pinned, and this checks the manifest still holds to what the
harness assumes — no unsafe flags, no plugins, no macros. It resolves its own
package from the script's location, so the working directory does not matter:

```console
$ mise exec -- bash dev/Spikes/Scripts/check-toolchain.sh
```

The shared harness:

```console
$ mise exec -- swift test --package-path dev/Spikes --filter SpikeSupportTests
```

Everything, including the suites that drive real tmux:

```console
$ mise exec -- swift test --package-path dev/Spikes
```

Expect failures from both unless you have an authenticated tmux lane.
`TmuxMatrixTests` provisions tmux releases through the matrix harness and wants
`LIBTMUX_TMUX_BIN`, `LIBTMUX_TMUX_TAG`, or `LIBTMUX_MATRIX_ROOT`; without one it
reports rather than guessing, and it is inside the `SpikeSupportTests` filter
above as well. These are not CI gates — what CI runs from this directory is
`PythonTests/`, against a real Python libtmux.

## Its resolved versions are deliberately not pinned

`.gitignore` keeps `dev/Spikes/Package.resolved` out of the repository. The
library pins its dependencies because a pinned failure is a reproducible one.
This package is the opposite: it exists to find out how something behaves
*today*, so it resolves whatever is current on purpose.
