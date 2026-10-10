# Owning resources and testing examples

Use `Server()` for normal tmux defaults. Use an owned scope when your code accepts responsibility for destroying a remote object. Closing a client connection leaves tmux objects running.

## Automatic examples and test fixtures

This complete program creates a session, a window and a pane. Each `withValue` waits for that owner's cleanup before returning. The examples harness supplies socket defaults in its child environment; the displayed source stays unchanged.

```swift
import Foundation
import LibTmux

let server = try Server()
let session = try await server.newOwnedSession(named: "example-\(UUID().uuidString.prefix(8))")
try await session.withValue { session in
    let window = try await server.newOwnedWindow(in: session, named: "logs")
    try await window.withValue { window in
        guard let pane = try await server.panes().first(where: { $0.windowID == window.id }) else {
            throw TmuxError.staleServerValue
        }
        let split = try await server.splitOwned(pane)
        try await split.withValue { pane in
            print("Working in pane \(pane.id)")
        }
    }
}
print("Owned hierarchy cleaned up")
```

## Ownership of existing objects

`adopt` accepts a server, session, window or pane for cleanup. Here the program adopts a session it created through the existing borrowed API. Renaming it does not change the captured ID. Lookup and discovery return borrowed values.

```swift
import Foundation
import LibTmux

let server = try Server()
let session = try await server.newSession(named: "example-\(UUID().uuidString.prefix(8))")
let owner = try await server.adopt(session)
try await owner.withValue { session in
    try await server.rename(session, to: "renamed-\(UUID().uuidString.prefix(8))")
    print("Accepted cleanup of session \(session.id)")
}
print("Adopted session cleaned up")
```

Adoption initializes the reserved server option `@libtmux_owner_generation` if absent. A valid existing token stays unchanged; an empty or malformed value fails. The token contains 32 hexadecimal characters. Do not change or shadow this option. Cleanup checks the token and daemon identity inside tmux before addressing the captured object ID. A window owner destroys all links to that window, not one session's appearance.

## Socket discovery

Discovery reads the current user's configured tmux socket directory by default. Pass `in:`, `environment:` or `limits:` for another search. It does not start daemons. The result includes failed probes, skipped filesystem entries and truncation; it does not claim a complete system inventory.

```swift
import LibTmux

let result = try await TmuxServers.discover()
for server in result.servers {
    print("\(server.socketPath): \(server.sessionCount) sessions")
}
for diagnostic in result.diagnostics {
    print("\(diagnostic.kind): \(diagnostic.path): \(diagnostic.detail)")
}
print("Truncated: \(result.truncated)")
```

Default ceilings are 64 roots, 4,096 directory entries, 128 socket probes and eight concurrent clients, with two seconds per probe. Limits have finite upper bounds. The scanner skips final symlink roots and entries while preserving intermediate path-component semantics. Caller cancellation throws instead of returning a partial inventory.

## Find or create

`FindOrCreate.created` carries an owner; `reused` carries a borrowed value. Sessions match exact names. Windows match exact names within one session, and duplicate names throw. Panes match a pane-local `@libtmux_pane_identity` within one window; duplicate identities throw. tmux can rewrite session names and pane option values. The new acquisition calls verify the stored name or identity and roll back a mismatch.

```swift
import Foundation
import LibTmux

let server = try Server()
let session = try await server.findOrCreateSession(named: "example-\(UUID().uuidString.prefix(8))")
try await session.withValue { session in
    let window = try await server.findOrCreateWindow(in: session, named: "logs")
    try await window.withValue { window in
        let pane = try await server.findOrCreatePane(in: window, identity: "log-reader")
        try await pane.withValue { _ in
            let again = try await server.findOrCreatePane(in: window, identity: "log-reader")
            print("First created: \(pane.wasCreated); second created: \(again.wasCreated)")
        }
    }
}
print("New resources cleaned up")
```

`Server.findOrCreate()` applies the same created/reused distinction to the daemon. A per-call variable in the startup client's environment proves that this call started it. A racing foreign daemon stays borrowed; this call removes only its own bootstrap session.

Calls for the same physical socket parent and filename coordinate within one process through 64 fixed gates. Other processes and socket-file symlink aliases remain outside that boundary. Queued callers can cancel. Filesystem resolution preserves `symlink/..` and rejects unresolved `missing/..` instead of changing the target.

## Cleanup scopes and failure handling

Whole-server destruction requires an explicit disposable endpoint in this example. The owner waits for the captured local daemon to exit. Session, window and pane scopes destroy only their captured object.

```swift
import Foundation
import LibTmux

let server = try Server(socketName: "libtmux-swift-example-\(UUID().uuidString.prefix(8))")
let owner = try await server.newOwnedServer(bootstrapSession: "example")
try await owner.withValue { server in
    print("Owned server has \(try await server.sessions().count) session")
}
print("Owned daemon exited")
```

`close()` coalesces concurrent calls. It becomes a no-op after success; failure remains inspectable in `cleanupFailure` and can be retried. `ResourceScopeFailure` retains both the original body error and the cleanup error. The existing `withNewSession` scope retains its `SessionScopeFailure` spelling.

`AcquisitionFailure` retains the original `cause`, any separate `commandFailure`, and the rollback's `cleanupFailure`. `hasReceipt` tells you whether the command yielded a verified cleanup target; `retryCleanup()` retries that target. An absent or contradictory receipt supplies no destruction authority. Adoption failure leaves an existing object intact. Lifecycle calls use their own client so a caller's control connection cannot discard a receipt. Caller cancellation is reported after the bounded client drains, with a ten-second client deadline. Cleanup runs in an awaited detached task. Adoption, cleanup and discovery clients pass tmux’s `-N` flag so they cannot start a missing daemon.

## Environment variables for defaults

The normal constructor captures explicit selectors, then `LIBTMUX_SOCKET_PATH`, `LIBTMUX_SOCKET_NAME`, `TMUX`, or tmux's named default, in that order. `TMUX_TMPDIR` supplies the named socket parent. `environment:` replaces the inherited child-process environment without changing the host process. It is separate from tmux's server/session environment APIs; there is no `LIBTMUX_SOCKET_ENV` variable.

The test harness sets those variables before starting each unchanged program. A shell command can also give one execution its socket name:

```console
LIBTMUX_SOCKET_NAME=my-docs swift run --package-path Examples OwnedHierarchy
```

That example cleans up its own session hierarchy. A caller who selects an existing server keeps responsibility for that server's other sessions. No global environment guard is exported; use a child environment to avoid concurrent mutation.

## Sandbox and example testing

`TmuxFixture` is for tests that need a private daemon. It shields teardown from body cancellation and exposes a cleanup failure with the retained root. Ordinary completion removes files only after observing the owned daemon's exit. A crash reaper signals the captured daemon PID and retains the root because a tmux job cannot verify exit after its own daemon terminates. An outer harness must observe exit before removing that root.

```swift
import LibTmux
import TmuxFixture

try await withTmuxServer { server in
    try await server.withNewSession(named: "fixture-example") { session in
        print("Fixture session: \(session.name)")
    }
}
print("Fixture daemon exited and its root was removed")
```

The consumer package builds these programs through public products. `Scripts/check_examples.py` compares displayed Swift fences with that source; the live example suite executes the same files. The separate harness checks each program’s output and keeper session, then observes its captured daemon PIDs during outer cleanup and checks that the host environment stayed unchanged. Each whole-server owner also observes its daemon before returning; the external harness does not independently capture a daemon that exits before its final scan. The ordinary-program harness also checks a body failure and an intentional disabled-cleanup mutation.

Markdown, Astro Markdown/MDX, Sphinx reStructuredText/MyST and Python doctest remain in the cross-port example-testing scope. These Swift source files and fence checks do not constitute format-aware execution adapters. The standalone format prototypes live in the project plan; repository adapter integration and independent acceptance remain pending.
