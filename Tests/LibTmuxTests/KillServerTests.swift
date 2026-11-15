import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

extension Tag {
    /// Cases that take long enough, or fail rarely enough, that they run on request.
    @Tag static var slow: Self
}

/// A process boundary for a daemon that has been told to exit.
///
/// It answers `kill-server` with a fixed reply, then each endpoint probe with
/// the next state in `probes`, repeating the last one once they run out.
private actor DyingDaemon: ProcessTransport {
    enum State {
        /// The listener is still open and drops every connection.
        case closing
        /// Nothing listens any more.
        case absent
        /// A daemon answers.
        case answering
    }

    private let killReply: TmuxReply
    private var probes: [State]
    private(set) var probeCount = 0
    private(set) var killCount = 0

    init(kill: TmuxReply, probes: [State]) {
        self.killReply = kill
        self.probes = probes
    }

    func run(
        executable _: String, arguments: [String], environment _: [String: String],
        perStreamOutputLimit _: Int
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains("kill-server") {
            killCount += 1
            return killReply
        }
        probeCount += 1
        let state = probes.count > 1 ? probes.removeFirst() : (probes.first ?? .absent)
        switch state {
        case .closing: return Self.reply(error: "server exited unexpectedly\n")
        case .absent:
            return Self.reply(
                error: "no server running on /tmp/libtmux-swift-test/kill-script/socket\n")
        case .answering:
            return TmuxReply(standardOutput: Array("$0\n".utf8), standardError: [], exitCode: 0)
        }
    }

    static func reply(error: String = "") -> TmuxReply {
        TmuxReply(
            standardOutput: [], standardError: Array(error.utf8), exitCode: error.isEmpty ? 0 : 1)
    }
}

@Suite("killing the server", .timeLimit(.minutes(5)))
struct KillServerTests {
    private func server(_ daemon: DyingDaemon) throws -> Server {
        Server(
            endpoint: try Endpoint(
                socketPath: "/tmp/libtmux-swift-test/kill-script/socket"),
            tmuxExecutable: "/usr/bin/tmux", transport: daemon)
    }

    @Test("killServer returns only once the listener has closed")
    func waitsForTheListenerToClose() async throws {
        let daemon = DyingDaemon(kill: DyingDaemon.reply(), probes: [.closing, .closing, .absent])
        try await server(daemon).killServer()
        #expect(await daemon.probeCount == 3)
    }

    @Test("a kill-server reply that is the dropped connection counts once the endpoint is quiet")
    func droppedReplyCountsOnceQuiet() async throws {
        let daemon = DyingDaemon(
            kill: DyingDaemon.reply(error: "server exited unexpectedly\n"),
            probes: [.closing, .absent])
        try await server(daemon).killServer()
        #expect(await daemon.probeCount == 2)
    }

    @Test("a dropped reply with a daemon still answering is a failure")
    func droppedReplyWithALiveDaemonFails() async throws {
        let daemon = DyingDaemon(
            kill: DyingDaemon.reply(error: "server exited unexpectedly\n"),
            probes: [.answering])
        await #expect(throws: TmuxError.invocationFailed(reason: "server exited unexpectedly")) {
            try await server(daemon).killServer()
        }
    }

    @Test("a daemon that never stops accepting connections is reported")
    func unendingShutdownIsReported() async throws {
        let daemon = DyingDaemon(kill: DyingDaemon.reply(), probes: [.closing])
        await #expect(throws: TmuxError.self) {
            try await server(daemon).killServer(stopWithin: .milliseconds(100))
        }
        #expect(await daemon.probeCount > 1)
    }

    @Test("a refused kill-server is reported without waiting")
    func refusalIsNotWaitedOn() async throws {
        let daemon = DyingDaemon(
            kill: DyingDaemon.reply(error: "no server running on /tmp/s\n"), probes: [.absent])
        await #expect(throws: TmuxError.invocationFailed(reason: "no server running on /tmp/s")) {
            try await server(daemon).killServer()
        }
        #expect(await daemon.probeCount == 0)
    }
}

/// Rounds of a kill and an immediate replacement against real tmux.
///
/// The gap is a few milliseconds on an idle machine and wider on a loaded one,
/// so a round fails rarely. Pin the run to one core beside a busy loop to
/// widen it:
///
///     LIBTMUX_TEST_SLOW=1 taskset -c 0 Scripts/swift-test --filter replacementAfterKillServer
@Suite("killing the server against tmux", .timeLimit(.minutes(5)))
struct KillServerLoopTests {
    @Test(
        "a replacement started right after killServer never meets the dying daemon",
        .tags(.slow),
        .enabled(
            if: ProcessInfo.processInfo.environment["LIBTMUX_TEST_SLOW"] != nil,
            "the loop takes about a minute; set LIBTMUX_TEST_SLOW to run it")
    )
    func replacementAfterKillServer() async throws {
        let rounds =
            ProcessInfo.processInfo.environment["LIBTMUX_TEST_KILL_ROUNDS"].flatMap(Int.init)
            ?? 200
        try await withTmuxServer { server in
            for round in 0..<rounds {
                let before = try await server.incarnation()
                try await server.killServer()
                // A pane blocked on a client of its own, as a retained run leaves.
                let reply = try await server.run(
                    TmuxCommand(
                        "new-session",
                        [
                            "-d", "-s", "round-\(round)",
                            "\(server.shellInvocation) wait-for round-\(round)",
                        ]
                    )
                )
                #expect(reply.isSuccess, "round \(round): \(reply.errorText)")
                #expect(try await server.incarnation() != before, "round \(round)")
            }
        }
    }
}
