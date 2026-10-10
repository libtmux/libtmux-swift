# `TmuxFixture`

Provisions an isolated real tmux server for a test or benchmark and reaps it
when the body returns, throws, or its owning process is killed.

The package product and module are both `TmuxFixture`:

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

Teardown runs outside body cancellation and retains both body and cleanup failures. Ordinary completion removes the root only after the captured daemon exits. A replacement daemon causes a visible failure and retained root. A test that creates a replacement must accept that replacement through `adopt()` and close its own owner.

After a killed runner, the in-daemon reaper signals its captured daemon PID and retains the root. It cannot observe exit after tmux ends its background job; an outer harness must confirm exit before removing the recorded path. It never sweeps other fixture roots.
