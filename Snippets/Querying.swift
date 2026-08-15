// The examples in the README's "Ask what is there" section.

import LibTmux

func askWhatExists(_ server: Server) async throws {
    let sessions = try await server.sessions()
    let windows = try await server.windows()
    let panes = try await server.panes()
    print(sessions.count, windows.count, panes.count)
}

func readWhatEachPaneIsDoing(_ server: Server) async throws {
    for pane in try await server.panes() {
        print(pane.id, pane.currentCommand, pane.currentPath)
    }
}

func askBeforeActing(_ server: Server) async throws {
    guard try await server.hasSession("work") else { return }
    print("already there")
}

func anythingTheLibraryDoesNotModel(_ server: Server) async throws {
    let reply = try await server.run(
        TmuxCommand("display-message", ["-p", "#{client_termname}"])
    )
    print(reply.isSuccess ? reply.text : reply.errorText)
}
