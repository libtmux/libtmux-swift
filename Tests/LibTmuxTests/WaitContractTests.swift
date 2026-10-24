import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A control client of the server under test that is stopped, not closed.
///
/// tmux stays up until every client has left, so a stopped client keeps the
/// server alive through a `kill-server` for as long as it is held.
private final class StoppedControlClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()

    init(socketPath: String, session: String) throws {
        process.executableURL = URL(fileURLWithPath: tmuxExecutablePath())
        process.arguments = ["-S", socketPath, "-C", "attach", "-t", session]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() { kill(process.processIdentifier, SIGSTOP) }

    func release() {
        kill(process.processIdentifier, SIGCONT)
        process.terminate()
        process.waitUntilExit()
    }
}

/// What a wait answers when the pane, or the whole server, is taken away.
///
/// Every case runs on whichever path the lane has: a timer below tmux 3.7 and
/// the control connection from it.
@Suite("waiting for output: what ends a wait", .timeLimit(.minutes(5)))
struct WaitContractTests {
    private func bootstrapPane(_ server: Server) async throws -> Pane {
        try #require(try await server.panes().first)
    }

    /// Starts a wait that nothing satisfies, so only the pane or the server
    /// going away can end it.
    private func unsatisfiableWait(
        _ server: Server, in pane: Pane, timeout: Duration = .seconds(20)
    ) -> Task<OutputWait, any Error> {
        Task {
            try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("never-appears-anywhere")],
                timeout: timeout)
        }
    }

    /// Prints `marker` in `pane` after `wait` has started, and gives the wait
    /// time to read it, so the output it reports back was seen during the wait.
    private func emit(
        _ marker: String, in pane: Pane, during server: Server
    ) async throws {
        try await Task.sleep(for: .milliseconds(500))
        try await server.run("echo \(marker); sleep 60", in: pane)
        let seen = try await waitUntil(within: .seconds(15)) {
            try await server.capture(pane).contains { $0.contains(marker) }
        }
        try #require(seen)
        try await Task.sleep(for: .seconds(2))
    }

    /// A second pane, so killing it leaves the server and its session up.
    private func extraPane(_ server: Server) async throws -> Pane {
        let first = try await bootstrapPane(server)
        _ = try await server.run(
            TmuxCommand("split-window", ["-d", "-t", first.id.rawValue, "exec sleep 600"]))
        return try #require(try await server.panes().first { $0.id != first.id })
    }

    // MARK: Wrapped rows

    private static let wrapped =
        "printf '%s%s\\n' \"$(printf '%078d' 0)\" WRAP\"\"NEEDLE"

    @Test("a match split across a wrapped row is found while waiting")
    func wrappedMatchIsFoundWhileWaiting() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let wait = Task {
                try await server.waitForOutput(
                    in: pane,
                    matching: [try RegexPattern("0WRAPNEEDLE")],
                    timeout: .seconds(20))
            }
            try await Task.sleep(for: .milliseconds(500))
            try await server.run(Self.wrapped, in: pane)
            let result = try await wait.value
            #expect(result.outcome == .matched)
        }
    }

    @Test("a match split across a wrapped row is found when it is already on screen")
    func wrappedMatchIsFoundAtEntry() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.run(Self.wrapped, in: pane)
            let drawn = try await waitUntil(within: .seconds(15)) {
                try await server.capture(pane).contains { $0.hasSuffix("APNEEDLE") }
            }
            try #require(drawn)
            let result = try await server.waitForOutput(
                in: pane,
                matching: [try RegexPattern("0WRAPNEEDLE")],
                timeout: .seconds(10))
            #expect(result.outcome == .matched)
            #expect(result.matchedAtEntry)
        }
    }

    @Test("a wrapped row that arrives in two reads is still one line")
    func wrappedRowArrivingInTwoReads() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let wait = Task {
                try await server.waitForOutput(
                    in: pane,
                    matching: [try RegexPattern("0WRAPNEEDLE")],
                    timeout: .seconds(20))
            }
            try await Task.sleep(for: .milliseconds(500))
            // The first half fills a row, the rest lands on the next one a
            // moment later, so no single read holds both halves of the match.
            try await server.run(
                "printf '%s' \"$(printf '%078d' 0)WR\"; sleep 2; printf 'AP''NEEDLE\\n'",
                in: pane)
            let result = try await wait.value
            #expect(result.outcome == .matched)
        }
    }

    // MARK: Pane and server going away

    @Test("a pane killed mid-wait ends it as paneClosed with the output so far")
    func killedPaneEndsTheWait() async throws {
        try await withTmuxServer { server in
            let pane = try await extraPane(server)
            let wait = unsatisfiableWait(server, in: pane)
            try await emit("before-pane-kill", in: pane, during: server)
            try await server.kill(pane)
            let result = try await wait.value
            #expect(result.outcome == .paneClosed)
            #expect(result.tail.contains { $0.contains("before-pane-kill") })
        }
    }

    @Test("a killed server ends the wait as paneClosed with the output so far")
    func killedServerEndsTheWait() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let wait = unsatisfiableWait(server, in: pane)
            try await emit("before-server-kill", in: pane, during: server)
            _ = try await server.run(TmuxCommand("kill-server"))
            let result = try await wait.value
            #expect(result.outcome == .paneClosed)
            #expect(result.tail.contains { $0.contains("before-server-kill") })
        }
    }

    @Test("a killed server gives the same answer while a stopped client keeps it up")
    func killedServerWithAStoppedClient() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else {
                Issue.record("the fixture serves a socket path")
                return
            }
            let pane = try await bootstrapPane(server)
            let client = try StoppedControlClient(socketPath: path, session: "bootstrap")
            defer { client.release() }
            let attached = try await waitUntil(within: .seconds(15)) {
                try await server.clients().contains { $0.isControlMode }
            }
            try #require(attached)
            client.stop()
            let wait = unsatisfiableWait(server, in: pane)
            try await emit("before-stopped-kill", in: pane, during: server)
            _ = try await server.run(TmuxCommand("kill-server"))
            let result = try await wait.value
            #expect(result.outcome == .paneClosed)
            #expect(result.tail.contains { $0.contains("before-stopped-kill") })
        }
    }

    @Test(
        "a dropped stream with the pane alive is not a closed pane",
        .enabled(if: laneSupportsControl, "control mode needs tmux 3.7"))
    func droppedStreamIsNotAClosedPane() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let wait = unsatisfiableWait(server, in: pane)
            try await emit("stream-alive", in: pane, during: server)
            let clients = try await server.clients().filter(\.isControlMode)
            try #require(!clients.isEmpty)
            for client in clients {
                _ = try await server.run(TmuxCommand("detach-client", ["-t", client.name]))
            }
            do {
                let result = try await wait.value
                Issue.record("the wait ended as \(result.outcome), want connectionClosed")
            } catch {
                #expect(error as? OutputWaitError == .tmux(.connectionClosed))
            }
        }
    }
}
