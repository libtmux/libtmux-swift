import Testing

@testable import LibTmux

@Suite("new session")
struct NewSessionTests {
    @Test("a replacement cannot reuse the created session's id")
    func replacementCannotReuseTheCreatedID() async throws {
        let socketPath = "/tmp/libtmux-swift-test/new-session-atomic/socket"
        let endpoint = try Endpoint(socketPath: socketPath)
        let transport = SessionReplacementTransport(socketPath: socketPath)
        let server = Server(
            endpoint: endpoint,
            transport: transport
        )

        let session = try await server.newSession(named: "created")

        #expect(session.id == "$7")
        #expect(session.name == "created")
        #expect(session.windowCount == 1)
        #expect(!session.isAttached)
        #expect(session.createdAt == 100)
        #expect(
            session.incarnation
                == ServerIncarnation(
                    endpoint: endpoint,
                    socketPath: socketPath,
                    processID: 700,
                    startedAt: 900
                )
        )
        #expect(await transport.invocationCount == 1)
    }
}

private actor SessionReplacementTransport: ProcessTransport {
    let socketPath: String
    private(set) var invocationCount = 0

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        invocationCount += 1
        guard
            let command = arguments.first(where: {
                $0 == "new-session" || $0 == "list-sessions"
            })
        else {
            throw .invocationFailed(reason: "unexpected command")
        }
        let replacement = command == "list-sessions"
        return try reply(
            to: arguments,
            values: [
                "session_id": "$7",
                "session_name": replacement ? "replacement" : "created",
                "session_windows": replacement ? "2" : "1",
                "session_attached": replacement ? "1" : "0",
                "session_created": replacement ? "101" : "100",
                "socket_path": socketPath,
                "pid": replacement ? "701" : "700",
                "start_time": replacement ? "901" : "900",
            ]
        )
    }

    private func reply(
        to arguments: [String],
        values: [String: String]
    ) throws(TmuxError) -> TmuxReply {
        guard let flag = arguments.firstIndex(of: "-F"), arguments.indices.contains(flag + 1)
        else {
            throw .invocationFailed(reason: "missing format")
        }
        let rendered = values.reduce(arguments[flag + 1]) { output, field in
            output.replacingOccurrences(of: "#{\(field.key)}", with: field.value)
        }
        guard !rendered.contains("#{") else {
            throw .invocationFailed(reason: "unknown format field")
        }
        return TmuxReply(
            standardOutput: Array("\(rendered)\n".utf8),
            standardError: [],
            exitCode: 0
        )
    }
}
