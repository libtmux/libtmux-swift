import Testing
import TmuxFixture

@testable import LibTmux

@Suite("bounded process transport", .timeLimit(.minutes(1)))
struct TransportLimitTests {
    @Test("an isolated command fails closed when output exceeds its limit")
    func isolatedCommandBoundsOutput() async throws {
        try await withTmuxServer { server in
            let value = String(repeating: "x", count: 4_096)
            try await server.setBuffer(value, named: "bounded-output")

            await #expect(
                throws: TmuxError.invocationFailed(
                    reason: "tmux output exceeded 128 bytes per stream"
                )
            ) {
                try await server.runIsolated(
                    TmuxCommand("show-buffer", ["-b", "bounded-output"]),
                    perStreamOutputLimit: 128
                )
            }

            #expect(try await server.isRunning())
        }
    }

    @Test("the compatibility transport checks each stream at the boundary")
    func compatibilityTransportChecksEachStream() async throws {
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
            throws: TmuxError.invocationFailed(
                reason: "tmux output exceeded 4 bytes per stream"
            )
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
            let stale = try #require(try await server.incarnation())
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
            let option = try await server.run(
                TmuxCommand("show-options", ["-gv", "@isolated-guard"])
            )
            #expect(!option.isSuccess)
        }
    }
}

private struct FixedReplyTransport: ProcessTransport {
    let reply: TmuxReply

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        reply
    }
}
