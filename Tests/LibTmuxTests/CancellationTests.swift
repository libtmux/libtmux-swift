import Foundation
import Synchronization
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("cancellation", .timeLimit(.minutes(5)))
struct CancellationTests {
    /// `wait-for` blocks until something signals the channel, which is the
    /// simplest tmux command that reliably does not return on its own.
    private func blockingCommand() -> TmuxCommand {
        TmuxCommand("wait-for", ["libtmux-cancellation-channel"])
    }

    @Test("a cancelled request reports cancellation rather than an empty answer")
    func cancelledRequestReportsCancellation() async throws {
        try await withTmuxServer { server in
            let blocked = Task {
                try await server.run(blockingCommand())
            }
            // Let the child reach the point where it is waiting.
            try await Task.sleep(for: .milliseconds(200))
            blocked.cancel()

            do {
                _ = try await blocked.value
                Issue.record("a cancelled request returned a reply")
            } catch let error as TmuxError {
                // Never an empty result: that is indistinguishable from a
                // server with nothing to report.
                #expect(error == .cancelled)
            }
        }
    }

    @Test("cancelling one request leaves the server usable")
    func cancellingOneRequestLeavesTheServerUsable() async throws {
        try await withTmuxServer { server in
            let blocked = Task { try await server.run(blockingCommand()) }
            try await Task.sleep(for: .milliseconds(200))
            blocked.cancel()
            _ = try? await blocked.value

            // The cancelled client is gone; the server it spoke to is not.
            let running = try await server.isRunning()
            #expect(running)
            let sessions = try await server.sessions()
            #expect(sessions.map(\.name) == ["bootstrap"])
        }
    }

    @Test("a cancelled request leaves no client attached to the server")
    func cancelledRequestLeavesNoClient() async throws {
        try await withTmuxServer { server in
            let blocked = Task { try await server.run(blockingCommand()) }
            try await Task.sleep(for: .milliseconds(200))
            blocked.cancel()
            _ = try? await blocked.value

            // A child that survived its cancellation would still be holding a
            // connection open.
            var clients = try await server.clients()
            for _ in 0..<100 where !clients.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                clients = try await server.clients()
            }
            #expect(clients.isEmpty)
        }
    }

    @Test("cancelling before the request starts never reaches tmux")
    func cancellingBeforeStartNeverReachesTmux() async throws {
        try await withTmuxServer { server in
            let task = Task {
                // Cancelled while still suspended, before any spawn.
                try await Task.sleep(for: .seconds(30))
                return try await server.run(TmuxCommand("kill-server"))
            }
            task.cancel()
            _ = try? await task.value

            // If the command had run, the server would be gone.
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("many cancelled requests do not accumulate children")
    func manyCancelledRequestsDoNotAccumulate() async throws {
        try await withTmuxServer { server in
            for _ in 0..<8 {
                let blocked = Task { try await server.run(blockingCommand()) }
                try await Task.sleep(for: .milliseconds(80))
                blocked.cancel()
                _ = try? await blocked.value
            }

            var clients = try await server.clients()
            for _ in 0..<100 where !clients.isEmpty {
                try await Task.sleep(for: .milliseconds(20))
                clients = try await server.clients()
            }
            #expect(clients.isEmpty)

            let running = try await server.isRunning()
            #expect(running)
        }
    }

    /// A tmux that does not answer, so the first version probe stays in flight.
    private func withStallingTmux(
        _ body: (Server) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("stall-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("tmux")
        try "#!/bin/sh\nexec sleep 15\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path)
        let server = try Server(
            socketPath: root.appendingPathComponent("s").path, tmuxExecutable: script.path)
        try await body(server)
    }

    private func sessionsOutcome(_ server: Server) -> Task<String, Never> {
        Task {
            do {
                _ = try await server.sessions()
                return "returned"
            } catch let error as TmuxError {
                return error == .cancelled ? "cancelled" : "threw \(error)"
            } catch {
                return "threw \(error)"
            }
        }
    }

    @Test("a caller cancelled during the first version probe resumes at once")
    func cancelledDuringFirstProbe() async throws {
        try await withStallingTmux { server in
            let clock = ContinuousClock()
            let caller = sessionsOutcome(server)
            try await Task.sleep(for: .milliseconds(500))
            let start = clock.now
            caller.cancel()
            let outcome = await caller.value
            let elapsed = start.duration(to: clock.now)
            #expect(outcome == "cancelled")
            #expect(elapsed < .seconds(5), "resumed after \(elapsed), the stall is 15 s")
        }
    }

    @Test("cancelling one caller of a shared version probe leaves the others waiting")
    func cancelledCallerDoesNotFailOtherWaiters() async throws {
        try await withStallingTmux { server in
            let clock = ContinuousClock()
            let first = sessionsOutcome(server)
            let second = sessionsOutcome(server)
            try await Task.sleep(for: .milliseconds(500))
            first.cancel()
            #expect(await first.value == "cancelled")

            // The probe is still in flight for the second caller.
            let finished = Mutex(false)
            let watcher = Task {
                let outcome = await second.value
                finished.withLock { $0 = true }
                return outcome
            }
            try await Task.sleep(for: .seconds(1))
            #expect(
                !finished.withLock { $0 }, "the second caller was resumed by the first's cancel")

            let start = clock.now
            second.cancel()
            #expect(await watcher.value == "cancelled")
            #expect(start.duration(to: clock.now) < .seconds(5))
        }
    }
}
