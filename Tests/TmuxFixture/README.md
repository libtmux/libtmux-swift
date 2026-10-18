# `TmuxFixture`

Provisions an isolated real tmux server for a test or benchmark and reaps it
when the body returns, throws, or its owning process is killed.

The package product and module are both `TmuxFixture`, and
[`withTmuxServer`][api-withtmuxserver] is its entry point:

```swift
.product(name: "TmuxFixture", package: "libtmux-swift")
```

```swift
import Testing
import TmuxFixture

try await withTmuxServer { server in
    let sessions = try await server.sessions()
    #expect(sessions.map(\.name) == ["bootstrap"])
}
```

Each call starts one tmux server under `/tmp/libtmux-swift-test/`, creates a
bootstrap session, and limits concurrent fixtures so the suite cannot exhaust
processes or pseudo-terminals. The reaper refuses paths outside this port's
test and development roots.

This product drives tmux rather than mocking it. The selected executable comes
from `LIBTMUX_TMUX_BIN`, then the usual installed locations. A suite using
socket names must set `TMUX_TMPDIR` below `/tmp/libtmux-swift-test/` before the
process starts.

## Reference

- [`withTmuxServer(socketFileName:_:)`][api-withtmuxserver] provisions one
  server for a body, and
  [`withNamedTmuxServer(_:)`][api-withnamedtmuxserver] does the same for a
  socket reached by name
- [`namedSocketsAvailable`][api-namedsocketsavailable] says whether the process
  started with `TMUX_TMPDIR` below the test root
- [Testing with libtmux][ref-testing]: an isolated server and how to check
  cleanup failures
- [`Server`][api-server] is the type the body receives

[api-withtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withtmuxserver(socketfilename-_-)/>
[api-withnamedtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withnamedtmuxserver(_-)/>
[api-namedsocketsavailable]: https://libtmux.org/en/swift/latest/reference/namedsocketsavailable/
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[ref-testing]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
