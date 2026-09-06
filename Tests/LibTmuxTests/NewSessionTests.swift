import Testing

@testable import LibTmux

@Suite("new session")
struct NewSessionTests {
    @Test("a replacement cannot reuse the created session's id")
    func replacementCannotReuseTheCreatedID() async throws {
        let socketPath = "/tmp/libtmux-swift-test/new-session-atomic/socket"
        let endpoint = try Endpoint(socketPath: socketPath)
        let transport = NewSessionTransport(socketPath: socketPath)
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

    @Test("a changed requested size is repaired on the created window")
    func changedRequestedSizeIsRepaired() async throws {
        let socketPath = "/tmp/libtmux-swift-test/new-session-size/socket"
        let transport = NewSessionTransport(
            socketPath: socketPath,
            reportedWidth: 80,
            reportedHeight: 23
        )
        let server = Server(
            endpoint: try Endpoint(socketPath: socketPath),
            transport: transport
        )

        _ = try await server.newSession(named: "sized", width: 111, height: 41)

        #expect(await transport.invocationCount == 2)
        let resize = try #require(await transport.resizeArguments)
        let command = resize.joined(separator: " ")
        #expect(command.contains("resize-window"))
        #expect(command.contains("@4"))
        #expect(command.contains("-x 111"))
        #expect(command.contains("-y 41"))
    }

    @Test("an honored requested size needs no repair")
    func honoredRequestedSizeNeedsNoRepair() async throws {
        let socketPath = "/tmp/libtmux-swift-test/new-session-size-match/socket"
        let transport = NewSessionTransport(
            socketPath: socketPath,
            reportedWidth: 111,
            reportedHeight: 41
        )
        let server = Server(
            endpoint: try Endpoint(socketPath: socketPath),
            transport: transport
        )

        _ = try await server.newSession(named: "sized", width: 111, height: 41)

        #expect(await transport.invocationCount == 1)
        #expect(await transport.resizeArguments == nil)
    }

    @Test("a rejected size repair reports the partial outcome")
    func rejectedSizeRepairReportsPartialOutcome() async throws {
        let socketPath = "/tmp/libtmux-swift-test/new-session-size-failure/socket"
        let transport = NewSessionTransport(
            socketPath: socketPath,
            reportedWidth: 80,
            reportedHeight: 23,
            rejectsResize: true
        )
        let server = Server(
            endpoint: try Endpoint(socketPath: socketPath),
            transport: transport
        )

        await #expect(throws: TmuxError.invocationFailed(reason: "resize rejected")) {
            _ = try await server.newSession(named: "sized", width: 111, height: 41)
        }
        #expect(await transport.invocationCount == 2)
    }
}

private actor NewSessionTransport: ProcessTransport {
    let socketPath: String
    let reportedWidth: Int
    let reportedHeight: Int
    let rejectsResize: Bool
    private(set) var invocationCount = 0
    private(set) var resizeArguments: [String]?

    init(
        socketPath: String,
        reportedWidth: Int = 80,
        reportedHeight: Int = 23,
        rejectsResize: Bool = false
    ) {
        self.socketPath = socketPath
        self.reportedWidth = reportedWidth
        self.reportedHeight = reportedHeight
        self.rejectsResize = rejectsResize
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        invocationCount += 1
        if arguments.contains(where: { $0.contains("resize-window") }) {
            guard let fence = arguments.first(where: { $0.hasSuffix("_fence") }) else {
                throw .invocationFailed(reason: "guarded resize has no fence")
            }
            resizeArguments = arguments
            let prefix = String(fence.dropLast("_fence".count))
            return TmuxReply(
                standardOutput: Array("\(prefix)_true\n\(fence)\n".utf8),
                standardError: rejectsResize ? Array("resize rejected\n".utf8) : [],
                exitCode: rejectsResize ? 1 : 0
            )
        }
        guard
            let command = arguments.first(where: {
                ["new-session", "list-sessions"].contains($0)
            })
        else { throw .invocationFailed(reason: "unexpected command") }
        let replacement = command == "list-sessions"
        return try reply(
            to: arguments,
            values: [
                "session_id": "$7",
                "session_name": replacement ? "replacement" : "created",
                "session_windows": replacement ? "2" : "1",
                "session_attached": replacement ? "1" : "0",
                "session_created": replacement ? "101" : "100",
                "window_id": "@4",
                "window_name": "created",
                "window_index": "0",
                "window_panes": "1",
                "window_active": "1",
                "window_width": String(reportedWidth),
                "window_height": String(reportedHeight),
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
