# [`TmuxFixture`][mod-tmuxfixture]

Provisions an isolated real tmux server for a test or benchmark and reaps it
when the body returns, throws, or its owning process is killed.

```swift
.product(name: "TmuxFixture", package: "libtmux-swift")
```

**Contents** — [Quick start](#quick-start) ·
[What it does](#what-the-fixture-does) · [Choose the tmux](#choose-the-tmux) ·
[Named sockets](#named-sockets) · [Reference](#reference)

## Quick start

The package product and module are both [`TmuxFixture`][mod-tmuxfixture]. Import
it beside Swift Testing:

```swift
import Testing
import TmuxFixture

try await withTmuxServer { server in
    let sessions = try await server.sessions()
    #expect(sessions.map(\.name) == ["bootstrap"])
}
```

### [`withTmuxServer`][api-withtmuxserver]: a server of the test's own

`withTmuxServer` hands the body a [`Server`][api-server], and
[`Server.sessions()`][api-server-sessions] lists what it holds. A fresh server
holds one session, `bootstrap`, and `CancellationTests` makes this assertion.

## What the fixture does

- **One server per call**, under `/tmp/libtmux-swift-test/`, with a bootstrap
  session so the server has something to hold it open.
- **Bounded concurrency.** It limits concurrent fixtures so the suite cannot
  exhaust processes or pseudo-terminals.
- **Reaped.** The reaper refuses paths outside this port's test and development
  roots.

## Choose the tmux

This product drives tmux rather than mocking it. The selected executable comes
from `LIBTMUX_TMUX_BIN`, then the usual installed locations.
[`tmuxExecutablePath`][api-tmuxexecutablepath] reports the one a run resolved.

## Named sockets

### [`withNamedTmuxServer`][api-withnamedtmuxserver]: a server addressed by name

`withNamedTmuxServer` serves the half that addresses a socket by name. A suite
using socket names must set `TMUX_TMPDIR` below `/tmp/libtmux-swift-test/`
before the process starts, and
[`namedSocketsAvailable`][api-namedsocketsavailable] says whether it did.

## Reference

- [`withTmuxServer`][api-withtmuxserver] provisions one server for a body, and
  [`withNamedTmuxServer`][api-withnamedtmuxserver] does the same for a socket
  reached by name
- [`namedSocketsAvailable`][api-namedsocketsavailable] says whether the process
  started with `TMUX_TMPDIR` below the test root
- [Testing with libtmux][ref-guide-testing]: an isolated server and how to
  check cleanup failures
- [`Server`][api-server] is the type the body receives
[api-namedsocketsavailable]: https://libtmux.org/en/swift/latest/reference/namedsocketsavailable/
[api-server-sessions]: <https://libtmux.org/en/swift/latest/reference/server-sessions()/>
[api-server]: https://libtmux.org/en/swift/latest/reference/server/
[api-tmuxexecutablepath]: <https://libtmux.org/en/swift/latest/reference/tmuxexecutablepath()/>
[api-withnamedtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withnamedtmuxserver(_-)/>
[api-withtmuxserver]: <https://libtmux.org/en/swift/latest/reference/withtmuxserver(socketfilename-_-)/>
[mod-tmuxfixture]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
[ref-guide-testing]: https://libtmux.org/en/swift/latest/guides/testing-with-libtmux/
