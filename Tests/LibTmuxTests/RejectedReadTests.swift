import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

/// A read tmux rejects is a thrown `commandFailed`, and an answer that is
/// legitimately empty or absent stays empty or `nil`.
@Suite("rejected reads", .timeLimit(.minutes(5)))
struct RejectedReadTests {
    /// The tmux command a rejected operation reports, or `nil` when it did not
    /// throw `commandFailed`.
    private func rejectedCommand<Value>(
        _ operation: () async throws -> Value
    ) async -> String? {
        do {
            _ = try await operation()
            return nil
        } catch let error as TmuxError {
            guard case let .commandFailed(command, exitCode, reason) = error else { return nil }
            return exitCode == 0 || reason.isEmpty ? nil : command
        } catch {
            return nil
        }
    }

    @Test("a hook table of a session tmux does not have throws")
    func hooksOfMissingSession() async throws {
        try await withTmuxServer { server in
            #expect(
                await rejectedCommand { try await server.hooks(.session("nosuch")) } == "show-hooks"
            )
        }
    }

    @Test("an environment of a session tmux does not have throws")
    func environmentOfMissingSession() async throws {
        try await withTmuxServer { server in
            #expect(
                await rejectedCommand { try await server.environment(.session("nosuch")) }
                    == "show-environment")
        }
    }

    @Test("a table of a server that is gone throws instead of reading as empty")
    func listingsOfAGoneServer() async throws {
        try await withTmuxServer { server in
            try await server.killServer()
            #expect(await rejectedCommand { try await server.options(.server) } == "show-options")
            #expect(await rejectedCommand { try await server.option("@x", scope: .server) } != nil)
            #expect(await rejectedCommand { try await server.hooks() } == "show-hooks")
            #expect(await rejectedCommand { try await server.environment() } == "show-environment")
            #expect(await rejectedCommand { try await server.buffers() } == "list-buffers")
            #expect(await rejectedCommand { try await server.buffer(named: "x") } == "show-buffer")
            #expect(
                await rejectedCommand { try await server.environmentValue("X") }
                    == "show-environment")
        }
    }

    @Test("a rejected write is commandFailed, not a missing reply")
    func rejectedWriteIsCommandFailed() async throws {
        try await withTmuxServer { server in
            let missing = "/tmp/libtmux-swift-test/no-such-file-\(UUID().uuidString)"
            #expect(
                await rejectedCommand { try await server.loadBuffer(from: missing) }
                    == "load-buffer")
        }
    }

    @Test("an empty answer and a documented nil are not errors")
    func legitimateEmptyAnswersStayEmpty() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            #expect(try await server.options(.session(session)).isEmpty)
            #expect(try await server.hooks(.session(session.id.rawValue)).isEmpty)
            #expect(try await server.buffers().isEmpty)
            #expect(try await server.option("@nosuch", scope: .server) == nil)
            #expect(try await server.option("nosuch-option", scope: .server) == nil)
            #expect(try await server.optionValue("nosuch-option", scope: .server) == nil)
            #expect(
                try await server.resolvedOption("nosuch-option", scope: .session(session)) == nil)
            #expect(try await server.environmentValue("LIBTMUX_NO_SUCH_VARIABLE") == nil)
            #expect(try await server.buffer(named: "nosuch") == nil)
            #expect(try await server.buffer() == nil)
        }
    }
}
