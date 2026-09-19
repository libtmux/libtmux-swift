import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("cancellation", .hangLimit)
struct CancellationTests {
    /// `wait-for` blocks until something signals the channel, which is the
    /// simplest tmux command that reliably does not return on its own.
    private func blockingCommand() -> TmuxCommand {
        TmuxCommand("wait-for", ["libtmux-cancellation-channel"])
    }

    @Test("a command that never answers ends at its own deadline")
    func boundedCommandEndsAtItsDeadline() async throws {
        try await withTmuxServer { server in
            let bounded = server.withTimeout(.milliseconds(250))
            let started = ContinuousClock.now

            await #expect(throws: TmuxError.timedOut(after: .milliseconds(250))) {
                _ = try await bounded.run(blockingCommand())
            }

            // The bound is the point: without it this call does not return at
            // all, so the elapsed time is the assertion, not decoration.
            #expect(started.duration(to: .now) < .seconds(5))
            // The daemon is untouched -- only this command's client was killed.
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("a bound is a property of the value, not of the server")
    func boundBelongsToTheValue() async throws {
        try await withTmuxServer { server in
            #expect(server.commandTimeout == nil)
            #expect(server.withTimeout(.seconds(1)).commandTimeout == .seconds(1))
            // Same daemon, so the two values are the same server.
            #expect(server.withTimeout(.seconds(1)) == server)
            #expect(server.withTimeout(.seconds(1)).withTimeout(nil).commandTimeout == nil)
        }
    }

    @Test("waiting for a channel is not bounded by the server's command timeout")
    func channelWaitIgnoresTheCommandTimeout() async throws {
        try await withTmuxServer { server in
            let bounded = server.withTimeout(.milliseconds(100))
            let waiting = Task { try await bounded.wait(for: "libtmux-unbounded-channel") }
            // A wait is meant to outlast an ordinary command's bound: this one
            // is ten times it and still has to be the signal that ends it.
            try await Task.sleep(for: .seconds(1))
            try await server.signal("libtmux-unbounded-channel")

            try await waiting.value
        }
    }

    @Test("a channel wait ends at its own timeout when given one")
    func channelWaitHonorsItsOwnTimeout() async throws {
        try await withTmuxServer { server in
            let refused = await #expect(
                throws: TmuxError.timedOut(after: .milliseconds(250))
            ) {
                try await server.wait(
                    for: "libtmux-bounded-channel",
                    timeout: .milliseconds(250)
                )
            }
            #expect(refused != nil)
        }
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
