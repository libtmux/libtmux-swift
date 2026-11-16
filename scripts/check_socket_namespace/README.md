# check_socket_namespace

Fails when a tracked Swift file addresses a tmux socket outside this port's
roots, `/tmp/libtmux-swift-test/` and `/tmp/libtmux-swift-dev/`, which keeps it
out of the other ports' servers. The rule is in [`AGENTS.md`](../../AGENTS.md).

It reads literal `Server(socketPath:)` and `Server(socketName:)` calls.

Outside `Sources/` it also fails a `Server()`, a `TmuxContext.current()` with no
environment and a `makeServer()`, because each follows `TMUX` or tmux's default
socket. A deliberate exception is listed beside its reason in the script. The check
cannot see whether a server was started.

CI runs it on the repository-checks leg of the `test` job.

```console
$ uv run scripts/check_socket_namespace/check_socket_namespace.py
```

## Tests

```console
$ uv run --group dev pytest scripts/check_socket_namespace
```
