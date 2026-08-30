import Testing
import TmuxFixture

@testable import LibTmux

@Suite("bounded process transport", .timeLimit(.minutes(1)))
struct TransportLimitTests {
    @Test("public direct commands have a finite output boundary")
    func publicCommandBoundsOutput() async throws {
        let endpoint = try Endpoint(
            socketPath: "/tmp/libtmux-swift-test/public-transport-limit/socket"
        )
        let limit = 1_048_576
        let server = Server(
            endpoint: endpoint,
            transport: FixedReplyTransport(
                reply: TmuxReply(
                    standardOutput: [UInt8](repeating: 0x78, count: limit + 1),
                    standardError: [],
                    exitCode: 0
                )
            )
        )

        await #expect(
            throws: TmuxError.outputLimitExceeded(perStreamBytes: limit)
        ) {
            try await server.run(TmuxCommand("display-message"))
        }
    }

    @Test("an isolated command fails closed when output exceeds its limit")
    func isolatedCommandBoundsOutput() async throws {
        try await withTmuxServer { server in
            let value = String(repeating: "x", count: 4_096)
            try await server.setBuffer(value, named: "bounded-output")

            await #expect(
                throws: TmuxError.outputLimitExceeded(perStreamBytes: 128)
            ) {
                try await server.runIsolated(
                    TmuxCommand("show-buffer", ["-b", "bounded-output"]),
                    perStreamOutputLimit: 128
                )
            }

            #expect(try await server.isRunning())
        }
    }

    @Test("a transport that ignores the limit still fails closed")
    func runtimeChecksEachStreamAtTheBoundary() async throws {
        let endpoint = try Endpoint(
            socketPath: "/tmp/libtmux-swift-test/transport-limit/socket"
        )
        let exact = Server(
            endpoint: endpoint,
            transport: FixedReplyTransport(
                reply:
                    TmuxReply(
                        standardOutput: Array("1234".utf8),
                        standardError: Array("abcd".utf8),
                        exitCode: 0
                    )
            )
        )
        let reply = try await exact.runIsolated(
            TmuxCommand("display-message"),
            perStreamOutputLimit: 4
        )
        #expect(reply.standardOutput.count == 4)
        #expect(reply.standardError.count == 4)

        let oversizedError = Server(
            endpoint: endpoint,
            transport: FixedReplyTransport(
                reply:
                    TmuxReply(
                        standardOutput: [],
                        standardError: Array("abcde".utf8),
                        exitCode: 0
                    )
            )
        )
        await #expect(
            throws: TmuxError.outputLimitExceeded(perStreamBytes: 4)
        ) {
            try await oversizedError.runIsolated(
                TmuxCommand("display-message"),
                perStreamOutputLimit: 4
            )
        }
    }

    @Test("a replacement daemon cannot receive an isolated command")
    func replacementCannotReceiveIsolatedCommand() async throws {
        try await withTmuxServer { server in
            let stale = try await server.incarnation()
            _ = try await server.run(TmuxCommand("kill-server"))
            _ = try await server.run(
                TmuxCommand("new-session", ["-d", "-s", "replacement"])
            )

            await #expect(throws: TmuxError.serverRestarted) {
                try await server.runIsolated(
                    TmuxCommand("set-option", ["-g", "@isolated-guard", "ran"]),
                    expecting: stale,
                    perStreamOutputLimit: 128
                )
            }
            #expect(try await server.option("@isolated-guard", scope: .globalSession) == nil)
        }
    }

    @Test("a stale server termination cannot kill a replacement daemon")
    func staleTerminationCannotKillReplacement() async throws {
        try await withTmuxServer { server in
            let stale = try await server.incarnation()
            _ = try await server.run(TmuxCommand("kill-server"))
            _ = try await server.run(
                TmuxCommand("new-session", ["-d", "-s", "replacement"])
            )

            await #expect(throws: TmuxError.serverRestarted) {
                try await server.killServer(expecting: stale)
            }
            #expect(try await server.isRunning())
        }
    }

    @Test("a client that never starts is distinguishable from an ambiguous failure")
    func launchFailureIsDefinite() async throws {
        try await withTmuxServer { fixture in
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: "/libtmux-swift-test/missing-tmux"
            )
            do {
                _ = try await server.version()
                Issue.record("the missing executable started")
            } catch let error as TmuxError {
                guard case .processLaunchFailed = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
            }
        }
    }
}

private struct FixedReplyTransport: ProcessTransport {
    let reply: TmuxReply

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        reply
    }
}
