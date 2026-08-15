// The examples in <doc:Modes>, and the mode section of the README.

import LibTmux
import TmuxWorkspace

func direct(_ server: Server) async throws {
    let sessions = try await server.sessions()
    print(sessions.count)
}

func overOneConnection(_ server: Server) async throws {
    let names = try await server.using(.connected(to: "main")) { server in
        try await server.sessions().map(\.name)
    }
    print(names)
}

func chosenAtRuntime(_ server: Server, _ shouldAttach: Bool) async throws {
    let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
    let sessions = try await server.using(mode) { server in
        try await server.sessions()
    }
    print(sessions.count)
}

func withTheConnectionHandedOverToo(_ server: Server) async throws {
    let names = try await server.connected(attachingTo: "main") { server, _ in
        try await server.sessions().map(\.name)
    }
    print(names)
}

func aPipelinedBatch(_ server: Server) async throws {
    let (sessions, panes) = try await server.connected(attachingTo: "main") { server, _ in
        async let sessions = server.sessions()
        async let panes = server.panes()
        return try await (sessions, panes)
    }
    print(sessions.count, panes.count)
}

func oneInvocationForAllOfThem(_ server: Server) async throws {
    var plan = TmuxCommandList()
    for name in ["edit", "test", "logs"] {
        plan = plan.then("new-window", ["-d", "-n", name])
    }
    _ = try await server.run(plan)
}

func aConsumerThatNeverMentionsAMode(
    _ server: Server,
    _ workspace: Workspace
) async throws {
    let session = try await server.connected(attachingTo: "main") { server, _ in
        try await WorkspaceBuilder.build(workspace, on: server)
    }
    print(session.name)
}

func beingToldRatherThanAsking(_ server: Server) async throws {
    try await server.connected(attachingTo: "work") { server, events in
        for await notification in events.notifications
        where notification.name == "output" {
            print(notification.arguments)
        }
    }
}
