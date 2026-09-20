# Benchmarks

What each tmux mode costs, measured rather than asserted. `libtmux-bench` runs
every scenario under `.direct` and under `.connected(to:)`, counting a process
each time one starts and a round trip each time a command line is handed over,
and prints the table that appears in [the README][readme] and in
[`Modes.md`][modes].

## Why this is its own package

The shipped manifest should name only what ships. A benchmark is not part of
the library, so it lives in a package of its own — the same place
[swift-collections][], [swift-nio][], and [swift-log][] keep theirs — and
`.gitattributes` keeps this directory out of a release archive entirely.

It depends on the library by path, so the numbers come from the library as
built rather than from a copy of it:

```swift
dependencies: [.package(name: "libtmux", path: "..")]
```

The benchmark uses the root package's [`TmuxFixture`][fixture] crash reaper.
Each measurement owns a server with an empty tmux configuration and a
non-login `/bin/sh` pane. The server is reaped when the measurement ends,
including when the benchmark process is killed.

The output-noticing comparison disables terminal echo before preparing its
marker. The measured command prints that marker without typing its literal
value, so echoed input cannot satisfy either observer. Both lanes exclude
pane lookup and producer preparation; streaming includes opening and closing
the control connection. Streaming matches only the target pane's output and
retains partial markers across notifications. Ending the stream without a
match fails the measurement.

## Running it

From the repository root. It needs a real tmux, and puts its sockets under
`/tmp/libtmux-swift-dev/`:

```console
$ swift run --package-path Benchmarks libtmux-bench
```

That prints the counts along with wall-clock medians, which move with the
machine — run it yourself for those rather than trusting a number in a
document.

The counts, as the tables the documents carry:

```console
$ swift run --package-path Benchmarks libtmux-bench --markdown
```

Measure a particular tmux release instead of whichever one is on `PATH`:

```console
$ LIBTMUX_TMUX_BIN=~/tmux-3.4/bin/tmux swift run --package-path Benchmarks libtmux-bench
```

## The tables in the documents are generated

Never edit the table between the `<!-- mode-matrix:start -->` and
`<!-- mode-matrix:end -->` markers. `Scripts/update_mode_matrix.py` writes it
from this benchmark's own output, and CI fails when what is committed has
drifted from what the code now does:

```console
$ python3 Scripts/update_mode_matrix.py
```

```console
$ python3 Scripts/update_mode_matrix.py --check
```

[readme]: ../README.md
[modes]: ../Sources/LibTmux/LibTmux.docc/Modes.md
[fixture]: ../Tests/TmuxFixture
[swift-collections]: https://github.com/apple/swift-collections/tree/main/Benchmarks
[swift-nio]: https://github.com/apple/swift-nio/tree/main/Benchmarks
[swift-log]: https://github.com/apple/swift-log/tree/main/Benchmarks
