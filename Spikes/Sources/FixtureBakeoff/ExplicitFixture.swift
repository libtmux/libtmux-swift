import SpikeSupport

package typealias FixtureCleanupFailureSink =
    @Sendable (FixtureCleanupError) async -> Void

package func withTmuxServer<Value: Sendable>(
    configuration: FixtureConfiguration,
    transport: any ProcessTransport,
    secondaryCleanupFailureSink: @escaping FixtureCleanupFailureSink,
    body: @Sendable (TmuxFixture) async throws -> Value
) async throws -> Value {
    let lease = try await FixtureLease.start(
        configuration: configuration,
        transport: transport
    )

    let bodyResult: Result<Value, any Error>
    do {
        bodyResult = .success(try await body(lease.fixture))
    } catch {
        bodyResult = .failure(error)
    }

    let cleanupResult = await Task.detached {
        await lease.cleanupResult()
    }.value

    switch (bodyResult, cleanupResult) {
    case let (.success(value), .success):
        return value
    case let (.failure(error), .success):
        throw error
    case let (.success, .failure(cleanupError)):
        throw cleanupError
    case let (.failure(bodyError), .failure(cleanupError)):
        await secondaryCleanupFailureSink(cleanupError)
        throw bodyError
    }
}
