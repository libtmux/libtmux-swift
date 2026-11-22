# swift_test

Runs `swift test` with no tmux selector in its environment, and stops any tmux
server the run leaves behind.

tmux follows an inherited `TMUX` to the server its caller is inside, and
`TMUX_PANE` and `LIBTMUX_SOCKET*` pick a pane and a socket. A suite started from
a tmux pane reaches that server once one case names no socket. The script:

- removes those variables;
- gives the run a fresh owner-only `TMUX_TMPDIR` under
  `/tmp/libtmux-swift-test/`, and refuses that root unless the caller owns it
  and no one else can write to it;
- marks the run in `LIBTMUX_TEST_SANDBOX`, which the fixtures check. A run
  started any other way is refused by the first fixture it reaches.

When the run ends, the script stops every server still listening on a socket
under that directory, waits up to three seconds for each to stop accepting
connections, and fails the run, naming the sockets, even when the tests passed.

- A socket file nothing listens on is not a leak.
- The directory stays while a listener remains.

Arguments go to `swift test` unchanged, and so does its exit status. SIGINT and
SIGTERM go to `swift test` as well; the script waits for it, cleans up, and
exits with 128 plus the signal's number. CI runs it for every test, and a
maintainer runs it in place of `swift test`:

```console
$ scripts/swift_test/swift_test.py \
    --traits YAMLWorkspaces \
    --force-resolved-versions
```

`LIBTMUX_TEST_TMUX_TMPDIR` names an absolute parent for the run's directory. The
script refuses a parent that:

- is a link, or is not empty;
- holds a `tmux-<uid>` entry;
- is so long that the default socket under it would pass 100 bytes.

It never changes the mode of a directory that exists.

## Tests

The tests run the script against stand-ins for `swift` and for the tmux client,
Python programs under `tests/stand_ins/`, and against a real tmux for the leak
cases, which skip when none is on `PATH`. `LIBTMUX_TEST_TMUX` picks the release
(with `LIBTMUX_TMUX_BIN` as a fallback).

```console
$ uv run --project scripts --group dev pytest scripts/swift_test
```
