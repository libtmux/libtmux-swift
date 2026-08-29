import Testing
import TmuxFixture

@testable import LibTmux

@Suite("clients and connection close", .timeLimit(.minutes(1)))
struct ClientTests {
    @Test("a control connection appears as a client and detaches")
    func controlConnectionIsAClientAndDetaches() async throws {
        try await withTmuxServer { server in
            await #expect(throws: TmuxError.connectionClosed) {
                try await server.withControlMode(attachingTo: "bootstrap") { control in
                    _ = try await control.send(TmuxCommand("display-message", ["-p", "hi"]))

                    // The control connection is a real client, reported with the
                    // flag that distinguishes it from a terminal.
                    var clients = try await server.clients()
                    for _ in 0..<100 where clients.isEmpty {
                        try await Task.sleep(for: .milliseconds(20))
                        clients = try await server.clients()
                    }
                    let client = try #require(clients.first)
                    #expect(client.isControlMode)

                    try await server.detach(client)

                    var after = try await server.clients()
                    for _ in 0..<100 where !after.isEmpty {
                        try await Task.sleep(for: .milliseconds(20))
                        after = try await server.clients()
                    }
                    #expect(after.isEmpty)
                }
            }
            // Detaching a client leaves the server and its sessions alone.
            let running = try await server.isRunning()
            #expect(running)
            let sessions = try await server.sessions()
            #expect(sessions.map(\.name) == ["bootstrap"])
        }
    }

    @Test("detaching by session removes that session's clients")
    func detachingBySessionRemovesItsClients() async throws {
        try await withTmuxServer { server in
            let sessions = try await server.sessions()
            let session = try #require(sessions.first)

            await #expect(throws: TmuxError.connectionClosed) {
                try await server.withControlMode(attachingTo: session.id.rawValue) { _ in
                    var clients = try await server.clients()
                    for _ in 0..<100 where clients.isEmpty {
                        try await Task.sleep(for: .milliseconds(20))
                        clients = try await server.clients()
                    }
                    #expect(!clients.isEmpty)

                    try await server.detachClients(from: session)
                    var after = try await server.clients()
                    for _ in 0..<100 where !after.isEmpty {
                        try await Task.sleep(for: .milliseconds(20))
                        after = try await server.clients()
                    }
                    #expect(after.isEmpty)
                }
            }

            // Detaching nobody is also success, so teardown need not list first.
            try await server.detachClients(from: session)
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("a send after the server is gone says it was not submitted")
    func writeToADeadConnectionWasNotSubmitted() async throws {
        try await withTmuxServer { server in
            _ = await #expect(throws: TmuxError.requestNotSubmitted) {
                try await server.withControlMode(attachingTo: "bootstrap") { control in
                    _ = try? await control.send(TmuxCommand("kill-server"))
                    // The connection has already observed its closure, so a
                    // later command cannot have entered its write queue.
                    _ = try await waitUntil { try await !server.isRunning() }
                    _ = try await control.send(
                        TmuxCommand("display-message", ["-p", "unreachable"])
                    )
                }
            }
        }
    }

    @Test("a command still waiting when the connection closes says so")
    func closedConnectionReportsItself() async throws {
        let (writes, witness) = AsyncStream.makeStream(of: Void.self)
        let control = ControlSession(write: { _ in witness.yield() })
        await control.consume("%begin 1 1 0")
        await control.consume("%end 1 1 0")

        let pending = Task {
            try await control.send(TmuxCommand("display-message", ["-p", "unreachable"]))
        }
        var iterator = writes.makeAsyncIterator()
        _ = await iterator.next()
        await control.finish(throwing: TmuxError.connectionClosed)

        await #expect(throws: TmuxError.connectionClosed) {
            try await pending.value
        }
    }
}
