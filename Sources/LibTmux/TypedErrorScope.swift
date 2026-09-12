/// Narrowing a scope's thrown type back to ``TmuxError``.
///
/// Every call in this library throws ``TmuxError`` and says so, which lets a
/// program write `throws(TmuxError)` from top to bottom. The scoped forms —
/// ``Server/using(_:_:)``, ``Server/connected(attachingTo:_:)`` and
/// ``Server/withControlMode(attachingTo:_:)`` — are the exception: they take a
/// closure, and a closure's thrown type cannot be carried out of one.
///
/// That is a property of the language rather than a choice made here. Swift
/// 6.2 does not infer a closure literal's thrown type from its body, so a
/// `throws(TmuxError)` overload of those scopes is unreachable without spelling
/// the closure's own signature at every call site — and even with the type
/// inferred, a scope that can fail on its own behalf has no way to rethrow that
/// failure as the body's error, because there is no union of the two.
///
/// So the narrowing happens at the boundary instead of inside the scope:
///
/// ```swift
/// func names(_ server: Server) async throws(TmuxError) -> [String] {
///     try await withTmuxError {
///         try await server.using(.connected(to: "main")) { server in
///             try await server.sessions().map(\.name)
///         }
///     }
/// }
/// ```
///
/// One wrapper per scope, rather than an annotation per closure.
///
/// - Important: This is for work that only fails with ``TmuxError``. Anything
///   else `body` throws is flattened into
///   ``TmuxError/invocationFailed(reason:)`` with its description as the
///   reason, which keeps the signature honest but loses the original type. A
///   body that throws errors of its own should stay untyped and be caught as
///   itself.
///
/// - Parameter body: the work to run, typically a scoped call.
/// - Returns: whatever `body` returned.
/// - Throws: ``TmuxError``, either as thrown or as a flattened foreign error.
public func withTmuxError<Result>(
    _ body: () async throws -> Result
) async throws(TmuxError) -> Result {
    try await withTmuxErrorMapping(body)
}
