import Foundation
import Testing

@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private let publicCaseIdentityProbe = PublicCaseIdentityProbe(expectedCount: 2)
private let registryDuplicateObserved = AsyncGate()
private let registryProbeEnabled: Bool = {
    guard let value = getenv("LIBTMUX_REGISTRY_IDENTITY_PROBE") else {
        return false
    }
    return String(cString: value) == "1"
}()

private enum FixtureFailureContractError: Error, Sendable, Equatable {
    case missingCurrentCase
    case missingCurrentTest
}

private struct PublicCaseIdentitySnapshot: Sendable {
    let parameterizedCaseCount: Int
    let testIdentityCount: Int
}

private actor PublicCaseIdentityProbe {
    private let expectedCount: Int
    private let allObserved = AsyncGate()
    private var cases: [Bool] = []
    private var testIdentities: Set<Test.ID> = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func observe(
        test: Test,
        testCase: Test.Case
    ) async throws -> PublicCaseIdentitySnapshot {
        testIdentities.insert(test.id)
        cases.append(testCase.isParameterized)
        if cases.count == expectedCount {
            await allObserved.open()
        }
        try await allObserved.wait(timeout: .seconds(30))
        return PublicCaseIdentitySnapshot(
            parameterizedCaseCount: cases.filter { $0 }.count,
            testIdentityCount: testIdentities.count
        )
    }
}

@Suite(
    "fixture contender failure authority",
    .timeLimit(.minutes(1))
)
struct FixtureFailureTests {
    @Test(
        "public parameterized cases share one declaration identity",
        arguments: [0, 1]
    )
    func publicParameterizedCasesShareOneDeclarationIdentity(
        _ argument: Int
    ) async throws {
        _ = argument
        guard let test = Test.current else {
            throw FixtureFailureContractError.missingCurrentTest
        }
        guard let testCase = Test.Case.current else {
            throw FixtureFailureContractError.missingCurrentCase
        }
        #expect(test.isParameterized)
        #expect(testCase.isParameterized)
        let snapshot = try await publicCaseIdentityProbe.observe(
            test: test,
            testCase: testCase
        )
        #expect(snapshot.parameterizedCaseCount == 2)
        #expect(snapshot.testIdentityCount == 1)
    }

    @Test(
        "registry rejects duplicate public case identity",
        RegistryFixtureTrait(
            configuration: inMemoryFixtureConfiguration,
            transport: inMemoryFixtureTransport,
            duplicateCaseIdentitySink: {
                await registryDuplicateObserved.open()
            }
        ),
        .enabled(
            if: registryProbeEnabled,
            "runs only in the expected-failure subprocess"
        ),
        arguments: [0, 1]
    )
    func registryRejectsDuplicatePublicCaseIdentity(
        _ argument: Int
    ) async throws {
        _ = argument
        let fixture = try await currentRegistryTmuxFixture()
        let inherited = try await Task {
            try await currentRegistryTmuxFixture()
        }.value
        #expect(inherited == fixture)
        try await registryDuplicateObserved.wait(timeout: .seconds(30))
    }
}
