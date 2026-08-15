import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("cancellation", .timeLimit(.minutes(1)))
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
}
