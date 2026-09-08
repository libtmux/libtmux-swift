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
                    let pane = try #require(try await server.panes().first)
                    #expect(client.activePaneID == pane.id)
                    #expect(client.isWindowZoomed == false)

                    try await server.detach(client)
                    try await Task.sleep(for: .seconds(20))
                }
            }
            var after = try await server.clients()
            for _ in 0..<100 where !after.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                after = try await server.clients()
            }
            #expect(after.isEmpty)
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
                    try await Task.sleep(for: .seconds(20))
                }
            }

            var after = try await server.clients()
            for _ in 0..<100 where !after.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                after = try await server.clients()
            }
            #expect(after.isEmpty)

            // Detaching nobody is also success, so teardown need not list first.
            try await server.detachClients(from: session)
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("a send after closure says it was not submitted")
    func writeToClosedConnectionWasNotSubmitted() async {
        let control = ControlSession(write: { _ in })
        await control.finish(throwing: TmuxError.connectionClosed)

        await #expect(throws: TmuxError.requestNotSubmitted) {
            _ = try await control.send(
                TmuxCommand("display-message", ["-p", "unreachable"])
            )
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

    @Test("client attention state is typed and malformed rows fail closed")
    func clientAttentionStateIsStrictlyDecoded() throws {
        var values = [
            "client_name": "/dev/pts/7", "client_tty": "/dev/pts/7",
            "client_pid": "77", "client_width": "80", "client_height": "24",
            "client_control_mode": "0", "session_id": "$2", "pane_id": "%7",
            "window_zoomed_flag": "1",
            "socket_path": "/tmp/libtmux-swift-test/client-attention", "pid": "42",
            "start_time": "9",
        ]
        func encoded() -> [UInt8] {
            let separator = String(FormatProjection.separator)
            let row = Client.projection.fields.map { values[$0.name] ?? "" }
                .joined(separator: separator)
            return Array("\(row)\n".utf8)
        }

        let row = try #require(Client.projection.decode(encoded()).first)
        let client = Client(
            row: row,
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/client-attention")
        )
        #expect(client.activePaneID == "%7")
        #expect(client.isWindowZoomed == true)

        for (field, malformed) in [
            ("pane_id", ""), ("pane_id", "7"),
            ("window_zoomed_flag", ""), ("window_zoomed_flag", "2"),
        ] {
            let original = values[field]
            values[field] = malformed
            #expect(throws: FormatDecodingError.self) {
                try Client.projection.decode(encoded())
            }
            values[field] = original
        }
    }
}
