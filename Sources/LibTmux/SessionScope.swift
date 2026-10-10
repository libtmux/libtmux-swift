/// Both failures from a session body and its teardown.
public struct SessionScopeFailure: Error, Sendable {
    public let bodyError: any Error
    public let cleanupError: TmuxError
}

extension Server {
    /// Creates a session and destroys that captured session after `body` returns or throws.
    ///
    /// Cleanup runs in an awaited detached task, so body cancellation cannot
    /// cancel teardown. A renamed session keeps its ID; a replacement daemon
    /// fails the existing provenance guard. A missing session is a cleanup
    /// error. If body and teardown both fail, ``SessionScopeFailure`` retains both.
    /// This scope owns only the new session. Other sessions remain intact.
    public func withNewSession<Value: Sendable>(
        named name: String,
        shell: String? = nil,
        _ body: @Sendable (Session) async throws -> Value
    ) async throws -> Value {
        let owner = try await newOwnedSession(named: name, shell: shell)
        do { return try await owner.withValue(body) } catch let failure as ResourceScopeFailure {
            throw SessionScopeFailure(
                bodyError: failure.bodyError, cleanupError: failure.cleanupError)
        }
    }
}
