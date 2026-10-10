import Testing
import TmuxFixture

@testable import LibTmux

@Suite("owned session scope", .timeLimit(.minutes(5)))
struct SessionScopeTests {
    private enum BodyFailure: Error { case deliberate }

    @Test("a renamed session is removed after a body failure and borrowed sessions survive")
    func bodyFailureRemovesCapturedID() async throws {
        try await withTmuxServer { server async throws -> Void in
            await #expect(throws: BodyFailure.deliberate) {
                try await server.withNewSession(named: "owned", shell: "sleep 300") { session in
                    try await server.rename(session, to: "renamed")
                    throw BodyFailure.deliberate
                }
            }
            #expect(try await server.sessions().map(\.name) == ["bootstrap"])
        }
    }

    @Test("cancellation waits for cleanup")
    func cancelledBodyStillCleansUp() async throws {
        try await withTmuxServer { server async throws -> Void in
            let (started, signal) = AsyncStream<Void>.makeStream()
            let task = Task {
                try await server.withNewSession(named: "cancelled", shell: "sleep 300") { _ in
                    signal.yield(())
                    signal.finish()
                    try await Task.sleep(for: .seconds(300))
                }
            }
            for await _ in started { break }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(try await server.sessions().map(\.name) == ["bootstrap"])
        }
    }

    @Test("body and cleanup failures remain inspectable")
    func combinedFailure() async throws {
        try await withTmuxServer { server async throws -> Void in
            do {
                try await server.withNewSession(named: "removed", shell: "sleep 300") { session in
                    try await server.kill(session)
                    throw BodyFailure.deliberate
                }
                Issue.record("the scope hid both failures")
            } catch let failure as SessionScopeFailure {
                #expect(failure.bodyError as? BodyFailure == .deliberate)
                #expect(failure.cleanupError == .staleServerValue)
            }
            #expect(try await server.sessions().map(\.name) == ["bootstrap"])
        }
    }

    @Test("a cleanup failure after a successful body is thrown")
    func cleanupFailureIsObservable() async throws {
        try await withTmuxServer { server async throws -> Void in
            await #expect(throws: TmuxError.staleServerValue) {
                try await server.withNewSession(named: "removed", shell: "sleep 300") { session in
                    try await server.kill(session)
                }
            }
        }
    }
}
