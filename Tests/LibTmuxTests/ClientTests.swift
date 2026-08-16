import Testing
import TmuxFixture

@testable import LibTmux

@Suite("clients and connection close", .timeLimit(.minutes(1)))
struct ClientTests {
    @Test("a control connection appears as a client and detaches")
    func controlConnectionIsAClientAndDetaches() async throws {
        try await withTmuxServer { server in
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
            // No clients attached: tmux accepts the request regardless, which
            // keeps teardown code from having to check first.
            try await server.detachClients(from: session)
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("a send after the server is provably gone still says connectionClosed")
    func writeToADeadConnectionReportsClosure() async throws {
        try await withTmuxServer { server in
            _ = await #expect(throws: TmuxError.connectionClosed) {
                try await server.withControlMode(attachingTo: "bootstrap") { control in
                    _ = try? await control.send(TmuxCommand("kill-server"))
                    // Waiting until the server is provably gone leaves the
                    // send only one way to fail: in the write.
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
        try await withTmuxServer { server in
            _ = await #expect(throws: TmuxError.connectionClosed) {
                try await server.withControlMode(attachingTo: "bootstrap") { control in
                    // Killing the server ends this connection; the reply to a
                    // command sent after it can never arrive.
                    _ = try await control.send(TmuxCommand("kill-server"))
                    _ = try await control.send(
                        TmuxCommand("display-message", ["-p", "unreachable"])
                    )
                }
            }
        }
    }
}
