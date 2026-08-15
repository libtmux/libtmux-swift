// The examples in <doc:Snapshots>.

import LibTmux

func walkOneConsistentPicture(_ server: Server, _ session: Session) async throws {
    let snapshot = try await server.snapshot()
    for window in snapshot.windows(of: session) {
        print(window.name, snapshot.panes(of: window).count)
    }
}

func talkToTheServerThatLaunchedYou() async throws {
    if let context = TmuxContext.current() {
        let server = try context.server()
        let here = try await server.sessions().first { $0.id == context.sessionID }
        print(here?.name ?? "not in a session")
    }
}
