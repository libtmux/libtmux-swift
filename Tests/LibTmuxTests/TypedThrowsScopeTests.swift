import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

/// A caller can keep `throws(TmuxError)` across a scope.
///
/// Not by overloading the scopes — Swift 6.2 will not infer a closure literal's
/// thrown type, so a typed overload is unreachable without annotating every
/// call site. The narrowing happens at the boundary instead, and most of this
/// suite is the compiler proving it: each helper below declares
/// `throws(TmuxError)` around a scope, so if `withTmuxError` stopped working
/// this file would not build.
@Suite("typed throws scopes", .timeLimit(.minutes(1)))
struct TypedThrowsScopeTests {
    struct Unrelated: Error {}

    // MARK: Resolution, checked at compile time

    /// The case that could not be written before: a typed signature all the way
    /// through a mode switch.
    static func typedThroughUsing(_ server: Server) async throws(TmuxError) -> [Session] {
        try await withTmuxError {
            try await server.using(.direct) { server in
                try await server.sessions()
            }
        }
    }

    /// A body throwing something else needs no wrapper and keeps its own type.
    static func untypedStillResolves(_ server: Server) async throws -> [Session] {
        try await server.using(.direct) { server in
            guard try await server.isRunning() else { throw Unrelated() }
            return try await server.sessions()
        }
    }

    /// A body that cannot throw at all still narrows cleanly.
    static func nonThrowingResolves(_ server: Server) async throws(TmuxError) -> Int {
        try await withTmuxError { try await server.using(.direct) { _ in 7 } }
    }

    /// The same question for the connection-carrying forms.
    static func typedThroughConnected(
        _ server: Server,
        _ session: String
    ) async throws(TmuxError) -> Int {
        try await withTmuxError {
            try await server.connected(attachingTo: session) { server, _ in
                try await server.sessions().count
            }
        }
    }

    static func typedThroughControlMode(
        _ server: Server,
        _ session: String
    ) async throws(TmuxError) -> Bool {
        try await withTmuxError {
            try await server.withControlMode(attachingTo: session) { control in
                try await control.send(TmuxCommand("list-sessions")).isError == false
            }
        }
    }

    // MARK: Behaviour

    @Test("a typed scope runs and returns with its error type intact")
    func typedScopeRuns() async throws {
        try await withTmuxServer { server in
            let sessions = try await Self.typedThroughUsing(server)
            #expect(!sessions.isEmpty)
            #expect(try await Self.nonThrowingResolves(server) == 7)
        }
    }

    @Test("a tmux failure inside a typed scope arrives as TmuxError, not any Error")
    func failuresStayTyped() async throws {
        try await withTmuxServer { server in
            // Catching the concrete type is only possible because the wrapper
            // narrowed it; around a bare scope this would not compile.
            do {
                _ = try await withTmuxError {
                    try await server.using(.connected(to: "absent")) { server in
                        try await server.sessions()
                    }
                }
                Issue.record("attaching to a session that does not exist should fail")
            } catch let error as TmuxError {
                #expect(error != .cancelled)
            }
        }
    }

    @Test("an unrelated error still propagates unwrapped")
    func unrelatedErrorsPropagate() async throws {
        try await withTmuxServer { server in
            await #expect(throws: Unrelated.self) {
                _ = try await server.using(.direct) { _ in
                    throw Unrelated()
                }
            }
            // And the unwrapped helper above stays callable.
            _ = try await Self.untypedStillResolves(server)
        }
    }

    @Test("the connection-carrying forms keep the type too")
    func connectedFormsStayTyped() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "typed")
            let count = try await Self.typedThroughConnected(server, session.name)
            #expect(count >= 1)
            #expect(try await Self.typedThroughControlMode(server, session.name))
        }
    }
}
