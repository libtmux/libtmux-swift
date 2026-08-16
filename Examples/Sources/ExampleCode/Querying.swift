// The examples in the README's "Ask what is there" section.
//
// Each function holds the documented lines verbatim — the `print` the page
// shows included — and then returns what it printed. The documented block still
// appears as a consecutive run of lines, so `check_examples.py` matches it; the
// trailing `return` is what lets a test assert on the same code the reader is
// shown. One copy, compiled as a consumer and executed.

import LibTmux

public func askWhatExists(_ server: Server) async throws -> (Int, Int, Int) {
    let sessions = try await server.sessions()
    let windows = try await server.windows()
    let panes = try await server.panes()
    print(sessions.count, windows.count, panes.count)
    return (sessions.count, windows.count, panes.count)
}

public func readWhatEachPaneIsDoing(_ server: Server) async throws -> [Pane] {
    for pane in try await server.panes() {
        print(pane.id, pane.currentCommand, pane.currentPath)
    }
    return try await server.panes()
}

// Void, because the documented block ends in a bare `return` and a value would
// have to be threaded around it. What a test can still assert is that it
// reaches a live server and comes back without throwing, on both branches.
public func askBeforeActing(_ server: Server) async throws {
    guard try await server.hasSession("work") else { return }
    print("already there")
}

public func anythingTheLibraryDoesNotModel(_ server: Server) async throws -> String {
    let reply = try await server.run(
        TmuxCommand("display-message", ["-p", "#{client_termname}"])
    )
    print(reply.isSuccess ? reply.text : reply.errorText)
    return reply.isSuccess ? reply.text : reply.errorText
}
