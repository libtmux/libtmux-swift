// The examples in <doc:Modes>, and the mode section of the README.

import LibTmux
import TmuxWorkspace

public func overOneConnection(_ server: Server) async throws -> [String] {
    let names = try await server.using(.connected(to: "main")) { server in
        try await server.sessions().map(\.name)
    }
    return names
}

public func chosenAtRuntime(
    _ server: Server,
    _ shouldAttach: Bool
) async throws -> [Session] {
    let mode: TmuxMode = shouldAttach ? .connected(to: "main") : .direct
    let sessions = try await server.using(mode) { server in
        try await server.sessions()
    }
    return sessions
}

public func aPipelinedBatch(_ server: Server) async throws -> (Int, Int) {
    let counts = try await server.connected(attachingTo: "main") { server, _ in
        async let sessions = server.sessions()
        async let panes = server.panes()
        return try await (sessions.count, panes.count)
    }
    return counts
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

public func namesOverAConnection(_ server: Server) async throws -> [String] {
    let names = try await server.connected(
        attachingTo: "main"
    ) { server, _ in
        try await server.sessions().map(\.name)
    }
    return names
}

public func namesInTheChosenMode(
    _ server: Server,
    _ attachToExisting: Bool
) async throws -> [String] {
    let mode: TmuxMode = attachToExisting ? .connected(to: "main") : .direct
    let names = try await server.using(mode) { server in
        try await server.sessions().map(\.name)
    }
    return names
}
