# swift_test

Runs `swift test` with no tmux selector in its environment, and stops any tmux
server the run leaves behind.

tmux follows an inherited `TMUX` to the server its caller is inside, ahead of
`TMUX_TMPDIR`, and `TMUX_PANE` and `LIBTMUX_SOCKET*` pick a pane and a socket. A
suite started from a tmux pane would reach that server as soon as one case named
no socket. The script removes those variables, gives the run a fresh owner-only
`TMUX_TMPDIR` under `/tmp/libtmux-swift-test/`, and marks the run in
`LIBTMUX_TEST_SANDBOX`, which the fixtures check: a run of this package started
any other way is refused by the first fixture it reaches.

When the run ends, the script looks for sockets anywhere under that directory
and stops every server still listening on one. It then waits up to three seconds
for the socket to stop accepting connections and fails the run, naming the
sockets, even when the tests passed. A socket file nothing listens on is not a
leak. The directory stays while a listener remains.

Arguments go to `swift test` unchanged, and so does its exit status. A signal
waits for `swift test` to end, then ends the run with 128 plus its number after
the cleanup. CI runs it for every test, and a maintainer runs it in place of
`swift test`:

```console
$ scripts/swift_test/swift_test.py \
    --traits YAMLWorkspaces \
    --force-resolved-versions
```

`LIBTMUX_TEST_TMUX_TMPDIR` names an absolute parent for the run's directory. The
script refuses a parent that is a link, is not empty, holds a `tmux-<uid>`
entry, or is so long that the default socket under it would pass 100 bytes. It
never changes the mode of a directory that exists.

## Tests

The tests run the script against stand-ins for `swift`, and against a real tmux
for the leak cases, which skip when none is on `PATH`. `LIBTMUX_TMUX_BIN` picks
the release.

```console
$ uv run --group dev pytest scripts/swift_test
```
