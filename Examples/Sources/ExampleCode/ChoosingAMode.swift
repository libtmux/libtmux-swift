// The examples in <doc:Modes>, and the mode section of the README.

import LibTmux
import TmuxWorkspace

public func overOneConnection(_ server: Server) async throws -> [String] {
    let names = try await server.using(.connected(to: "main")) { server in
        try await server.sessions().map(\.name)
    }
    return names
}

public func chosenAtRuntime(_ server: Server, _ shouldAttach: Bool) async throws -> [Session] {
    let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
    let sessions = try await server.using(mode) { server in
        try await server.sessions()
    }
    return sessions
}

public func boundedByATimeout(_ server: Server) async throws -> [Session] {
    let sessions = try await server.withTimeout(.seconds(5)).sessions()
    return sessions
}

public func aWaitWithItsOwnBound(_ server: Server, _ channel: String) async throws -> Bool {
    do {
        try await server.withTimeout(.seconds(5)).wait(
            for: channel,
            timeout: .milliseconds(250)
        )
        return true
    } catch TmuxError.timedOut {
        // The wait took its own bound rather than the server's five seconds.
        return false
    }
}

public func aPipelinedBatch(_ server: Server) async throws -> (Int, Int) {
    let (sessions, panes) = try await server.connected(attachingTo: "main") { server, _ in
        async let sessions = server.sessions()
        async let panes = server.panes()
        return try await (sessions, panes)
    }
    return (sessions.count, panes.count)
}

public func aConsumerThatNeverMentionsAMode(
    _ server: Server,
    _ workspace: Workspace
) async throws -> Session {
    let session = try await server.connected(attachingTo: "main") { server, _ in
        try await WorkspaceBuilder.build(workspace, on: server)
    }
    return session
}
