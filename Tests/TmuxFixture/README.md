# `TmuxTestSupport`

Provisions an isolated real tmux server for a test or benchmark and reaps it
when the body returns, throws, or its owning process is killed.

The package product is `TmuxTestSupport`; the module it exports is
`TmuxFixture`:

```swift
.product(name: "TmuxTestSupport", package: "libtmux-swift")
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
