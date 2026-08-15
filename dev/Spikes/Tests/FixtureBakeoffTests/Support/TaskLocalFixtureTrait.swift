import Testing

@testable import FixtureBakeoff
@testable import SpikeSupport

private enum FixtureContext {
    @TaskLocal static var current: TmuxFixture?
}

package enum FixtureContextError: Error, Sendable, Equatable {
    case missingFixture
}

package func currentTmuxFixture() throws -> TmuxFixture {
    guard let fixture = FixtureContext.current else {
        throw FixtureContextError.missingFixture
    }
    return fixture
}

package func withTaskLocalTmuxServer(
    configuration: FixtureConfiguration,
    transport: any ProcessTransport,
    secondaryCleanupFailureSink: @escaping FixtureCleanupFailureSink,
    body: @Sendable () async throws -> Void
) async throws {
    try await withTmuxServer(
        configuration: configuration,
        transport: transport,
        secondaryCleanupFailureSink: secondaryCleanupFailureSink
    ) { fixture in
        try await FixtureContext.$current.withValue(fixture) {
            try await body()
        }
    }
}

package struct TmuxFixtureTrait: TestTrait, TestScoping {
    private let configuration: FixtureConfiguration
    private let transport: any ProcessTransport

    package init(
        configuration: FixtureConfiguration,
        transport: any ProcessTransport
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    package func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        _ = test
        _ = testCase
        try await withTaskLocalTmuxServer(
            configuration: configuration,
            transport: transport,
            secondaryCleanupFailureSink: { cleanupError in
                Issue.record("fixture cleanup also failed: \(cleanupError)")
            }
        ) {
            try await function()
        }
    }
}
