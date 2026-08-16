// The examples in <doc:Snapshots>.

import LibTmux

public func walkOneConsistentPicture(
    _ server: Server,
    _ session: Session
) async throws -> Snapshot {
    let snapshot = try await server.snapshot()
    for window in snapshot.windows(of: session) {
        print(window.name, snapshot.panes(of: window).count)
    }
    return snapshot
}

// Compiled, never executed: `TmuxContext.current()` is only non-nil inside a
// tmux pane, and this process is the test runner. `ContextTests` covers the
// same ground live by asking the question from inside a pane, which needs a
// command rather than a Swift call.
public func talkToTheServerThatLaunchedYou() async throws {
    if let context = TmuxContext.current() {
        let server = try context.server()
        let here = try await server.sessions().first { $0.id == context.sessionID }
        print(here?.name ?? "not in a session")
    }
}
