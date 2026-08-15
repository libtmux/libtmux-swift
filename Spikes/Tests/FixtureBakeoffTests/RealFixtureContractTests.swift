import Foundation
import Testing

@testable import FixtureBakeoff
@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private let realFixtureCaseCount = 32
private let realFixtureIncarnationOption = "@libtmux_swift_incarnation"
private let realFixtureDirectoryType: UInt32 = 0o040000
private let realFixtureRegularType: UInt32 = 0o100000
private let realFixtureSocketType: UInt32 = 0o140000
private let realFixtureTypeMask: UInt32 = 0o170000
private let realFixtureOverlap = RealFixtureOverlap(
    expectedCount: realFixtureCaseCount
)

private enum RealFixtureContractError: Error, Sendable, Equatable {
    case barrierTimedOut(actualCount: Int)
    case cleanupBarrierTimedOut(actualCount: Int)
    case duplicateArgument(Int)
    case duplicateCleanupArgument(Int)
    case endpointAbsenceTimedOut
    case expectedBodyFailure
    case expectedMismatchRejection
    case expectedSetupCheckpointFailure
    case fixtureNotPublished
    case fixtureInventoryInvalid([String])
    case fixtureRegistrationMismatch(Int)
    case filesystem(operation: String, code: Int32)
    case pathIdentityChanged(String)
    case pathStatusFailed(path: String, code: Int32)
    case pathStillPresent(String)
    case replacementGuardFailed(ProcessReply)
    case unexpectedStartError(FixtureStartError)
    case unexpectedTokenReply(ProcessReply)
    case unexpectedTransport
}

private struct RealFixturePathIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64

    var fileType: UInt32 { mode & realFixtureTypeMask }
}

private func realFixturePathIdentity(
    _ path: URL
) throws -> RealFixturePathIdentity {
    var status = stat()
    guard lstat(path.path, &status) == 0 else {
        throw RealFixtureContractError.pathStatusFailed(
            path: path.path,
            code: errno
        )
    }
    return RealFixturePathIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        mode: UInt32(status.st_mode),
        size: Int64(status.st_size)
    )
}

private func requireRealFixturePathIdentity(
    _ path: URL,
    expected: RealFixturePathIdentity
) throws {
    let actual = try realFixturePathIdentity(path)
    let sizeMatches =
        expected.fileType != realFixtureRegularType
        || actual.size == expected.size
    guard actual.device == expected.device,
        actual.inode == expected.inode,
        actual.mode == expected.mode,
        sizeMatches
    else {
        throw RealFixtureContractError.pathIdentityChanged(path.path)
    }
}

private func realFixtureDirectoryEntries(
    _ directory: URL
) throws -> [String: RealFixturePathIdentity] {
    let names = try FileManager.default.contentsOfDirectory(
        atPath: directory.path
    )
    var entries: [String: RealFixturePathIdentity] = [:]
    for name in names {
        entries[name] = try realFixturePathIdentity(
            directory.appendingPathComponent(name)
        )
    }
    return entries
}

private func requireRealFixtureEntryNames(
    _ entries: [String: RealFixturePathIdentity],
    expected: Set<String>,
    scope: String
) throws {
    guard Set(entries.keys) == expected else {
        throw RealFixtureContractError.fixtureInventoryInvalid(
            [scope] + entries.keys.sorted()
        )
    }
}

private struct RealFixtureArtifactInventory: Sendable {
    let configurationIdentity: RealFixturePathIdentity
    let fixture: TmuxFixture
    let ownershipIdentity: RealFixturePathIdentity
    let runDirectoryEntries: [String: RealFixturePathIdentity]
    let runDirectoryIdentity: RealFixturePathIdentity
    let socketDirectoryEntries: [String: RealFixturePathIdentity]
    let socketDirectoryIdentity: RealFixturePathIdentity
    let socketIdentity: RealFixturePathIdentity
}

private struct RealFixtureRunRoot: Sendable {
    let directory: URL
    let identity: RealFixturePathIdentity

    static func create(lane: TmuxLane, purpose: String) throws -> Self {
        let nonce = UUID().uuidString.prefix(8)
        let directory = lane.root.appendingPathComponent(
            "\(purpose)-\(nonce)",
            isDirectory: true
        )
        guard mkdir(directory.path, 0o700) == 0 else {
            throw RealFixtureContractError.filesystem(
                operation: "mkdir-real-fixture-root",
                code: errno
            )
        }
        guard chmod(directory.path, 0o700) == 0 else {
            let code = errno
            _ = rmdir(directory.path)
            throw RealFixtureContractError.filesystem(
                operation: "chmod-real-fixture-root",
                code: code
            )
        }
        do {
            return Self(
                directory: directory,
                identity: try realFixturePathIdentity(directory)
            )
        } catch {
            _ = rmdir(directory.path)
            throw error
        }
    }

    func removeIfEmpty() throws {
        try requireRealFixturePathIdentity(directory, expected: identity)
        guard rmdir(directory.path) == 0 else {
            throw RealFixtureContractError.filesystem(
                operation: "rmdir-real-fixture-root",
                code: errno
            )
        }
    }
}

private struct RealFixtureOverlapSnapshot: Sendable {
    let argumentCount: Int
    let endpointCount: Int
    let tokenCount: Int
}

private actor RealFixtureOverlap {
    private let expectedCount: Int
    private let allEntered = AsyncGate()
    private let allCleaned = AsyncGate()
    private var cleanedFixtures: [Int: TmuxFixture] = [:]
    private var fixtures: [Int: TmuxFixture] = [:]

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func enter(
        argument: Int,
        fixture: TmuxFixture
    ) async throws -> RealFixtureOverlapSnapshot {
        guard fixtures[argument] == nil else {
            throw RealFixtureContractError.duplicateArgument(argument)
        }
        fixtures[argument] = fixture
        if fixtures.count == expectedCount {
            await allEntered.open()
        }
        do {
            try await allEntered.wait(timeout: .seconds(30))
        } catch AsyncGateError.timedOut {
            throw RealFixtureContractError.barrierTimedOut(
                actualCount: fixtures.count
            )
        }
        return RealFixtureOverlapSnapshot(
            argumentCount: fixtures.count,
            endpointCount: Set(fixtures.values.map(\.endpoint)).count,
            tokenCount: Set(fixtures.values.map(\.incarnation.token)).count
        )
    }

    func registerAbsentArtifacts(
        argument: Int,
        fixture: TmuxFixture
    ) async throws -> RealFixtureOverlapSnapshot {
        guard fixtures[argument] == fixture else {
            throw RealFixtureContractError.fixtureRegistrationMismatch(argument)
        }
        guard cleanedFixtures[argument] == nil else {
            throw RealFixtureContractError.duplicateCleanupArgument(argument)
        }
        try requireFixtureArtifactsAbsent(fixture)
        cleanedFixtures[argument] = fixture
        if cleanedFixtures.count == expectedCount {
            for cleanedFixture in cleanedFixtures.values {
                try requireFixtureArtifactsAbsent(cleanedFixture)
            }
            await allCleaned.open()
        }
        do {
            try await allCleaned.wait(timeout: .seconds(30))
        } catch AsyncGateError.timedOut {
            throw RealFixtureContractError.cleanupBarrierTimedOut(
                actualCount: cleanedFixtures.count
            )
        }
        return RealFixtureOverlapSnapshot(
            argumentCount: cleanedFixtures.count,
            endpointCount: Set(cleanedFixtures.values.map(\.endpoint)).count,
            tokenCount: Set(cleanedFixtures.values.map(\.incarnation.token)).count
        )
    }
}

private actor RealFixtureCapture {
    private let published = AsyncGate()
    private var fixture: TmuxFixture?

    func publish(_ fixture: TmuxFixture) async {
        self.fixture = fixture
        await published.open()
    }

    func value() async throws -> TmuxFixture {
        try await published.wait(timeout: .seconds(30))
        guard let fixture else {
            throw RealFixtureContractError.fixtureNotPublished
        }
        return fixture
    }
}

private actor RealFixtureInventoryCapture {
    private let published = AsyncGate()
    private var inventory: RealFixtureArtifactInventory?

    func publish(_ inventory: RealFixtureArtifactInventory) async {
        self.inventory = inventory
        await published.open()
    }

    func value() async throws -> RealFixtureArtifactInventory {
        try await published.wait(timeout: .seconds(30))
        guard let inventory else {
            throw RealFixtureContractError.fixtureNotPublished
        }
        return inventory
    }
}

private func selectedRealFixtureTransport() throws -> any ProcessTransport {
    let transport = makeSelectedTmuxTransport()
    guard transport is SwiftSubprocessTransport else {
        throw RealFixtureContractError.unexpectedTransport
    }
    return transport
}

private func requireExactEndpointToken(
    lane: TmuxLane,
    fixture: TmuxFixture,
    transport: any ProcessTransport
) async throws {
    try await requireEndpointToken(
        lane: lane,
        fixture: fixture,
        expectedToken: fixture.incarnation.token,
        transport: transport
    )
}

private func requireEndpointToken(
    lane: TmuxLane,
    fixture: TmuxFixture,
    expectedToken: UUID,
    transport: any ProcessTransport
) async throws {
    let endpoint = try socketPath(fixture)
    let reply = try await transport.run(
        ProcessRequest(
            executable: .path(lane.binary),
            arguments: [
                "-N", "-S", endpoint,
                "show-options", "-sv", realFixtureIncarnationOption,
            ],
            environment: lane.childEnvironment,
            workingDirectory: nil,
            outputPolicy: .complete
        )
    )
    let expected = ProcessReply(
        standardOutput: Array(
            "\(expectedToken.uuidString)\n".utf8
        ),
        standardError: [],
        termination: .exited(0)
    )
    guard reply == expected else {
        throw RealFixtureContractError.unexpectedTokenReply(reply)
    }
}

private func requirePathAbsent(_ path: URL) throws {
    var status = stat()
    if lstat(path.path, &status) == 0 {
        throw RealFixtureContractError.pathStillPresent(path.path)
    }
    let code = errno
    guard code == ENOENT else {
        throw RealFixtureContractError.pathStatusFailed(
            path: path.path,
            code: code
        )
    }
}

private func requireFixtureArtifactsAbsent(_ fixture: TmuxFixture) throws {
    try requirePathAbsent(URL(fileURLWithPath: socketPath(fixture)))
    try requirePathAbsent(fixture.runDirectory)
    try requirePathAbsent(
        fixture.runDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(fixture.runDirectory.lastPathComponent).owner.json"
        )
    )
}

private func captureRealFixtureInventory(
    in runRoot: RealFixtureRunRoot
) throws -> RealFixtureArtifactInventory {
    try requireRealFixturePathIdentity(
        runRoot.directory,
        expected: runRoot.identity
    )
    let rootEntries = try realFixtureDirectoryEntries(runRoot.directory)
    guard rootEntries.count == 1,
        let runName = rootEntries.keys.first,
        runName.hasPrefix("f-"),
        rootEntries[runName]?.fileType == realFixtureDirectoryType
    else {
        throw RealFixtureContractError.fixtureInventoryInvalid(
            ["root"] + rootEntries.keys.sorted()
        )
    }

    let runDirectory = runRoot.directory.appendingPathComponent(
        runName,
        isDirectory: true
    )
    let runDirectoryIdentity = try realFixturePathIdentity(runDirectory)
    let runEntries = try realFixtureDirectoryEntries(runDirectory)
    try requireRealFixtureEntryNames(
        runEntries,
        expected: ["owner.json", "s", "tmux.conf"],
        scope: "run"
    )
    guard runEntries["owner.json"]?.fileType == realFixtureRegularType,
        runEntries["s"]?.fileType == realFixtureDirectoryType,
        runEntries["tmux.conf"]?.fileType == realFixtureRegularType
    else {
        throw RealFixtureContractError.fixtureInventoryInvalid(["run-types"])
    }

    let socketDirectory = runDirectory.appendingPathComponent(
        "s",
        isDirectory: true
    )
    let socketDirectoryIdentity = try realFixturePathIdentity(socketDirectory)
    let socketDirectoryEntries = try realFixtureDirectoryEntries(socketDirectory)
    try requireRealFixtureEntryNames(
        socketDirectoryEntries,
        expected: ["s"],
        scope: "socket-directory"
    )
    guard socketDirectoryEntries["s"]?.fileType == realFixtureSocketType else {
        throw RealFixtureContractError.fixtureInventoryInvalid(["socket-type"])
    }

    let configurationFile = runDirectory.appendingPathComponent("tmux.conf")
    let ownershipMarker = runDirectory.appendingPathComponent("owner.json")
    let socket = socketDirectory.appendingPathComponent("s")
    let ownerRecord = try JSONDecoder().decode(
        OwnerLeaseRecord.self,
        from: Data(contentsOf: ownershipMarker)
    )
    let endpoint = TmuxEndpoint.socketPath(socket.path)
    let incarnation = try ServerIncarnationID(
        endpoint: endpoint,
        token: ownerRecord.token
    )
    let fixture = TmuxFixture(
        runDirectory: runDirectory,
        socketDirectory: socketDirectory,
        configurationFile: configurationFile,
        ownershipMarker: ownershipMarker,
        ownershipRecord: FixtureOwnershipRecord(
            marker: ownershipMarker,
            token: ownerRecord.token
        ),
        endpoint: endpoint,
        incarnation: incarnation
    )

    return RealFixtureArtifactInventory(
        configurationIdentity: runEntries["tmux.conf"]!,
        fixture: fixture,
        ownershipIdentity: runEntries["owner.json"]!,
        runDirectoryEntries: runEntries,
        runDirectoryIdentity: runDirectoryIdentity,
        socketDirectoryEntries: socketDirectoryEntries,
        socketDirectoryIdentity: socketDirectoryIdentity,
        socketIdentity: socketDirectoryEntries["s"]!
    )
}

private func requireRealFixtureInventoryUnchanged(
    _ inventory: RealFixtureArtifactInventory,
    in runRoot: RealFixtureRunRoot
) throws {
    try requireRealFixturePathIdentity(
        runRoot.directory,
        expected: runRoot.identity
    )
    let rootEntries = try realFixtureDirectoryEntries(runRoot.directory)
    try requireRealFixtureEntryNames(
        rootEntries,
        expected: [inventory.fixture.runDirectory.lastPathComponent],
        scope: "root"
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.runDirectory,
        expected: inventory.runDirectoryIdentity
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.socketDirectory,
        expected: inventory.socketDirectoryIdentity
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.configurationFile,
        expected: inventory.configurationIdentity
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.ownershipMarker,
        expected: inventory.ownershipIdentity
    )
    try requireRealFixturePathIdentity(
        URL(fileURLWithPath: socketPath(inventory.fixture)),
        expected: inventory.socketIdentity
    )
    guard
        try realFixtureDirectoryEntries(inventory.fixture.runDirectory)
            == inventory.runDirectoryEntries,
        try realFixtureDirectoryEntries(inventory.fixture.socketDirectory)
            == inventory.socketDirectoryEntries
    else {
        throw RealFixtureContractError.fixtureInventoryInvalid(
            ["identity-drift"]
        )
    }
}

private func setRealFixtureEndpointToken(
    lane: TmuxLane,
    fixture: TmuxFixture,
    token: UUID,
    transport: any ProcessTransport
) async throws {
    let reply = try await transport.run(
        ProcessRequest(
            executable: .path(lane.binary),
            arguments: [
                "-N", "-S", try socketPath(fixture),
                "set-option", "-s", realFixtureIncarnationOption,
                token.uuidString,
            ],
            environment: lane.childEnvironment,
            workingDirectory: nil,
            outputPolicy: .complete
        )
    )
    guard
        reply
            == ProcessReply(
                standardOutput: [],
                standardError: [],
                termination: .exited(0)
            )
    else {
        throw RealFixtureContractError.unexpectedTokenReply(reply)
    }
}

/// A tmux server unlinks its socket only when a new server binds the same
/// path, never when it exits, so a dead endpoint keeps a stale socket file.
/// The caller removes that file itself after this returns.
private func waitForRealFixtureServerExit(
    lane: TmuxLane,
    fixture: TmuxFixture,
    transport: any ProcessTransport
) async throws {
    let request = try ProcessRequest(
        executable: .path(lane.binary),
        arguments: [
            "-N", "-S", socketPath(fixture),
            "display-message", "-p", "#{socket_path}",
        ],
        environment: lane.childEnvironment,
        workingDirectory: nil,
        outputPolicy: .complete
    )
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        let reply = try await transport.run(request)
        if reply.termination == .exited(1) {
            return
        }
        if reply.termination != .exited(0) {
            throw RealFixtureContractError.unexpectedTokenReply(reply)
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw RealFixtureContractError.endpointAbsenceTimedOut
}

private func unlinkMatchingRealFixtureFile(
    _ file: URL,
    expected: RealFixturePathIdentity,
    operation: String
) throws {
    guard expected.fileType != realFixtureDirectoryType else {
        throw RealFixtureContractError.fixtureInventoryInvalid([operation])
    }
    try requireRealFixturePathIdentity(file, expected: expected)
    guard unlink(file.path) == 0 else {
        throw RealFixtureContractError.filesystem(
            operation: operation,
            code: errno
        )
    }
}

private func removeEmptyMatchingRealFixtureDirectory(
    _ directory: URL,
    expected: RealFixturePathIdentity,
    operation: String
) throws {
    guard expected.fileType == realFixtureDirectoryType else {
        throw RealFixtureContractError.fixtureInventoryInvalid([operation])
    }
    try requireRealFixturePathIdentity(directory, expected: expected)
    guard try realFixtureDirectoryEntries(directory).isEmpty else {
        throw RealFixtureContractError.fixtureInventoryInvalid([operation])
    }
    guard rmdir(directory.path) == 0 else {
        throw RealFixtureContractError.filesystem(
            operation: operation,
            code: errno
        )
    }
}

private func removePreservedRealFixtureArtifacts(
    _ inventory: RealFixtureArtifactInventory,
    from runRoot: RealFixtureRunRoot
) throws {
    try requireRealFixturePathIdentity(
        runRoot.directory,
        expected: runRoot.identity
    )
    let rootEntries = try realFixtureDirectoryEntries(runRoot.directory)
    try requireRealFixtureEntryNames(
        rootEntries,
        expected: [inventory.fixture.runDirectory.lastPathComponent],
        scope: "preserved-root"
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.runDirectory,
        expected: inventory.runDirectoryIdentity
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.socketDirectory,
        expected: inventory.socketDirectoryIdentity
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.configurationFile,
        expected: inventory.configurationIdentity
    )
    try requireRealFixturePathIdentity(
        inventory.fixture.ownershipMarker,
        expected: inventory.ownershipIdentity
    )
    let runEntries = try realFixtureDirectoryEntries(
        inventory.fixture.runDirectory
    )
    try requireRealFixtureEntryNames(
        runEntries,
        expected: ["owner.json", "s", "tmux.conf"],
        scope: "preserved-run"
    )
    try requireRealFixtureEntryNames(
        try realFixtureDirectoryEntries(inventory.fixture.socketDirectory),
        expected: ["s"],
        scope: "preserved-socket-directory"
    )

    try unlinkMatchingRealFixtureFile(
        URL(fileURLWithPath: socketPath(inventory.fixture)),
        expected: inventory.socketIdentity,
        operation: "unlink-preserved-socket"
    )
    try unlinkMatchingRealFixtureFile(
        inventory.fixture.configurationFile,
        expected: inventory.configurationIdentity,
        operation: "unlink-preserved-configuration"
    )
    try unlinkMatchingRealFixtureFile(
        inventory.fixture.ownershipMarker,
        expected: inventory.ownershipIdentity,
        operation: "unlink-preserved-owner"
    )
    try removeEmptyMatchingRealFixtureDirectory(
        inventory.fixture.socketDirectory,
        expected: inventory.socketDirectoryIdentity,
        operation: "rmdir-preserved-socket-directory"
    )
    try removeEmptyMatchingRealFixtureDirectory(
        inventory.fixture.runDirectory,
        expected: inventory.runDirectoryIdentity,
        operation: "rmdir-preserved-run-directory"
    )
}

private func shutDownAuthenticatedReplacement(
    lane: TmuxLane,
    inventory: RealFixtureArtifactInventory,
    runRoot: RealFixtureRunRoot,
    replacementToken: UUID,
    transport: any ProcessTransport
) async throws {
    try requireRealFixtureInventoryUnchanged(inventory, in: runRoot)
    try await requireEndpointToken(
        lane: lane,
        fixture: inventory.fixture,
        expectedToken: replacementToken,
        transport: transport
    )
    let mismatchSentinel = UUID().uuidString
    let condition =
        "#{==:#{\(realFixtureIncarnationOption)},"
        + "\(replacementToken.uuidString)}"
    let reply = try await transport.run(
        ProcessRequest(
            executable: .path(lane.binary),
            arguments: [
                "-N", "-S", try socketPath(inventory.fixture),
                "if-shell", "-F", condition,
                "kill-server", "display-message -p \(mismatchSentinel)",
            ],
            environment: lane.childEnvironment,
            workingDirectory: nil,
            outputPolicy: .complete
        )
    )
    guard
        reply
            == ProcessReply(
                standardOutput: [],
                standardError: [],
                termination: .exited(0)
            )
    else {
        throw RealFixtureContractError.replacementGuardFailed(reply)
    }

    try await waitForRealFixtureServerExit(
        lane: lane,
        fixture: inventory.fixture,
        transport: transport
    )
    try removePreservedRealFixtureArtifacts(inventory, from: runRoot)
}

@Suite(
    "real fixture lifecycle authority",
    .timeLimit(.minutes(2))
)
struct RealFixtureContractTests {
    @Test("artifact absence oracle rejects recovery sidecar residue")
    func artifactAbsenceOracleRejectsRecoverySidecarResidue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-real-fixture-oracle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let runDirectory = root.appendingPathComponent("f-oracle", isDirectory: true)
        let sidecar = root.appendingPathComponent(".f-oracle.owner.json")
        try Data("orphan\n".utf8).write(to: sidecar)
        let token = UUID()
        let endpoint = TmuxEndpoint.socketPath(
            runDirectory.appendingPathComponent("s/s").path
        )
        let fixture = TmuxFixture(
            runDirectory: runDirectory,
            socketDirectory: runDirectory.appendingPathComponent("s", isDirectory: true),
            configurationFile: runDirectory.appendingPathComponent("tmux.conf"),
            ownershipMarker: runDirectory.appendingPathComponent("owner.json"),
            ownershipRecord: FixtureOwnershipRecord(
                marker: runDirectory.appendingPathComponent("owner.json"),
                token: token
            ),
            endpoint: endpoint,
            incarnation: try ServerIncarnationID(endpoint: endpoint, token: token)
        )

        #expect(
            throws: RealFixtureContractError.pathStillPresent(sidecar.path)
        ) {
            try requireFixtureArtifactsAbsent(fixture)
        }
    }

    @Test(
        "32 live cases unwind one body failure without fixture residue",
        arguments: Array(0..<realFixtureCaseCount)
    )
    func parameterizedCasesOverlapOnUniqueLiveEndpoints(
        _ argument: Int
    ) async throws {
        let lane = try authenticatedTmuxLane()
        let transport = try selectedRealFixtureTransport()
        let capture = RealFixtureCapture()

        do {
            try await withTaskLocalTmuxServer(
                configuration: lane.fixtureConfiguration(),
                transport: transport,
                secondaryCleanupFailureSink: { cleanupError in
                    Issue.record("fixture cleanup also failed: \(cleanupError)")
                }
            ) {
                let fixture = try currentTmuxFixture()
                let inherited = try await Task {
                    try currentTmuxFixture()
                }.value
                #expect(inherited == fixture)
                await capture.publish(fixture)

                let snapshot = try await realFixtureOverlap.enter(
                    argument: argument,
                    fixture: fixture
                )
                #expect(snapshot.argumentCount == realFixtureCaseCount)
                #expect(snapshot.endpointCount == realFixtureCaseCount)
                #expect(snapshot.tokenCount == realFixtureCaseCount)
                try await requireExactEndpointToken(
                    lane: lane,
                    fixture: fixture,
                    transport: transport
                )
                if argument == 0 {
                    throw RealFixtureContractError.expectedBodyFailure
                }
            }
            if argument == 0 {
                Issue.record("designated fixture body failure was discarded")
            }
        } catch {
            guard argument == 0,
                let contractError = error as? RealFixtureContractError,
                contractError == .expectedBodyFailure
            else {
                throw error
            }
        }

        let fixture = try await capture.value()
        let cleanupSnapshot = try await realFixtureOverlap.registerAbsentArtifacts(
            argument: argument,
            fixture: fixture
        )
        #expect(cleanupSnapshot.argumentCount == realFixtureCaseCount)
        #expect(cleanupSnapshot.endpointCount == realFixtureCaseCount)
        #expect(cleanupSnapshot.tokenCount == realFixtureCaseCount)
    }

    @Test("post-daemon setup failure rolls back exact artifacts")
    func postDaemonSetupFailureRollsBackExactArtifacts() async throws {
        let lane = try authenticatedTmuxLane()
        let transport = try selectedRealFixtureTransport()
        let runRoot = try RealFixtureRunRoot.create(
            lane: lane,
            purpose: "rb"
        )
        let capture = RealFixtureInventoryCapture()
        let checkpoints = FixtureLifecycleCheckpoints(
            afterInitialTokenAcceptance: {
                let inventory = try captureRealFixtureInventory(in: runRoot)
                try await requireExactEndpointToken(
                    lane: lane,
                    fixture: inventory.fixture,
                    transport: transport
                )
                await capture.publish(inventory)
                throw RealFixtureContractError.expectedSetupCheckpointFailure
            }
        )

        var observedRollback = false
        do {
            let lease = try await FixtureLease.start(
                configuration: lane.fixtureConfiguration(
                    runRoot: runRoot.directory,
                    checkpoints: checkpoints
                ),
                transport: transport
            )
            Issue.record("post-daemon setup failure unexpectedly returned a lease")
            try await lease.cleanupResult().get()
        } catch let error as FixtureStartError {
            guard error == .transportFailure else {
                throw RealFixtureContractError.unexpectedStartError(error)
            }
            observedRollback = true
        }
        guard observedRollback else {
            throw RealFixtureContractError.expectedSetupCheckpointFailure
        }

        let inventory = try await capture.value()
        try requireFixtureArtifactsAbsent(inventory.fixture)
        try runRoot.removeIfEmpty()
        try requirePathAbsent(runRoot.directory)
    }

    @Test("readiness token mismatch preserves then authenticates cleanup")
    func readinessTokenMismatchPreservesThenAuthenticatesCleanup() async throws {
        let lane = try authenticatedTmuxLane()
        let transport = try selectedRealFixtureTransport()
        let runRoot = try RealFixtureRunRoot.create(
            lane: lane,
            purpose: "mm"
        )
        let capture = RealFixtureInventoryCapture()
        let replacementToken = UUID()
        let expectedMismatchReply = ProcessReply(
            standardOutput: Array("\(replacementToken.uuidString)\n".utf8),
            standardError: [],
            termination: .exited(0)
        )
        let checkpoints = FixtureLifecycleCheckpoints(
            afterInitialTokenAcceptance: {
                let inventory = try captureRealFixtureInventory(in: runRoot)
                try await requireExactEndpointToken(
                    lane: lane,
                    fixture: inventory.fixture,
                    transport: transport
                )
                try requireRealFixtureInventoryUnchanged(
                    inventory,
                    in: runRoot
                )
                try await setRealFixtureEndpointToken(
                    lane: lane,
                    fixture: inventory.fixture,
                    token: replacementToken,
                    transport: transport
                )
                try await requireEndpointToken(
                    lane: lane,
                    fixture: inventory.fixture,
                    expectedToken: replacementToken,
                    transport: transport
                )
                try requireRealFixtureInventoryUnchanged(
                    inventory,
                    in: runRoot
                )
                await capture.publish(inventory)
            }
        )

        do {
            _ = try await FixtureLease.start(
                configuration: lane.fixtureConfiguration(
                    runRoot: runRoot.directory,
                    checkpoints: checkpoints
                ),
                transport: transport
            )
            throw RealFixtureContractError.expectedMismatchRejection
        } catch let error as FixtureStartError {
            guard error == .readinessTokenMismatch(expectedMismatchReply) else {
                throw RealFixtureContractError.unexpectedStartError(error)
            }
        }

        let inventory = try await capture.value()
        try requireRealFixtureInventoryUnchanged(inventory, in: runRoot)
        try await shutDownAuthenticatedReplacement(
            lane: lane,
            inventory: inventory,
            runRoot: runRoot,
            replacementToken: replacementToken,
            transport: transport
        )
        try runRoot.removeIfEmpty()
        try requirePathAbsent(runRoot.directory)
    }

    @Test("successful scope removes its exact endpoint and run directory")
    func successfulScopeRemovesExactArtifacts() async throws {
        let lane = try authenticatedTmuxLane()
        let transport = try selectedRealFixtureTransport()
        let capture = RealFixtureCapture()

        try await withTaskLocalTmuxServer(
            configuration: lane.fixtureConfiguration(),
            transport: transport,
            secondaryCleanupFailureSink: { cleanupError in
                Issue.record("fixture cleanup also failed: \(cleanupError)")
            }
        ) {
            let fixture = try currentTmuxFixture()
            await capture.publish(fixture)
            try await requireExactEndpointToken(
                lane: lane,
                fixture: fixture,
                transport: transport
            )
        }

        let fixture = try await capture.value()
        try requireFixtureArtifactsAbsent(fixture)
    }

    @Test("thrown body remains primary after exact artifact cleanup")
    func thrownBodyRemainsPrimaryAfterCleanup() async throws {
        let lane = try authenticatedTmuxLane()
        let transport = try selectedRealFixtureTransport()
        let capture = RealFixtureCapture()

        do {
            try await withTaskLocalTmuxServer(
                configuration: lane.fixtureConfiguration(),
                transport: transport,
                secondaryCleanupFailureSink: { cleanupError in
                    Issue.record("fixture cleanup also failed: \(cleanupError)")
                }
            ) {
                let fixture = try currentTmuxFixture()
                await capture.publish(fixture)
                try await requireExactEndpointToken(
                    lane: lane,
                    fixture: fixture,
                    transport: transport
                )
                throw RealFixtureContractError.expectedBodyFailure
            }
            Issue.record("fixture scope discarded its body error")
        } catch let error as RealFixtureContractError {
            #expect(error == .expectedBodyFailure)
        }

        let fixture = try await capture.value()
        try requireFixtureArtifactsAbsent(fixture)
    }

    @Test("cooperative cancellation awaits exact artifact cleanup")
    func cooperativeCancellationAwaitsCleanup() async throws {
        let lane = try authenticatedTmuxLane()
        let transport = try selectedRealFixtureTransport()
        let capture = RealFixtureCapture()
        let bodyEntered = AsyncGate()
        let operation = Task {
            try await withTaskLocalTmuxServer(
                configuration: lane.fixtureConfiguration(),
                transport: transport,
                secondaryCleanupFailureSink: { cleanupError in
                    Issue.record("fixture cleanup also failed: \(cleanupError)")
                }
            ) {
                let fixture = try currentTmuxFixture()
                await capture.publish(fixture)
                try await requireExactEndpointToken(
                    lane: lane,
                    fixture: fixture,
                    transport: transport
                )
                await bodyEntered.open()
                try await Task.sleep(for: .seconds(30))
            }
        }

        do {
            try await bodyEntered.wait(timeout: .seconds(30))
        } catch {
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
        let fixture = try await capture.value()
        operation.cancel()
        do {
            try await operation.value
            Issue.record("fixture scope discarded cooperative cancellation")
        } catch is CancellationError {
        }

        try requireFixtureArtifactsAbsent(fixture)
    }
}
