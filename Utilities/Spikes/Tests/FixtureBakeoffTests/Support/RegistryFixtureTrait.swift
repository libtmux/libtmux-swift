import Testing

@testable import SpikeSupport

package enum RegistryFixtureError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case duplicateCaseIdentity
    case missingFixture

    package var description: String {
        switch self {
        case .duplicateCaseIdentity:
            "duplicateCaseIdentity"
        case .missingFixture:
            "missingFixture"
        }
    }
}

private enum RegistryFixtureEntry: Sendable {
    case active(TmuxFixture)
    case reserved
}

private actor RegistryFixtureStore {
    static let shared = RegistryFixtureStore()

    private var entries: [Test.ID: RegistryFixtureEntry] = [:]

    func reserve(
        _ identity: Test.ID,
        duplicateCaseIdentitySink: @Sendable () async -> Void
    ) async throws {
        guard entries[identity] == nil else {
            await duplicateCaseIdentitySink()
            throw RegistryFixtureError.duplicateCaseIdentity
        }
        entries[identity] = .reserved
    }

    func activate(_ fixture: TmuxFixture, for identity: Test.ID) {
        entries[identity] = .active(fixture)
    }

    func fixture(for identity: Test.ID) throws -> TmuxFixture {
        guard case let .active(fixture) = entries[identity] else {
            throw RegistryFixtureError.missingFixture
        }
        return fixture
    }

    func release(_ identity: Test.ID) {
        entries.removeValue(forKey: identity)
    }
}

package func currentRegistryTmuxFixture() async throws -> TmuxFixture {
    guard let test = Test.current else {
        throw RegistryFixtureError.missingFixture
    }
    return try await RegistryFixtureStore.shared.fixture(for: test.id)
}

package struct RegistryFixtureTrait: TestTrait, TestScoping {
    private let configuration: FixtureConfiguration
    private let duplicateCaseIdentitySink: @Sendable () async -> Void
    private let transport: any ProcessTransport

    package init(
        configuration: FixtureConfiguration,
        transport: any ProcessTransport,
        duplicateCaseIdentitySink: @escaping @Sendable () async -> Void = {}
    ) {
        self.configuration = configuration
        self.transport = transport
        self.duplicateCaseIdentitySink = duplicateCaseIdentitySink
    }

    package func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        _ = testCase
        let identity = test.id
        try await RegistryFixtureStore.shared.reserve(
            identity,
            duplicateCaseIdentitySink: duplicateCaseIdentitySink
        )

        let lease: FixtureLease
        do {
            lease = try await FixtureLease.start(
                configuration: configuration,
                transport: transport
            )
        } catch {
            await RegistryFixtureStore.shared.release(identity)
            throw error
        }
        await RegistryFixtureStore.shared.activate(
            lease.fixture,
            for: identity
        )

        let bodyResult: Result<Void, any Error>
        do {
            try await function()
            bodyResult = .success(())
        } catch {
            bodyResult = .failure(error)
        }
        let cleanupResult = await Task.detached {
            await lease.cleanupResult()
        }.value
        await RegistryFixtureStore.shared.release(identity)

        switch (bodyResult, cleanupResult) {
        case (.success, .success):
            return
        case let (.failure(bodyError), .success):
            throw bodyError
        case let (.success, .failure(cleanupError)):
            throw cleanupError
        case let (.failure(bodyError), .failure(cleanupError)):
            Issue.record("fixture cleanup also failed: \(cleanupError)")
            throw bodyError
        }
    }
}
