import Testing
import TmuxFixture

@testable import LibTmux

@Suite("waiting on a channel", .timeLimit(.minutes(1)))
struct WaitTests {
    /// Whether a wait is still blocked after `milliseconds`.
    ///
    /// A channel nobody releases never answers, so "still blocked" is only
    /// observable as "the deadline came first". The wait loses that race by
    /// design and is cancelled with it, which is why nothing here reports a
    /// cancelled wait as a failure.
    private func blocks(
        beyond milliseconds: Int,
        _ wait: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await wait()) == nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(milliseconds))
                return true
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }

    @Test("an unmatched signal leaves the channel ready for the next wait")
    func anUnmatchedSignalArmsTheChannel() async throws {
        try await withTmuxServer { server in
            try await server.signal("gate")
            // Nothing is timed here: the channel is already ready, so the wait
            // has something to spend whenever it arrives. If it never returns,
            // the suite's limit says so.
            try await server.wait(for: "gate")
        }
    }

    @Test("a second unmatched signal puts the channel back rather than queueing")
    func signallingTwiceDisarmsTheChannel() async throws {
        try await withTmuxServer { server in
            try await server.signal("gate")
            try await server.signal("gate")
            #expect(await blocks(beyond: 1_000) { try await server.wait(for: "gate") })
        }
    }

    @Test("a wait does not stall the calls beside it on a connection")
    func waitDoesNotStallAConnection() async throws {
        try await withTmuxServer { server in
            try await server.connected(attachingTo: "bootstrap") { server, _ in
                async let waiting: Void = server.wait(for: "gate")
                // tmux runs one command at a time per control client, so a
                // wait carried over the connection would hold every command
                // behind it — including the one that would release it.
                try await Task.sleep(for: .milliseconds(300))
                let sessions = try await server.sessions()
                #expect(!sessions.isEmpty)

                // Releases the wait whether it is already blocked or has yet
                // to start, since an unmatched signal arms the channel.
                try await server.signal("gate")
                try await waiting
            }
        }
    }

    @Test("a wait whose server goes away is not reported as released")
    func waitOnADepartedServerIsNotSuccess() async throws {
        try await withTmuxServer { server in
            let waiting = Task { try await server.wait(for: "gate") }
            try await Task.sleep(for: .milliseconds(300))
            _ = try? await server.run(TmuxCommand("kill-server", []))

            // tmux releases every waiter when it shuts down, with the same
            // zero exit a real signal produces. Which refusal comes back
            // depends on whether the wait had started — a server that has
            // gone reports so outright, and one that goes mid-wait is caught
            // by its identity changing — but a release is never reported.
            await #expect(throws: TmuxError.self) {
                try await waiting.value
            }
        }
    }
}
