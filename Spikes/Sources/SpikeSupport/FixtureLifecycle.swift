import Foundation

#if canImport(Darwin)
    import Darwin
    import os
#else
    import Glibc
    import Synchronization
#endif

private let fixtureIncarnationOption = "@libtmux_swift_incarnation"
private let portableUnixSocketPathByteLimit = 103

package struct FixtureChildEnvironment: Sendable, Equatable {
    package let path: String
    /// Scratch storage for the tmux server and everything it spawns. The
    /// caller owns it, because a fixture run directory holds an exact
    /// inventory that teardown removes entry by entry: a tmux child that
    /// mints a temporary entry there makes that removal impossible.
    package let temporaryDirectory: String
    package let developerDirectory: String?
    package let sdkRoot: String?

    package init(
        path: String,
        temporaryDirectory: String,
        developerDirectory: String?,
        sdkRoot: String?
    ) {
        self.path = path
        self.temporaryDirectory = temporaryDirectory
        self.developerDirectory = developerDirectory
        self.sdkRoot = sdkRoot
    }

    fileprivate func emitted() -> [String: String] {
        var environment = [
            "LC_ALL": "C",
            "PATH": path,
            "TMPDIR": temporaryDirectory,
        ]
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory
        }
        if let sdkRoot {
            environment["SDKROOT"] = sdkRoot
        }
        return environment
    }
}

package struct FixtureLifecycleTiming: Sendable {
    package let waitForDeadline: @Sendable (Duration) async throws -> Void

    package init(
        waitForDeadline: @escaping @Sendable (Duration) async throws -> Void = {
            duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.waitForDeadline = waitForDeadline
    }
}

package struct FixtureLifecycleCheckpoints: Sendable {
    package let afterConfigurationRemoval: @Sendable () async throws -> Void
    package let afterInitialTokenAcceptance: @Sendable () async throws -> Void
    package let afterReadyRecordSynchronization: @Sendable () async throws -> Void
    package let afterRecoveryClaimSynchronization: @Sendable () async throws -> Void
    package let afterRecoverySidecarRemoval: @Sendable () async throws -> Void
    package let afterRecoverySidecarSynchronization: @Sendable () async throws -> Void
    package let afterRunDirectoryRemoval: @Sendable () async throws -> Void
    package let afterSocketIdentityValidation: @Sendable () async throws -> Void
    package let beforeClaimedSocketDirectoryValidation: @Sendable () async throws -> Void
    package let beforeConfigurationRemoval: @Sendable () async throws -> Void
    package let beforeRecoveryClaim: @Sendable () async throws -> Void
    package let beforeRecoverySidecarRemoval: @Sendable () async throws -> Void
    package let beforeRunDirectoryRemoval: @Sendable () async throws -> Void
    package let beforeSocketDirectoryRemoval: @Sendable () async throws -> Void
    package let cleanupRequested: @Sendable () async throws -> Void
    package let cleanupJoinedInFlight: @Sendable () async throws -> Void
    package let socketLockContended: @Sendable () async throws -> Void

    package init(
        afterConfigurationRemoval: @escaping @Sendable () async throws -> Void = {},
        afterInitialTokenAcceptance: @escaping @Sendable () async throws -> Void = {},
        afterReadyRecordSynchronization: @escaping @Sendable () async throws -> Void = {},
        afterRecoveryClaimSynchronization: @escaping @Sendable () async throws -> Void = {},
        afterRecoverySidecarRemoval: @escaping @Sendable () async throws -> Void = {},
        afterRecoverySidecarSynchronization: @escaping @Sendable () async throws -> Void = {},
        afterRunDirectoryRemoval: @escaping @Sendable () async throws -> Void = {},
        afterSocketIdentityValidation: @escaping @Sendable () async throws -> Void = {},
        beforeClaimedSocketDirectoryValidation: @escaping @Sendable () async throws -> Void = {},
        beforeConfigurationRemoval: @escaping @Sendable () async throws -> Void = {},
        beforeRecoveryClaim: @escaping @Sendable () async throws -> Void = {},
        beforeRecoverySidecarRemoval: @escaping @Sendable () async throws -> Void = {},
        beforeRunDirectoryRemoval: @escaping @Sendable () async throws -> Void = {},
        beforeSocketDirectoryRemoval: @escaping @Sendable () async throws -> Void = {},
        cleanupRequested: @escaping @Sendable () async throws -> Void = {},
        cleanupJoinedInFlight: @escaping @Sendable () async throws -> Void = {},
        socketLockContended: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.afterConfigurationRemoval = afterConfigurationRemoval
        self.afterInitialTokenAcceptance = afterInitialTokenAcceptance
        self.afterReadyRecordSynchronization = afterReadyRecordSynchronization
        self.afterRecoveryClaimSynchronization = afterRecoveryClaimSynchronization
        self.afterRecoverySidecarRemoval = afterRecoverySidecarRemoval
        self.afterRecoverySidecarSynchronization = afterRecoverySidecarSynchronization
        self.afterRunDirectoryRemoval = afterRunDirectoryRemoval
        self.afterSocketIdentityValidation = afterSocketIdentityValidation
        self.beforeClaimedSocketDirectoryValidation = beforeClaimedSocketDirectoryValidation
        self.beforeConfigurationRemoval = beforeConfigurationRemoval
        self.beforeRecoveryClaim = beforeRecoveryClaim
        self.beforeRecoverySidecarRemoval = beforeRecoverySidecarRemoval
        self.beforeRunDirectoryRemoval = beforeRunDirectoryRemoval
        self.beforeSocketDirectoryRemoval = beforeSocketDirectoryRemoval
        self.cleanupRequested = cleanupRequested
        self.cleanupJoinedInFlight = cleanupJoinedInFlight
        self.socketLockContended = socketLockContended
    }
}

package struct FixtureConfiguration: Sendable {
    package let runRoot: URL
    package let tmuxExecutable: ProcessExecutable
    package let childEnvironment: FixtureChildEnvironment
    package let startupDeadline: Duration
    package let cleanupDeadline: Duration
    package let checkpointInterval: Duration
    package let timing: FixtureLifecycleTiming
    package let checkpoints: FixtureLifecycleCheckpoints

    package init(
        runRoot: URL,
        tmuxExecutable: ProcessExecutable,
        childEnvironment: FixtureChildEnvironment,
        startupDeadline: Duration,
        cleanupDeadline: Duration,
        checkpointInterval: Duration,
        timing: FixtureLifecycleTiming = FixtureLifecycleTiming(),
        checkpoints: FixtureLifecycleCheckpoints = FixtureLifecycleCheckpoints()
    ) {
        self.runRoot = runRoot
        self.tmuxExecutable = tmuxExecutable
        self.childEnvironment = childEnvironment
        self.startupDeadline = startupDeadline
        self.cleanupDeadline = cleanupDeadline
        self.checkpointInterval = checkpointInterval
        self.timing = timing
        self.checkpoints = checkpoints
    }
}

package struct FixtureOwnershipRecord: Sendable, Equatable {
    package let marker: URL
    package let token: UUID
}

package struct TmuxFixture: Sendable, Equatable {
    package let runDirectory: URL
    package let socketDirectory: URL
    package let configurationFile: URL
    package let ownershipMarker: URL
    package let ownershipRecord: FixtureOwnershipRecord
    package let endpoint: TmuxEndpoint
    package let incarnation: ServerIncarnationID
}

package enum FixtureStartupFailure: Sendable, Equatable {
    case artifactIdentityChanged
    case cancellation
    case deadlineExceeded
    case endpointIdentityChanged
    case initialTokenRejected(ProcessReply)
    case invalidTmuxExecutable
    case readinessTokenMismatch(ProcessReply)
    case readyPublicationFailed(OwnerLeaseReadyPublicationError)
    case transportFailure
}

package enum FixtureStartError: Error, Sendable, Equatable {
    case artifactIdentityChanged
    case deadlineExceeded
    case endpointIdentityChanged
    case filesystem(operation: String, code: Int32)
    case initialTokenRejected(ProcessReply)
    case invalidTmuxExecutable
    case ownerAcquisitionFailed(OwnerLeaseAcquisitionError)
    case ownerCloseFailed(OwnerLeaseCloseError)
    case readinessTokenMismatch(ProcessReply)
    case readyPublicationFailed(OwnerLeaseReadyPublicationError)
    case rollbackFailed(
        primary: FixtureStartupFailure,
        cleanup: FixtureCleanupError,
        ownerCloseFailure: OwnerLeaseCloseError?
    )
    case socketPathTooLong(actualBytes: Int, maximumBytes: Int)
    case temporaryDirectoryWithinRunRoot
    case transportFailure
}

package enum FixtureCleanupError: Error, Sendable, Equatable {
    case checkpointFailure
    case deadlineExceeded
    case endpointProbeFailed(ProcessReply)
    case endpointProbeTransportFailure
    case extraSentinel(ProcessReply)
    case filesystem(operation: String, code: Int32)
    case guardRequestFailed(ProcessReply)
    case guardTransportFailure
    case malformedSentinel(ProcessReply)
    case ownerCloseFailed(OwnerLeaseCloseError)
    case ownershipMismatch(ProcessReply)
}

package final class FixtureLease: Sendable {
    package let fixture: TmuxFixture

    private let cleanupCoordinator: FixtureCleanupCoordinator

    private init(
        fixture: TmuxFixture,
        cleanupCoordinator: FixtureCleanupCoordinator
    ) {
        self.fixture = fixture
        self.cleanupCoordinator = cleanupCoordinator
    }

    package static func start(
        configuration: FixtureConfiguration,
        transport: any ProcessTransport
    ) async throws -> FixtureLease {
        guard fixtureExactExecutablePath(configuration.tmuxExecutable) != nil else {
            throw FixtureStartError.invalidTmuxExecutable
        }
        let prepared: PreparedFixture
        do {
            prepared = try await prepareFixture(configuration: configuration)
        } catch let error as FixtureCleanupError {
            if case let .filesystem(operation, code) = error {
                throw FixtureStartError.filesystem(
                    operation: operation,
                    code: code
                )
            }
            throw FixtureStartError.transportFailure
        } catch let error as OwnerLeaseAcquisitionError {
            throw FixtureStartError.ownerAcquisitionFailed(error)
        }
        let startupState = FixtureStartupState()
        let engine = FixtureCleanupEngine(
            fixture: prepared.fixture,
            configuration: configuration,
            transport: transport,
            ownerLease: prepared.ownerLease,
            identities: prepared.identities,
            startupState: startupState,
            mode: .lifecycle,
            recoveryPins: nil
        )
        let lease = FixtureLease(
            fixture: prepared.fixture,
            cleanupCoordinator: FixtureCleanupCoordinator(engine: engine)
        )
        do {
            try await withFixtureDeadline(
                duration: configuration.startupDeadline,
                timing: configuration.timing
            ) {
                try await runStartupProtocol(
                    prepared: prepared,
                    configuration: configuration,
                    transport: transport,
                    state: startupState
                )
                try await publishFixtureRecoveryReadyRecord(
                    prepared: prepared,
                    configuration: configuration,
                    state: startupState
                )
            }
            return lease
        } catch {
            let accepted = await startupState.didAcceptInitialToken
            let mustPreserve = !accepted || error is FixtureOwnershipRejection

            if mustPreserve {
                let closeResult = await prepared.ownerLease.closeResult()
                if case let .failure(closeError) = closeResult {
                    throw FixtureStartError.ownerCloseFailed(closeError)
                }
            } else {
                let cleanupResult = await Task.detached {
                    await lease.cleanupResult()
                }.value
                if case let .failure(cleanupError) = cleanupResult {
                    let closeResult = await prepared.ownerLease.closeResult()
                    let ownerCloseFailure: OwnerLeaseCloseError?
                    switch closeResult {
                    case .success:
                        ownerCloseFailure = nil
                    case let .failure(closeError):
                        ownerCloseFailure = closeError
                    }
                    throw FixtureStartError.rollbackFailed(
                        primary: fixtureStartupFailure(for: error),
                        cleanup: cleanupError,
                        ownerCloseFailure: ownerCloseFailure
                    )
                }
            }

            if error is CancellationError {
                throw CancellationError()
            }
            if error is FixtureDeadlineReached {
                throw FixtureStartError.deadlineExceeded
            }
            if case let FixtureOwnershipRejection.initial(reply) = error {
                throw FixtureStartError.initialTokenRejected(reply)
            }
            if case let FixtureOwnershipRejection.readiness(reply) = error {
                throw FixtureStartError.readinessTokenMismatch(reply)
            }
            if case FixtureOwnershipRejection.endpointIdentityChanged = error {
                throw FixtureStartError.endpointIdentityChanged
            }
            if case FixtureOwnershipRejection.artifactIdentityChanged = error {
                throw FixtureStartError.artifactIdentityChanged
            }
            if case FixtureReadyPublicationFailure.invalidTmuxExecutable = error {
                throw FixtureStartError.invalidTmuxExecutable
            }
            if case let FixtureReadyPublicationFailure.owner(publicationError) = error {
                throw FixtureStartError.readyPublicationFailed(publicationError)
            }
            throw FixtureStartError.transportFailure
        }
    }

    package func cleanupResult() async -> Result<Void, FixtureCleanupError> {
        await cleanupCoordinator.result()
    }
}

private struct PreparedFixture: Sendable {
    let bootstrapSession: String
    let environment: [String: String]
    let fixture: TmuxFixture
    let identities: FixtureArtifactIdentities
    let ownerLease: OwnerLease
}

private struct FixtureArtifactIdentities: Sendable {
    let configurationFile: FixturePathIdentity
    let ownershipMarker: FixturePathIdentity
    let runDirectory: FixturePathIdentity
    let socketDirectory: FixturePathIdentity
}

private enum FixturePathKind: Sendable, Equatable {
    case directory
    case regular
    case socket
}

private struct FixturePathIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: FixturePathKind
    let permissions: UInt16
}

private actor FixtureStartupState {
    private(set) var didAcceptInitialToken = false
    private(set) var endpointIdentity: FixturePathIdentity?

    func acceptInitialToken() {
        didAcceptInitialToken = true
    }

    func recordInitialEndpointIdentity(_ identity: FixturePathIdentity) {
        if endpointIdentity == nil {
            endpointIdentity = identity
        }
    }
}

private enum FixtureOwnershipRejection: Error, Sendable {
    case artifactIdentityChanged
    case endpointIdentityChanged
    case initial(ProcessReply)
    case readiness(ProcessReply)
}

private enum FixtureReadyPublicationFailure: Error, Sendable {
    case invalidTmuxExecutable
    case owner(OwnerLeaseReadyPublicationError)
}

private struct FixtureDeadlineReached: Error, Sendable {}

private func fixtureStartupFailure(for error: any Error) -> FixtureStartupFailure {
    if error is CancellationError {
        return .cancellation
    }
    if error is FixtureDeadlineReached {
        return .deadlineExceeded
    }
    if case let FixtureOwnershipRejection.initial(reply) = error {
        return .initialTokenRejected(reply)
    }
    if case let FixtureOwnershipRejection.readiness(reply) = error {
        return .readinessTokenMismatch(reply)
    }
    if case FixtureOwnershipRejection.endpointIdentityChanged = error {
        return .endpointIdentityChanged
    }
    if case FixtureOwnershipRejection.artifactIdentityChanged = error {
        return .artifactIdentityChanged
    }
    if case FixtureReadyPublicationFailure.invalidTmuxExecutable = error {
        return .invalidTmuxExecutable
    }
    if case let FixtureReadyPublicationFailure.owner(publicationError) = error {
        return .readyPublicationFailed(publicationError)
    }
    return .transportFailure
}

private enum FixtureDeadlineEvent<Value: Sendable>: Sendable {
    case deadline
    case value(Value)
}

private func withFixtureDeadline<Value: Sendable>(
    duration: Duration,
    timing: FixtureLifecycleTiming,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(
        of: FixtureDeadlineEvent<Value>.self,
        returning: Value.self
    ) { group in
        group.addTask {
            .value(try await operation())
        }
        group.addTask {
            try await timing.waitForDeadline(duration)
            return .deadline
        }
        defer { group.cancelAll() }

        guard let event = try await group.next() else {
            throw CancellationError()
        }
        switch event {
        case .deadline:
            throw FixtureDeadlineReached()
        case let .value(value):
            return value
        }
    }
}

private func prepareFixture(
    configuration: FixtureConfiguration
) async throws -> PreparedFixture {
    guard
        !pathIsWithin(
            configuration.childEnvironment.temporaryDirectory,
            configuration.runRoot
        )
    else {
        throw FixtureStartError.temporaryDirectoryWithinRunRoot
    }
    let runDirectory = try createPrivateDirectory(
        parent: configuration.runRoot,
        prefix: "f"
    )
    let socketDirectory = runDirectory.appendingPathComponent("s")
    var socketDirectoryCreated = false
    var configurationCreated = false
    var ownerLease: OwnerLease?
    let configurationFile = runDirectory.appendingPathComponent("tmux.conf")
    let ownershipMarker = runDirectory.appendingPathComponent("owner.json")
    let socketPath =
        socketDirectory
        .appendingPathComponent("s").path

    do {
        guard socketPath.utf8.count <= portableUnixSocketPathByteLimit else {
            throw FixtureStartError.socketPathTooLong(
                actualBytes: socketPath.utf8.count,
                maximumBytes: portableUnixSocketPathByteLimit
            )
        }
        try createPrivateDirectory(at: socketDirectory)
        socketDirectoryCreated = true

        let token = UUID()
        let acquiredOwner = try OwnerLease.acquire(
            marker: ownershipMarker,
            token: token
        )
        ownerLease = acquiredOwner

        let bootstrapSession = "bootstrap-\(token.uuidString)"
        let configurationText =
            "set-option -s \(fixtureIncarnationOption) \(token.uuidString)\n"
            + "new-session -d -s \(bootstrapSession)\n"
        try writeExclusiveFile(
            configurationFile,
            bytes: Array(configurationText.utf8),
            permissions: 0o600
        )
        configurationCreated = true

        let endpoint = TmuxEndpoint.socketPath(socketPath)
        let incarnation = try ServerIncarnationID(
            endpoint: endpoint,
            token: token
        )
        let fixture = TmuxFixture(
            runDirectory: runDirectory,
            socketDirectory: socketDirectory,
            configurationFile: configurationFile,
            ownershipMarker: ownershipMarker,
            ownershipRecord: FixtureOwnershipRecord(
                marker: ownershipMarker,
                token: token
            ),
            endpoint: endpoint,
            incarnation: incarnation
        )
        let identities = FixtureArtifactIdentities(
            configurationFile: try fixturePathIdentity(
                configurationFile,
                expected: .regular
            ),
            ownershipMarker: try fixturePathIdentity(
                ownershipMarker,
                expected: .regular
            ),
            runDirectory: try fixturePathIdentity(
                runDirectory,
                expected: .directory
            ),
            socketDirectory: try fixturePathIdentity(
                socketDirectory,
                expected: .directory
            )
        )
        return PreparedFixture(
            bootstrapSession: bootstrapSession,
            environment: configuration.childEnvironment.emitted(),
            fixture: fixture,
            identities: identities,
            ownerLease: acquiredOwner
        )
    } catch {
        var cleanupError: FixtureStartError?
        if configurationCreated, unlinkPath(configurationFile) != 0 {
            cleanupError = .filesystem(
                operation: "unlink-configuration-after-start-failure",
                code: errno
            )
        }
        if let ownerLease {
            let expectedMarker = FixturePathIdentity(
                device: ownerLease.identity.device,
                inode: ownerLease.identity.inode,
                kind: .regular,
                permissions: ownerLease.identity.permissions
            )
            let markerMatches =
                (try? fixturePathIdentity(
                    ownershipMarker,
                    expected: .regular
                )) == expectedMarker
            if markerMatches {
                if unlinkPath(ownershipMarker) != 0, cleanupError == nil {
                    cleanupError = .filesystem(
                        operation: "unlink-owner-after-start-failure",
                        code: errno
                    )
                }
            } else if cleanupError == nil {
                cleanupError = .filesystem(
                    operation: "owner-identity-after-start-failure",
                    code: ESTALE
                )
            }
            let closeResult = await ownerLease.closeResult()
            if case let .failure(closeError) = closeResult {
                cleanupError = .ownerCloseFailed(closeError)
            }
        }
        if socketDirectoryCreated {
            _ = removeDirectory(socketDirectory)
        }
        _ = removeDirectory(runDirectory)
        if let cleanupError {
            throw cleanupError
        }
        throw error
    }
}

private func runStartupProtocol(
    prepared: PreparedFixture,
    configuration: FixtureConfiguration,
    transport: any ProcessTransport,
    state: FixtureStartupState
) async throws {
    let fixture = prepared.fixture
    guard case let .socketPath(socketPath) = fixture.endpoint else {
        throw FixtureStartError.transportFailure
    }
    let initialRequest = try fixtureRequest(
        executable: configuration.tmuxExecutable,
        arguments: [
            "-S", socketPath,
            "-f", fixture.configurationFile.path,
            "start-server", ";",
            "show-options", "-sv", fixtureIncarnationOption,
        ],
        environment: prepared.environment
    )
    let initialReply = try await transport.run(initialRequest)
    guard fixtureReplyToken(initialReply) == fixture.incarnation.token else {
        throw FixtureOwnershipRejection.initial(initialReply)
    }
    let endpointIdentity = try fixturePathIdentity(
        URL(fileURLWithPath: socketPath),
        expected: .socket
    )
    await state.recordInitialEndpointIdentity(endpointIdentity)
    await state.acceptInitialToken()
    try await configuration.checkpoints.afterInitialTokenAcceptance()
    try Task.checkCancellation()

    let tokenRequest = try fixtureRequest(
        executable: configuration.tmuxExecutable,
        arguments: [
            "-N", "-S", socketPath,
            "show-options", "-sv", fixtureIncarnationOption,
        ],
        environment: prepared.environment
    )
    let bootstrapRequest = try fixtureRequest(
        executable: configuration.tmuxExecutable,
        arguments: [
            "-N", "-S", socketPath,
            "has-session", "-t", "=\(prepared.bootstrapSession)",
        ],
        environment: prepared.environment
    )

    while true {
        let tokenReply = try await transport.run(tokenRequest)
        if fixtureReplySucceeded(tokenReply) {
            guard fixtureReplyToken(tokenReply) == fixture.incarnation.token else {
                throw FixtureOwnershipRejection.readiness(tokenReply)
            }
            let bootstrapReply = try await transport.run(bootstrapRequest)
            if fixtureReplySucceeded(bootstrapReply) {
                let finalEndpointIdentity: FixturePathIdentity
                do {
                    finalEndpointIdentity = try fixturePathIdentity(
                        URL(fileURLWithPath: socketPath),
                        expected: .socket
                    )
                } catch {
                    throw FixtureOwnershipRejection.endpointIdentityChanged
                }
                guard
                    await state.endpointIdentity == finalEndpointIdentity
                else {
                    throw FixtureOwnershipRejection.endpointIdentityChanged
                }
                return
            }
        }
        try await Task.sleep(for: configuration.checkpointInterval)
    }
}

private func publishFixtureRecoveryReadyRecord(
    prepared: PreparedFixture,
    configuration: FixtureConfiguration,
    state: FixtureStartupState
) async throws {
    let fixture = prepared.fixture
    guard
        let tmuxExecutablePath = fixtureExactExecutablePath(
            configuration.tmuxExecutable
        ), case let .socketPath(socketPath) = fixture.endpoint
    else {
        throw FixtureReadyPublicationFailure.invalidTmuxExecutable
    }
    let currentIdentities = try FixtureArtifactIdentities(
        configurationFile: fixturePathIdentity(
            fixture.configurationFile,
            expected: .regular
        ),
        ownershipMarker: fixturePathIdentity(
            fixture.ownershipMarker,
            expected: .regular
        ),
        runDirectory: fixturePathIdentity(
            fixture.runDirectory,
            expected: .directory
        ),
        socketDirectory: fixturePathIdentity(
            fixture.socketDirectory,
            expected: .directory
        )
    )
    guard currentIdentities.configurationFile == prepared.identities.configurationFile,
        currentIdentities.ownershipMarker == prepared.identities.ownershipMarker,
        currentIdentities.runDirectory == prepared.identities.runDirectory,
        currentIdentities.socketDirectory == prepared.identities.socketDirectory
    else {
        throw FixtureOwnershipRejection.artifactIdentityChanged
    }
    let socketIdentity = try fixturePathIdentity(
        URL(fileURLWithPath: socketPath),
        expected: .socket
    )
    let acceptedSocketIdentity = await state.endpointIdentity
    guard socketIdentity == acceptedSocketIdentity else {
        throw FixtureOwnershipRejection.endpointIdentityChanged
    }
    let ownerIdentity = prepared.ownerLease.identity
    guard ownerIdentity.device == currentIdentities.ownershipMarker.device,
        ownerIdentity.inode == currentIdentities.ownershipMarker.inode,
        ownerIdentity.permissions == currentIdentities.ownershipMarker.permissions
    else {
        throw FixtureOwnershipRejection.artifactIdentityChanged
    }

    let record = FixtureRecoveryReadyRecord(
        configurationFile: fixtureRecoveryArtifact(
            fixture.configurationFile,
            identity: currentIdentities.configurationFile
        ),
        ownershipMarker: fixtureRecoveryArtifact(
            fixture.ownershipMarker,
            identity: currentIdentities.ownershipMarker
        ),
        runDirectory: fixtureRecoveryArtifact(
            fixture.runDirectory,
            identity: currentIdentities.runDirectory
        ),
        socket: fixtureRecoveryArtifact(
            URL(fileURLWithPath: socketPath),
            identity: socketIdentity
        ),
        socketDirectory: fixtureRecoveryArtifact(
            fixture.socketDirectory,
            identity: currentIdentities.socketDirectory
        ),
        tmuxExecutablePath: tmuxExecutablePath,
        token: fixture.incarnation.token
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let encoded: Data
    do {
        encoded = try encoder.encode(record)
    } catch {
        throw FixtureReadyPublicationFailure.owner(.invalidRecord)
    }
    var recordBytes = [UInt8](encoded)
    guard !recordBytes.contains(0x0A) else {
        throw FixtureReadyPublicationFailure.owner(.invalidRecord)
    }
    recordBytes.append(0x0A)
    do {
        let recoverySidecar = fixture.runDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(fixture.runDirectory.lastPathComponent).owner.json"
            )
        _ = try await prepared.ownerLease.publishReadyRecord(
            recordBytes,
            recoverySidecar: recoverySidecar,
            afterReadyRecordSynchronization:
                configuration.checkpoints.afterReadyRecordSynchronization,
            afterRecoverySidecarSynchronization:
                configuration.checkpoints.afterRecoverySidecarSynchronization
        )
    } catch let error as OwnerLeaseReadyPublicationError {
        throw FixtureReadyPublicationFailure.owner(error)
    }
}

private func fixtureExactExecutablePath(
    _ executable: ProcessExecutable
) -> String? {
    guard case let .path(path) = executable,
        path.hasPrefix("/"),
        URL(fileURLWithPath: path).standardizedFileURL.path == path
    else {
        return nil
    }
    return path
}

private func fixtureRecoveryArtifact(
    _ path: URL,
    identity: FixturePathIdentity
) -> FixtureRecoveryArtifactRecord {
    let kind: FixtureRecoveryArtifactKind
    switch identity.kind {
    case .directory:
        kind = .directory
    case .regular:
        kind = .regular
    case .socket:
        kind = .socket
    }
    return FixtureRecoveryArtifactRecord(
        device: identity.device,
        inode: identity.inode,
        kind: kind,
        path: path.path,
        permissions: identity.permissions
    )
}

private actor FixtureCleanupCoordinator {
    private enum State {
        case complete(Result<Void, FixtureCleanupError>)
        case idle
        case running(Task<Result<Void, FixtureCleanupError>, Never>)
    }

    private let engine: FixtureCleanupEngine
    private var state = State.idle

    init(engine: FixtureCleanupEngine) {
        self.engine = engine
    }

    func result() async -> Result<Void, FixtureCleanupError> {
        do {
            try await engine.configuration.checkpoints.cleanupRequested()
        } catch {
            return .failure(.checkpointFailure)
        }

        let task: Task<Result<Void, FixtureCleanupError>, Never>
        switch state {
        case let .complete(result):
            return result
        case .idle:
            let cleanupEngine = engine
            task = Task.detached {
                await cleanupEngine.result()
            }
            state = .running(task)
        case let .running(running):
            do {
                try await engine.configuration.checkpoints.cleanupJoinedInFlight()
            } catch {
                return .failure(.checkpointFailure)
            }
            task = running
        }

        let result = await task.value
        state = .complete(result)
        return result
    }
}

package enum FixtureRecoveryDirectoryPinError: Error, Sendable, Equatable {
    case alreadyAbsent
    case cleanupStateUnverifiable
    case identityChanged
    case released
    case systemCall(operation: String, code: Int32)
}

private enum FixtureRecoverySocketDirectoryPhase: Sendable, Equatable {
    case claimed
    case removed
    case ready

    var entryName: String? {
        switch self {
        case .claimed:
            return "c"
        case .removed:
            return nil
        case .ready:
            return "s"
        }
    }

    var nonselectedEntryName: String? {
        switch self {
        case .claimed:
            return "s"
        case .removed:
            return nil
        case .ready:
            return "c"
        }
    }
}

package enum FixtureRecoveryJournalPhase: Sendable, Equatable {
    case claimed
    case innerOnly
    case runRemoved
    case unclaimed
}

package enum FixtureRecoveryJournalClaimResult: Sendable {
    case absent
    case claimed(
        phase: FixtureRecoveryJournalPhase,
        claim: OwnerLeaseRecoveryClaim
    )
    case missingMarkers
}

private struct FixtureRecoveryDirectoryPinState: Sendable {
    var parentDescriptor: Int32
    var runDescriptor: Int32
    var socketDescriptor: Int32
    var socketDirectoryPhase: FixtureRecoverySocketDirectoryPhase?
    var journalPhase: FixtureRecoveryJournalPhase?
}

private func fixtureRecoveryIdentityIfPresent(
    directoryDescriptor: Int32,
    name: String,
    expected: FixturePathKind,
    operation: String
) throws -> FixturePathIdentity? {
    do {
        return try fixturePathIdentity(
            directoryDescriptor: directoryDescriptor,
            name: name,
            expected: expected,
            operation: operation
        )
    } catch let FixtureCleanupError.filesystem(_, code) where code == ENOENT {
        return nil
    }
}

package final class FixtureRecoveryDirectoryPins: Sendable {
    fileprivate let runDirectory: URL
    fileprivate let runName: String

    #if canImport(Darwin)
        private let state: OSAllocatedUnfairLock<FixtureRecoveryDirectoryPinState>
    #else
        private let state: Mutex<FixtureRecoveryDirectoryPinState>
    #endif

    private init(
        parentDescriptor: Int32,
        runDescriptor: Int32,
        socketDescriptor: Int32,
        runDirectory: URL,
        runName: String
    ) {
        self.runDirectory = runDirectory
        self.runName = runName
        let initialState = FixtureRecoveryDirectoryPinState(
            parentDescriptor: parentDescriptor,
            runDescriptor: runDescriptor,
            socketDescriptor: socketDescriptor,
            socketDirectoryPhase: nil,
            journalPhase: nil
        )
        #if canImport(Darwin)
            state = OSAllocatedUnfairLock(initialState: initialState)
        #else
            state = Mutex(initialState)
        #endif
    }

    package static func acquire(
        runDirectory: URL
    ) throws -> FixtureRecoveryDirectoryPins {
        let parent = runDirectory.deletingLastPathComponent()
        let directoryFlags = Int32(
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        let parentDescriptor = parent.path.withCString {
            open($0, directoryFlags)
        }
        guard parentDescriptor >= 0 else {
            if errno == ENOENT {
                throw FixtureRecoveryDirectoryPinError.alreadyAbsent
            }
            throw FixtureRecoveryDirectoryPinError.systemCall(
                operation: "open-recovery-parent",
                code: errno
            )
        }

        var runDescriptor: Int32 = -1
        do {
            let runName = runDirectory.lastPathComponent
            let pathRunIdentity = try fixtureRecoveryIdentityIfPresent(
                directoryDescriptor: parentDescriptor,
                name: runName,
                expected: .directory,
                operation: "fstatat-recovery-run-directory"
            )
            guard let pathRunIdentity else {
                return FixtureRecoveryDirectoryPins(
                    parentDescriptor: parentDescriptor,
                    runDescriptor: -1,
                    socketDescriptor: -1,
                    runDirectory: runDirectory,
                    runName: runName
                )
            }
            runDescriptor = runName.withCString {
                openat(parentDescriptor, $0, directoryFlags)
            }
            guard runDescriptor >= 0 else {
                throw FixtureRecoveryDirectoryPinError.systemCall(
                    operation: "openat-recovery-run-directory",
                    code: errno
                )
            }
            let descriptorRunIdentity = try fixtureDescriptorIdentity(
                runDescriptor,
                expected: .directory,
                operation: "fstat-recovery-run-directory"
            )
            guard descriptorRunIdentity == pathRunIdentity else {
                throw FixtureRecoveryDirectoryPinError.identityChanged
            }

            return FixtureRecoveryDirectoryPins(
                parentDescriptor: parentDescriptor,
                runDescriptor: runDescriptor,
                socketDescriptor: -1,
                runDirectory: runDirectory,
                runName: runName
            )
        } catch {
            if runDescriptor >= 0 {
                _ = close(runDescriptor)
            }
            _ = close(parentDescriptor)
            if error is FixtureRecoveryDirectoryPinError {
                throw error
            }
            throw FixtureRecoveryDirectoryPinError.identityChanged
        }
    }

    package func claimRecoveryJournal(
        innerMarker: URL,
        sidecar: URL,
        descriptorClose: @escaping OwnerLeaseDescriptorClose = ownerLeaseDescriptorClose
    ) throws -> FixtureRecoveryJournalClaimResult {
        let expectedSidecarName = ".\(runName).owner.json"
        guard innerMarker == runDirectory.appendingPathComponent("owner.json"),
            sidecar.deletingLastPathComponent()
                == runDirectory.deletingLastPathComponent(),
            sidecar.lastPathComponent == expectedSidecarName
        else {
            throw FixtureRecoveryDirectoryPinError.identityChanged
        }

        do {
            return try state.withLock { state in
                guard state.parentDescriptor >= 0 else {
                    throw FixtureRecoveryDirectoryPinError.released
                }
                let sidecarIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.parentDescriptor,
                    name: expectedSidecarName,
                    expected: .regular,
                    operation: "fstatat-recovery-sidecar"
                )

                guard state.runDescriptor >= 0 else {
                    try requireDirectoryEntryAbsent(
                        directoryDescriptor: state.parentDescriptor,
                        name: runName,
                        operation: "validate-recovery-run-directory-absence"
                    )
                    guard sidecarIdentity != nil else {
                        return .absent
                    }
                    let claim = try OwnerLease.claimRecoveryMarker(
                        marker: sidecar,
                        directoryDescriptor: state.parentDescriptor,
                        markerName: expectedSidecarName,
                        descriptorClose: descriptorClose
                    )
                    guard
                        fixtureRecoveryOwnerIdentity(
                            claim.lease.identity,
                            matches: sidecarIdentity
                        )
                    else {
                        throw FixtureRecoveryDirectoryPinError.identityChanged
                    }
                    state.journalPhase = .runRemoved
                    return .claimed(phase: .runRemoved, claim: claim)
                }

                let innerIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.runDescriptor,
                    name: "owner.json",
                    expected: .regular,
                    operation: "fstatat-recovery-owner"
                )
                let phase: FixtureRecoveryJournalPhase
                let marker: URL
                let directoryDescriptor: Int32
                let markerName: String
                let selectedIdentity: FixturePathIdentity
                switch (innerIdentity, sidecarIdentity) {
                case (.none, .none):
                    return .missingMarkers
                case let (.some(inner), .none):
                    phase = .innerOnly
                    marker = innerMarker
                    directoryDescriptor = state.runDescriptor
                    markerName = "owner.json"
                    selectedIdentity = inner
                case let (.some(inner), .some(sidecarIdentity)):
                    guard inner == sidecarIdentity else {
                        throw FixtureRecoveryDirectoryPinError.identityChanged
                    }
                    phase = .unclaimed
                    marker = sidecar
                    directoryDescriptor = state.parentDescriptor
                    markerName = expectedSidecarName
                    selectedIdentity = sidecarIdentity
                case let (.none, .some(sidecarIdentity)):
                    phase = .claimed
                    marker = sidecar
                    directoryDescriptor = state.parentDescriptor
                    markerName = expectedSidecarName
                    selectedIdentity = sidecarIdentity
                }

                let claim = try OwnerLease.claimRecoveryMarker(
                    marker: marker,
                    directoryDescriptor: directoryDescriptor,
                    markerName: markerName,
                    descriptorClose: descriptorClose
                )
                guard
                    fixtureRecoveryOwnerIdentity(
                        claim.lease.identity,
                        matches: selectedIdentity
                    )
                else {
                    throw FixtureRecoveryDirectoryPinError.identityChanged
                }
                state.journalPhase = phase
                return .claimed(phase: phase, claim: claim)
            }
        } catch let error as FixtureRecoveryDirectoryPinError {
            throw error
        } catch let FixtureCleanupError.filesystem(operation, code) {
            throw fixtureRecoveryDirectoryPinFailure(
                operation: operation,
                code: code
            )
        }
    }

    package func repairRecoverySidecar(
        ownerLease: OwnerLease
    ) throws {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0,
                state.journalPhase == .innerOnly
            else {
                throw FixtureRecoveryDirectoryPinError.identityChanged
            }
            let sidecarName = ".\(runName).owner.json"
            let innerIdentity = try fixturePathIdentity(
                directoryDescriptor: state.runDescriptor,
                name: "owner.json",
                expected: .regular,
                operation: "fstatat-recovery-owner-before-sidecar-repair"
            )
            guard
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: innerIdentity
                )
            else {
                throw FixtureRecoveryDirectoryPinError.identityChanged
            }
            try requireDirectoryEntryAbsent(
                directoryDescriptor: state.parentDescriptor,
                name: sidecarName,
                operation: "validate-recovery-sidecar-vacancy"
            )
            let linkResult = "owner.json".withCString { inner in
                sidecarName.withCString { sidecar in
                    linkat(
                        state.runDescriptor,
                        inner,
                        state.parentDescriptor,
                        sidecar,
                        0
                    )
                }
            }
            guard linkResult == 0 else {
                throw FixtureRecoveryDirectoryPinError.systemCall(
                    operation: "linkat-recovery-sidecar",
                    code: errno
                )
            }
            let repairedIdentity = try fixturePathIdentity(
                directoryDescriptor: state.parentDescriptor,
                name: sidecarName,
                expected: .regular,
                operation: "fstatat-recovery-sidecar-after-repair"
            )
            guard repairedIdentity == innerIdentity else {
                throw FixtureRecoveryDirectoryPinError.identityChanged
            }
            guard fsync(state.parentDescriptor) == 0 else {
                throw FixtureRecoveryDirectoryPinError.systemCall(
                    operation: "fsync-recovery-parent-after-sidecar-repair",
                    code: errno
                )
            }
            state.journalPhase = .unclaimed
        }
    }

    fileprivate func adoptLifecycleJournal(
        ownerLease: OwnerLease
    ) throws {
        let needsRepair = try state.withLock { state -> Bool in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0,
                state.journalPhase == nil
            else {
                throw FixtureRecoveryDirectoryPinError.identityChanged
            }
            let innerIdentity = try fixturePathIdentity(
                directoryDescriptor: state.runDescriptor,
                name: "owner.json",
                expected: .regular,
                operation: "fstatat-lifecycle-owner"
            )
            guard
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: innerIdentity
                )
            else {
                throw FixtureRecoveryDirectoryPinError.identityChanged
            }
            let sidecarIdentity = try fixtureRecoveryIdentityIfPresent(
                directoryDescriptor: state.parentDescriptor,
                name: ".\(runName).owner.json",
                expected: .regular,
                operation: "fstatat-lifecycle-sidecar"
            )
            if let sidecarIdentity {
                guard sidecarIdentity == innerIdentity else {
                    throw FixtureRecoveryDirectoryPinError.identityChanged
                }
                state.journalPhase = .unclaimed
                return false
            }
            state.journalPhase = .innerOnly
            return true
        }
        if needsRepair {
            try repairRecoverySidecar(ownerLease: ownerLease)
        }
    }

    package func validatesRemovedRun(
        _ markerRecord: FixtureRecoveryMarkerRecord,
        ownerLease: OwnerLease
    ) -> Bool {
        let ready = markerRecord.ready
        guard ready.runDirectory.path == runDirectory.path else {
            return false
        }
        return
            (try? state.withLock { state in
                guard state.parentDescriptor >= 0,
                    state.runDescriptor < 0,
                    state.journalPhase == .runRemoved
                else {
                    return false
                }
                try requireDirectoryEntryAbsent(
                    directoryDescriptor: state.parentDescriptor,
                    name: runName,
                    operation: "validate-recovery-run-directory-absence"
                )
                let sidecarIdentity = try fixturePathIdentity(
                    directoryDescriptor: state.parentDescriptor,
                    name: ".\(runName).owner.json",
                    expected: .regular,
                    operation: "fstatat-recovery-sidecar"
                )
                return sidecarIdentity
                    == fixturePathIdentity(ready.ownershipMarker)
                    && fixtureRecoveryOwnerIdentity(
                        ownerLease.identity,
                        matches: sidecarIdentity
                    )
            }) ?? false
    }

    package func validates(
        _ markerRecord: FixtureRecoveryMarkerRecord,
        ownerLease: OwnerLease,
        journalPhase: FixtureRecoveryJournalPhase
    ) -> Bool {
        let ready = markerRecord.ready
        guard ready.runDirectory.path == runDirectory.path else {
            return false
        }
        return
            (try? state.withLock { state in
                guard state.parentDescriptor >= 0,
                    state.runDescriptor >= 0,
                    state.journalPhase == journalPhase,
                    let socketPhase = state.socketDirectoryPhase
                else {
                    return false
                }
                let expectedRun = fixturePathIdentity(ready.runDirectory)
                let expectedConfiguration = fixturePathIdentity(
                    ready.configurationFile
                )
                let expectedMarker = fixturePathIdentity(ready.ownershipMarker)
                let expectedSocketDirectory = fixturePathIdentity(
                    ready.socketDirectory
                )
                let expectedSocket = fixturePathIdentity(ready.socket)
                let sidecarName = ".\(runName).owner.json"
                let innerIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.runDescriptor,
                    name: "owner.json",
                    expected: .regular,
                    operation: "fstatat-recovery-owner"
                )
                let sidecarIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.parentDescriptor,
                    name: sidecarName,
                    expected: .regular,
                    operation: "fstatat-recovery-sidecar"
                )
                let configurationIdentity =
                    try fixtureRecoveryIdentityIfPresent(
                        directoryDescriptor: state.runDescriptor,
                        name: "tmux.conf",
                        expected: .regular,
                        operation: "fstatat-recovery-configuration"
                    )
                let markersAreValid: Bool
                switch journalPhase {
                case .innerOnly:
                    markersAreValid =
                        innerIdentity == expectedMarker
                        && sidecarIdentity == nil
                case .unclaimed:
                    markersAreValid =
                        innerIdentity == expectedMarker
                        && sidecarIdentity == expectedMarker
                case .claimed:
                    markersAreValid =
                        innerIdentity == nil
                        && sidecarIdentity == expectedMarker
                case .runRemoved:
                    return false
                }
                let configurationIsValid =
                    configurationIdentity == expectedConfiguration
                    || (journalPhase == .claimed
                        && configurationIdentity == nil)
                guard markersAreValid,
                    configurationIsValid,
                    recoveryIdentity(
                        directoryDescriptor: state.parentDescriptor,
                        name: runName,
                        expected: .directory
                    ) == expectedRun,
                    recoveryIdentity(
                        descriptor: state.runDescriptor,
                        expected: .directory
                    ) == expectedRun,
                    fixtureRecoveryOwnerIdentity(
                        ownerLease.identity,
                        matches: expectedMarker
                    )
                else {
                    return false
                }

                guard let entryName = socketPhase.entryName else {
                    return journalPhase == .claimed
                        && state.socketDescriptor < 0
                }
                guard state.socketDescriptor >= 0,
                    recoveryIdentity(
                        directoryDescriptor: state.runDescriptor,
                        name: entryName,
                        expected: .directory
                    ) == expectedSocketDirectory,
                    recoveryIdentity(
                        descriptor: state.socketDescriptor,
                        expected: .directory
                    ) == expectedSocketDirectory
                else {
                    return false
                }
                if let nonselectedEntryName = socketPhase.nonselectedEntryName {
                    try requireDirectoryEntryAbsent(
                        directoryDescriptor: state.runDescriptor,
                        name: nonselectedEntryName,
                        operation: "validate-recovery-artifacts"
                    )
                }
                let socketIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.socketDescriptor,
                    name: "s",
                    expected: .socket,
                    operation: "fstatat-recovery-socket"
                )
                return socketIdentity == expectedSocket
                    || (journalPhase == .claimed && socketIdentity == nil)
            }) ?? false
    }

    package func withRunDescriptor<Value>(
        _ operation: (Int32) throws -> Value
    ) throws -> Value {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0
            else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            return try operation(state.runDescriptor)
        }
    }

    package func pinSocketDirectory(allowsMissing: Bool = false) throws {
        do {
            try state.withLock { state in
                guard state.parentDescriptor >= 0,
                    state.runDescriptor >= 0
                else {
                    throw FixtureRecoveryDirectoryPinError.released
                }
                let readyIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.runDescriptor,
                    name: "s",
                    expected: .directory,
                    operation: "fstatat-recovery-socket-directory"
                )
                let claimedIdentity = try fixtureRecoveryIdentityIfPresent(
                    directoryDescriptor: state.runDescriptor,
                    name: "c",
                    expected: .directory,
                    operation: "fstatat-recovery-claimed-directory"
                )
                let phase: FixtureRecoverySocketDirectoryPhase
                let pathIdentity: FixturePathIdentity?
                switch (readyIdentity, claimedIdentity) {
                case let (.some(identity), .none):
                    phase = .ready
                    pathIdentity = identity
                case let (.none, .some(identity)):
                    phase = .claimed
                    pathIdentity = identity
                case (.none, .none) where allowsMissing:
                    phase = .removed
                    pathIdentity = nil
                case (.none, .none):
                    throw FixtureRecoveryDirectoryPinError.cleanupStateUnverifiable
                default:
                    throw FixtureRecoveryDirectoryPinError.identityChanged
                }
                if phase == .removed {
                    guard state.socketDescriptor < 0 else {
                        throw FixtureRecoveryDirectoryPinError.identityChanged
                    }
                    state.socketDirectoryPhase = phase
                    return
                }
                guard let pathIdentity,
                    let entryName = phase.entryName
                else {
                    throw FixtureRecoveryDirectoryPinError.identityChanged
                }
                if state.socketDescriptor >= 0 {
                    let descriptorIdentity = try fixtureDescriptorIdentity(
                        state.socketDescriptor,
                        expected: .directory,
                        operation: "fstat-recovery-socket-directory"
                    )
                    guard descriptorIdentity == pathIdentity,
                        state.socketDirectoryPhase == phase
                    else {
                        throw FixtureRecoveryDirectoryPinError.identityChanged
                    }
                    return
                }
                let directoryFlags = Int32(
                    O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
                )
                let socketDescriptor = entryName.withCString {
                    openat(state.runDescriptor, $0, directoryFlags)
                }
                guard socketDescriptor >= 0 else {
                    throw fixtureRecoveryDirectoryPinFailure(
                        operation: "openat-recovery-socket-directory",
                        code: errno
                    )
                }
                do {
                    let descriptorIdentity = try fixtureDescriptorIdentity(
                        socketDescriptor,
                        expected: .directory,
                        operation: "fstat-recovery-socket-directory"
                    )
                    guard descriptorIdentity == pathIdentity else {
                        throw FixtureRecoveryDirectoryPinError.identityChanged
                    }
                    state.socketDescriptor = socketDescriptor
                    state.socketDirectoryPhase = phase
                } catch {
                    _ = close(socketDescriptor)
                    throw error
                }
            }
        } catch let error as FixtureRecoveryDirectoryPinError {
            throw error
        } catch let FixtureCleanupError.filesystem(operation, code) {
            throw fixtureRecoveryDirectoryPinFailure(
                operation: operation,
                code: code
            )
        } catch {
            throw FixtureRecoveryDirectoryPinError.identityChanged
        }
    }

    fileprivate func duplicateCleanupDescriptors() throws -> (
        socket: Int32,
        run: Int32,
        phase: FixtureRecoverySocketDirectoryPhase
    ) {
        try withDescriptors { _, run, socket, phase in
            let socketDuplicate = fcntl(socket, F_DUPFD_CLOEXEC, 0)
            guard socketDuplicate >= 0 else {
                throw FixtureCleanupError.filesystem(
                    operation: "dup-recovery-socket-directory",
                    code: errno
                )
            }
            let runDuplicate = fcntl(run, F_DUPFD_CLOEXEC, 0)
            guard runDuplicate >= 0 else {
                let code = errno
                _ = close(socketDuplicate)
                throw FixtureCleanupError.filesystem(
                    operation: "dup-recovery-run-directory",
                    code: code
                )
            }
            return (
                socket: socketDuplicate,
                run: runDuplicate,
                phase: phase
            )
        }
    }

    fileprivate var socketDirectoryWasRemoved: Bool {
        state.withLock { state in
            state.socketDirectoryPhase == .removed
                && state.socketDescriptor < 0
        }
    }

    fileprivate func validateRunPath(
        expected: FixturePathIdentity
    ) throws {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0
            else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            let pathIdentity = try fixturePathIdentity(
                directoryDescriptor: state.parentDescriptor,
                name: runName,
                expected: .directory,
                operation: "fstatat-recovery-run-directory"
            )
            let descriptorIdentity = try fixtureDescriptorIdentity(
                state.runDescriptor,
                expected: .directory,
                operation: "fstat-recovery-run-directory"
            )
            guard pathIdentity == expected,
                descriptorIdentity == expected
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-run-directory",
                    code: ESTALE
                )
            }
        }
    }

    fileprivate func validateForCleanup(
        fixture: TmuxFixture,
        identities: FixtureArtifactIdentities,
        endpointIdentity: FixturePathIdentity,
        ownerLease: OwnerLease,
        journalPhase: FixtureRecoveryJournalPhase,
        allowsMissingEndpoint: Bool = false
    ) throws {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0,
                state.journalPhase == journalPhase,
                let phase = state.socketDirectoryPhase
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-artifacts",
                    code: ESTALE
                )
            }
            let parent = state.parentDescriptor
            let run = state.runDescriptor
            let pathRunIdentity = try fixturePathIdentity(
                directoryDescriptor: parent,
                name: runName,
                expected: .directory,
                operation: "fstatat-recovery-run-directory"
            )
            let descriptorRunIdentity = try fixtureDescriptorIdentity(
                run,
                expected: .directory,
                operation: "fstat-recovery-run-directory"
            )
            let configurationIdentity = try fixtureRecoveryIdentityIfPresent(
                directoryDescriptor: run,
                name: fixture.configurationFile.lastPathComponent,
                expected: .regular,
                operation: "fstatat-recovery-configuration"
            )
            let markerIdentity = try fixtureRecoveryIdentityIfPresent(
                directoryDescriptor: run,
                name: fixture.ownershipMarker.lastPathComponent,
                expected: .regular,
                operation: "fstatat-recovery-owner"
            )
            let sidecarIdentity = try fixtureRecoveryIdentityIfPresent(
                directoryDescriptor: parent,
                name: ".\(runName).owner.json",
                expected: .regular,
                operation: "fstatat-recovery-sidecar"
            )
            let expectedOwnerIdentity = identities.ownershipMarker
            let markersAreValid: Bool
            switch journalPhase {
            case .innerOnly:
                markersAreValid =
                    markerIdentity == expectedOwnerIdentity
                    && sidecarIdentity == nil
            case .unclaimed:
                markersAreValid =
                    markerIdentity == expectedOwnerIdentity
                    && sidecarIdentity == expectedOwnerIdentity
            case .claimed:
                markersAreValid =
                    markerIdentity == nil
                    && sidecarIdentity == expectedOwnerIdentity
            case .runRemoved:
                markersAreValid = false
            }
            let configurationIsValid =
                configurationIdentity == identities.configurationFile
                || (journalPhase == .claimed && configurationIdentity == nil)
            guard pathRunIdentity == identities.runDirectory,
                descriptorRunIdentity == identities.runDirectory,
                configurationIsValid,
                markersAreValid,
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: expectedOwnerIdentity
                )
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-artifacts",
                    code: ESTALE
                )
            }

            guard let entryName = phase.entryName else {
                guard journalPhase == .claimed,
                    state.socketDescriptor < 0
                else {
                    throw FixtureCleanupError.filesystem(
                        operation: "validate-recovery-artifacts",
                        code: ESTALE
                    )
                }
                return
            }
            guard state.socketDescriptor >= 0 else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-artifacts",
                    code: ESTALE
                )
            }
            let socket = state.socketDescriptor
            if let nonselectedEntryName = phase.nonselectedEntryName {
                try requireDirectoryEntryAbsent(
                    directoryDescriptor: run,
                    name: nonselectedEntryName,
                    operation: "validate-recovery-artifacts"
                )
            }
            let socketDirectoryIdentity = try fixturePathIdentity(
                directoryDescriptor: run,
                name: entryName,
                expected: .directory,
                operation: "fstatat-recovery-socket-directory"
            )
            let descriptorSocketDirectoryIdentity =
                try fixtureDescriptorIdentity(
                    socket,
                    expected: .directory,
                    operation: "fstat-recovery-socket-directory"
                )
            guard case let .socketPath(socketPath) = fixture.endpoint else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-socket-path",
                    code: EINVAL
                )
            }
            let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
            let socketIdentity = try fixtureRecoveryIdentityIfPresent(
                directoryDescriptor: socket,
                name: socketName,
                expected: .socket,
                operation: "fstatat-recovery-socket"
            )
            let socketIsValid =
                socketIdentity == endpointIdentity
                || (allowsMissingEndpoint && socketIdentity == nil)
                || (journalPhase == .claimed && socketIdentity == nil)
            guard socketDirectoryIdentity == identities.socketDirectory,
                descriptorSocketDirectoryIdentity == identities.socketDirectory,
                socketIsValid
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-artifacts",
                    code: ESTALE
                )
            }
        }
    }

    fileprivate func unlinkArtifact(
        name: String,
        expected: FixturePathIdentity,
        operation: String,
        allowsMissing: Bool = false
    ) throws {
        try state.withLock { state in
            guard state.runDescriptor >= 0 else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            do {
                try unlinkRecoveryArtifact(
                    directoryDescriptor: state.runDescriptor,
                    name: name,
                    expected: expected,
                    operation: operation
                )
            } catch let FixtureCleanupError.filesystem(_, code)
                where allowsMissing && code == ENOENT
            {
                try requireDirectoryEntryAbsent(
                    directoryDescriptor: state.runDescriptor,
                    name: name,
                    operation: "validate-recovery-\(operation)-absence"
                )
            }
            guard fsync(state.runDescriptor) == 0 else {
                throw FixtureCleanupError.filesystem(
                    operation: "fsync-recovery-run-after-\(operation)",
                    code: errno
                )
            }
        }
    }

    fileprivate func claimCleanup(ownerLease: OwnerLease) throws {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0
            else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            let sidecarName = ".\(runName).owner.json"
            let sidecarIdentity = try fixturePathIdentity(
                directoryDescriptor: state.parentDescriptor,
                name: sidecarName,
                expected: .regular,
                operation: "fstatat-recovery-sidecar-before-claim"
            )
            guard
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: sidecarIdentity
                )
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-sidecar-before-claim",
                    code: ESTALE
                )
            }
            if state.journalPhase == .claimed {
                try requireDirectoryEntryAbsent(
                    directoryDescriptor: state.runDescriptor,
                    name: "owner.json",
                    operation: "validate-recovery-owner-claim"
                )
                return
            }
            guard state.journalPhase == .unclaimed else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-journal-before-claim",
                    code: ESTALE
                )
            }
            let innerIdentity = try fixturePathIdentity(
                directoryDescriptor: state.runDescriptor,
                name: "owner.json",
                expected: .regular,
                operation: "fstatat-recovery-owner-before-claim"
            )
            guard innerIdentity == sidecarIdentity,
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: innerIdentity
                )
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-owner-before-claim",
                    code: ESTALE
                )
            }
            guard
                "owner.json".withCString({
                    unlinkat(state.runDescriptor, $0, 0)
                }) == 0
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "unlinkat-recovery-owner-claim",
                    code: errno
                )
            }
            try requireDirectoryEntryAbsent(
                directoryDescriptor: state.runDescriptor,
                name: "owner.json",
                operation: "validate-recovery-owner-claim"
            )
            guard fsync(state.runDescriptor) == 0 else {
                throw FixtureCleanupError.filesystem(
                    operation: "fsync-recovery-run-after-owner-claim",
                    code: errno
                )
            }
            state.journalPhase = .claimed
        }
    }

    package func removeRecoverySidecar(
        ownerLease: OwnerLease,
        requireRunAbsent: Bool
    ) throws {
        try state.withLock { state in
            guard state.parentDescriptor >= 0 else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            if requireRunAbsent {
                try requireDirectoryEntryAbsent(
                    directoryDescriptor: state.parentDescriptor,
                    name: runName,
                    operation: "validate-recovery-run-directory-absence"
                )
            }
            let sidecarName = ".\(runName).owner.json"
            let sidecarIdentity = try fixturePathIdentity(
                directoryDescriptor: state.parentDescriptor,
                name: sidecarName,
                expected: .regular,
                operation: "fstatat-recovery-sidecar-before-removal"
            )
            guard
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: sidecarIdentity
                )
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-sidecar-before-removal",
                    code: ESTALE
                )
            }
            guard
                sidecarName.withCString({
                    unlinkat(state.parentDescriptor, $0, 0)
                }) == 0
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "unlinkat-recovery-sidecar",
                    code: errno
                )
            }
            try requireDirectoryEntryAbsent(
                directoryDescriptor: state.parentDescriptor,
                name: sidecarName,
                operation: "validate-recovery-sidecar-absence"
            )
            guard fsync(state.parentDescriptor) == 0 else {
                throw FixtureCleanupError.filesystem(
                    operation: "fsync-recovery-parent-after-sidecar-removal",
                    code: errno
                )
            }
        }
    }

    fileprivate func removeRunDirectory(
        expected: FixturePathIdentity,
        ownerLease: OwnerLease
    ) throws {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0
            else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            let parent = state.parentDescriptor
            let run = state.runDescriptor
            let sidecarIdentity = try fixturePathIdentity(
                directoryDescriptor: parent,
                name: ".\(runName).owner.json",
                expected: .regular,
                operation: "fstatat-recovery-sidecar-before-run-removal"
            )
            guard
                fixtureRecoveryOwnerIdentity(
                    ownerLease.identity,
                    matches: sidecarIdentity
                )
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-sidecar-before-run-removal",
                    code: ESTALE
                )
            }
            let descriptorIdentity = try fixtureDescriptorIdentity(
                run,
                expected: .directory,
                operation: "fstat-recovery-run-directory-before-removal"
            )
            let pathIdentity = try fixturePathIdentity(
                directoryDescriptor: parent,
                name: runName,
                expected: .directory,
                operation: "fstatat-recovery-run-directory-before-removal"
            )
            guard descriptorIdentity == expected,
                pathIdentity == expected
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-run-directory",
                    code: ESTALE
                )
            }
            guard
                runName.withCString({
                    unlinkat(parent, $0, AT_REMOVEDIR)
                }) == 0
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "unlinkat-recovery-run-directory",
                    code: errno
                )
            }
            try requireDirectoryEntryAbsent(
                directoryDescriptor: parent,
                name: runName,
                operation: "validate-recovery-run-directory-absence"
            )
            guard fsync(parent) == 0 else {
                throw FixtureCleanupError.filesystem(
                    operation: "fsync-recovery-parent-after-run-removal",
                    code: errno
                )
            }
        }
    }

    package func release() {
        let descriptors = state.withLock { state -> (Int32, Int32, Int32)? in
            guard state.parentDescriptor >= 0 else { return nil }
            let descriptors = (
                state.parentDescriptor,
                state.runDescriptor,
                state.socketDescriptor
            )
            state.parentDescriptor = -1
            state.runDescriptor = -1
            state.socketDescriptor = -1
            state.socketDirectoryPhase = nil
            state.journalPhase = nil
            return descriptors
        }
        guard let descriptors else { return }
        if descriptors.2 >= 0 {
            _ = close(descriptors.2)
        }
        if descriptors.1 >= 0 {
            _ = close(descriptors.1)
        }
        _ = close(descriptors.0)
    }

    deinit {
        release()
    }

    private func withDescriptors<Value>(
        _ operation: (
            Int32,
            Int32,
            Int32,
            FixtureRecoverySocketDirectoryPhase
        ) throws -> Value
    ) throws -> Value {
        try state.withLock { state in
            guard state.parentDescriptor >= 0,
                state.runDescriptor >= 0,
                state.socketDescriptor >= 0,
                let socketDirectoryPhase = state.socketDirectoryPhase
            else {
                throw FixtureRecoveryDirectoryPinError.released
            }
            return try operation(
                state.parentDescriptor,
                state.runDescriptor,
                state.socketDescriptor,
                socketDirectoryPhase
            )
        }
    }
}

private func recoveryIdentity(
    descriptor: Int32,
    expected: FixturePathKind
) -> FixturePathIdentity? {
    try? fixtureDescriptorIdentity(
        descriptor,
        expected: expected,
        operation: "fstat-recovery-artifact"
    )
}

private func fixtureRecoveryOwnerIdentity(
    _ ownerIdentity: OwnerLeaseIdentity,
    matches pathIdentity: FixturePathIdentity?
) -> Bool {
    guard let pathIdentity else { return false }
    return pathIdentity.kind == .regular
        && ownerIdentity.device == pathIdentity.device
        && ownerIdentity.inode == pathIdentity.inode
        && ownerIdentity.permissions == pathIdentity.permissions
}

private func fixtureRecoveryDirectoryPinFailure(
    operation: String,
    code: Int32
) -> FixtureRecoveryDirectoryPinError {
    if code == ENOENT || code == ENOTDIR || code == ELOOP
        || code == EINVAL || code == ESTALE || code == EACCES
    {
        return .identityChanged
    }
    return .systemCall(operation: operation, code: code)
}

private func recoveryIdentity(
    directoryDescriptor: Int32,
    name: String,
    expected: FixturePathKind
) -> FixturePathIdentity? {
    try? fixturePathIdentity(
        directoryDescriptor: directoryDescriptor,
        name: name,
        expected: expected,
        operation: "fstatat-recovery-artifact"
    )
}

private func fixturePathIdentity(
    _ artifact: FixtureRecoveryArtifactRecord
) -> FixturePathIdentity {
    let kind: FixturePathKind
    switch artifact.kind {
    case .directory:
        kind = .directory
    case .regular:
        kind = .regular
    case .socket:
        kind = .socket
    }
    return FixturePathIdentity(
        device: artifact.device,
        inode: artifact.inode,
        kind: kind,
        permissions: artifact.permissions
    )
}

private struct FixtureSocketCleanupLock: Sendable {
    let directoryDescriptor: Int32
    let lockDescriptor: Int32
    let lockIdentity: FixturePathIdentity
    let lockName: String
    let recoveryRunDescriptor: Int32?
    let recoverySocketDirectoryPhase: FixtureRecoverySocketDirectoryPhase?
    let socketDirectory: URL
    let socketDirectoryIdentity: FixturePathIdentity
    let socketName: String

    static func acquire(
        socketPath: String,
        socketDirectory: URL,
        expectedDirectoryIdentity: FixturePathIdentity,
        retryInterval: Duration,
        onContention: @Sendable () async throws -> Void,
        recoveryPins: FixtureRecoveryDirectoryPins? = nil
    ) async throws -> FixtureSocketCleanupLock {
        let socketURL = URL(fileURLWithPath: socketPath)
        guard
            socketURL.deletingLastPathComponent().standardizedFileURL.path
                == socketDirectory.standardizedFileURL.path,
            !socketURL.lastPathComponent.isEmpty
        else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-socket-path",
                code: EINVAL
            )
        }

        if recoveryPins == nil {
            try requireIdentity(
                socketDirectory,
                expected: expectedDirectoryIdentity,
                operation: "lstat-socket-directory-before-lock"
            )
        }
        let directoryFlags = Int32(
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        let directoryDescriptor: Int32
        let recoveryRunDescriptor: Int32?
        let recoverySocketDirectoryPhase: FixtureRecoverySocketDirectoryPhase?
        if let recoveryPins {
            let duplicates = try recoveryPins.duplicateCleanupDescriptors()
            directoryDescriptor = duplicates.socket
            recoveryRunDescriptor = duplicates.run
            recoverySocketDirectoryPhase = duplicates.phase
        } else {
            directoryDescriptor = socketDirectory.path.withCString {
                open($0, directoryFlags)
            }
            recoveryRunDescriptor = nil
            recoverySocketDirectoryPhase = nil
        }
        guard directoryDescriptor >= 0 else {
            throw FixtureCleanupError.filesystem(
                operation: "open-socket-directory",
                code: errno
            )
        }

        var lockDescriptor: Int32 = -1
        do {
            let directoryIdentity = try fixtureDescriptorIdentity(
                directoryDescriptor,
                expected: .directory,
                operation: "fstat-socket-directory"
            )
            guard directoryIdentity == expectedDirectoryIdentity else {
                throw FixtureCleanupError.filesystem(
                    operation: "fstat-socket-directory",
                    code: ESTALE
                )
            }

            let socketName = socketURL.lastPathComponent
            let lockName = "\(socketName).lock"
            let lockFlags = Int32(
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            while true {
                lockDescriptor = lockName.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        lockFlags,
                        mode_t(0o600)
                    )
                }
                guard lockDescriptor >= 0 else {
                    throw FixtureCleanupError.filesystem(
                        operation: "open-socket-lock",
                        code: errno
                    )
                }
                let lockIdentity = try fixtureDescriptorIdentity(
                    lockDescriptor,
                    expected: .regular,
                    operation: "fstat-socket-lock"
                )
                var lockStatus = stat()
                guard fstat(lockDescriptor, &lockStatus) == 0 else {
                    throw FixtureCleanupError.filesystem(
                        operation: "fstat-socket-lock-mode",
                        code: errno
                    )
                }
                guard UInt32(lockStatus.st_mode) & 0o777 == 0o600 else {
                    throw FixtureCleanupError.filesystem(
                        operation: "validate-socket-lock-mode",
                        code: EACCES
                    )
                }

                let lockResult = fixtureFlock(
                    lockDescriptor,
                    Int32(LOCK_EX | LOCK_NB)
                )
                var shouldReportContention = false
                if lockResult == 0 {
                    let pathIdentity: FixturePathIdentity?
                    do {
                        pathIdentity = try fixturePathIdentity(
                            directoryDescriptor: directoryDescriptor,
                            name: lockName,
                            expected: .regular,
                            operation: "fstatat-socket-lock-after-flock"
                        )
                    } catch let FixtureCleanupError.filesystem(_, code)
                        where code == ENOENT
                    {
                        pathIdentity = nil
                    }
                    if pathIdentity == lockIdentity {
                        return FixtureSocketCleanupLock(
                            directoryDescriptor: directoryDescriptor,
                            lockDescriptor: lockDescriptor,
                            lockIdentity: lockIdentity,
                            lockName: lockName,
                            recoveryRunDescriptor: recoveryRunDescriptor,
                            recoverySocketDirectoryPhase:
                                recoverySocketDirectoryPhase,
                            socketDirectory: socketDirectory,
                            socketDirectoryIdentity: expectedDirectoryIdentity,
                            socketName: socketName
                        )
                    }
                    _ = fixtureFlock(lockDescriptor, Int32(LOCK_UN))
                    shouldReportContention = true
                } else {
                    let code = errno
                    if code != EINTR, code != EAGAIN, code != EWOULDBLOCK {
                        throw FixtureCleanupError.filesystem(
                            operation: "flock-socket-lock",
                            code: code
                        )
                    }
                    shouldReportContention = code == EAGAIN || code == EWOULDBLOCK
                }

                _ = close(lockDescriptor)
                lockDescriptor = -1
                if shouldReportContention {
                    try await onContention()
                }
                try await Task.sleep(for: retryInterval)
            }
        } catch {
            if lockDescriptor >= 0 {
                _ = close(lockDescriptor)
            }
            if let recoveryRunDescriptor {
                _ = close(recoveryRunDescriptor)
            }
            _ = close(directoryDescriptor)
            throw error
        }
    }

    func removeSocketAndLock(
        expectedSocketIdentity: FixturePathIdentity,
        runDirectory: URL,
        expectedRunDirectoryIdentity: FixturePathIdentity,
        afterSocketIdentityValidation: @Sendable () async throws -> Void,
        beforeClaimedSocketDirectoryValidation: @Sendable () async throws -> Void
    ) async throws {
        if recoveryRunDescriptor == nil {
            try requireIdentity(
                socketDirectory,
                expected: socketDirectoryIdentity,
                operation: "lstat-socket-directory-before-unlink"
            )
        }
        let currentLockIdentity = try fixturePathIdentity(
            directoryDescriptor: directoryDescriptor,
            name: lockName,
            expected: .regular,
            operation: "fstatat-socket-lock-before-unlink"
        )
        guard currentLockIdentity == lockIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-socket-lock-identity",
                code: ESTALE
            )
        }

        let socketWasPresent: Bool
        do {
            let currentSocketIdentity = try fixturePathIdentity(
                directoryDescriptor: directoryDescriptor,
                name: socketName,
                expected: .socket,
                operation: "fstatat-socket"
            )
            guard currentSocketIdentity == expectedSocketIdentity else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-socket-identity",
                    code: ESTALE
                )
            }
            socketWasPresent = true
        } catch let FixtureCleanupError.filesystem(_, code) where code == ENOENT {
            socketWasPresent = false
        }

        let claimedDirectory = try claimSocketDirectory(
            runDirectory: runDirectory,
            expectedRunDirectoryIdentity: expectedRunDirectoryIdentity
        )
        do {
            try await afterSocketIdentityValidation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FixtureCleanupError.checkpointFailure
        }
        try requireSocketDirectoryPathAbsent(
            operation: "validate-socket-directory-vacancy"
        )

        if socketWasPresent {
            let finalSocketIdentity = try fixturePathIdentity(
                directoryDescriptor: directoryDescriptor,
                name: socketName,
                expected: .socket,
                operation: "fstatat-socket-before-unlink"
            )
            guard finalSocketIdentity == expectedSocketIdentity else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-socket-identity",
                    code: ESTALE
                )
            }
            guard
                socketName.withCString({
                    unlinkat(directoryDescriptor, $0, 0)
                }) == 0
            else {
                throw FixtureCleanupError.filesystem(
                    operation: "unlink-socket",
                    code: errno
                )
            }
        } else {
            try requireDirectoryEntryAbsent(
                directoryDescriptor: directoryDescriptor,
                name: socketName,
                operation: "validate-socket-absence"
            )
        }

        let finalLockIdentity = try fixturePathIdentity(
            directoryDescriptor: directoryDescriptor,
            name: lockName,
            expected: .regular,
            operation: "fstatat-socket-lock"
        )
        guard finalLockIdentity == lockIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-socket-lock-identity",
                code: ESTALE
            )
        }
        guard
            lockName.withCString({
                unlinkat(directoryDescriptor, $0, 0)
            }) == 0
        else {
            throw FixtureCleanupError.filesystem(
                operation: "unlink-socket-lock",
                code: errno
            )
        }
        do {
            try await beforeClaimedSocketDirectoryValidation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FixtureCleanupError.checkpointFailure
        }
        try removeClaimedSocketDirectory(
            claimedDirectory,
            runDirectory: runDirectory,
            expectedRunDirectoryIdentity: expectedRunDirectoryIdentity
        )
        try requireSocketDirectoryPathAbsent(
            operation: "validate-socket-directory-vacancy"
        )
    }

    private func claimSocketDirectory(
        runDirectory: URL,
        expectedRunDirectoryIdentity: FixturePathIdentity
    ) throws -> URL {
        guard
            socketDirectory.deletingLastPathComponent().standardizedFileURL.path
                == runDirectory.standardizedFileURL.path,
            !socketDirectory.lastPathComponent.isEmpty
        else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-socket-directory-path",
                code: EINVAL
            )
        }
        if recoveryRunDescriptor == nil {
            try requireIdentity(
                socketDirectory,
                expected: socketDirectoryIdentity,
                operation: "lstat-socket-directory-before-claim"
            )
            try requireIdentity(
                runDirectory,
                expected: expectedRunDirectoryIdentity,
                operation: "lstat-run-directory-before-claim"
            )
        }

        let parentFlags = Int32(
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        let parentDescriptor: Int32
        if let recoveryRunDescriptor {
            parentDescriptor = fcntl(
                recoveryRunDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
        } else {
            parentDescriptor = runDirectory.path.withCString {
                open($0, parentFlags)
            }
        }
        guard parentDescriptor >= 0 else {
            throw FixtureCleanupError.filesystem(
                operation: "open-run-directory-for-claim",
                code: errno
            )
        }
        defer { _ = close(parentDescriptor) }

        let parentIdentity = try fixtureDescriptorIdentity(
            parentDescriptor,
            expected: .directory,
            operation: "fstat-run-directory-for-claim"
        )
        guard parentIdentity == expectedRunDirectoryIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "fstat-run-directory-for-claim",
                code: ESTALE
            )
        }
        let sourceName = socketDirectory.lastPathComponent
        let tombstoneName = "c"
        if recoverySocketDirectoryPhase == .claimed {
            guard recoveryRunDescriptor != nil else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-claimed-recovery-directory",
                    code: EINVAL
                )
            }
            let claimedIdentity = try fixturePathIdentity(
                directoryDescriptor: parentDescriptor,
                name: tombstoneName,
                expected: .directory,
                operation: "fstatat-claimed-socket-directory"
            )
            guard claimedIdentity == socketDirectoryIdentity else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-claimed-socket-directory",
                    code: ESTALE
                )
            }
            try requireDirectoryEntryAbsent(
                directoryDescriptor: parentDescriptor,
                name: sourceName,
                operation: "validate-socket-directory-vacancy"
            )
            return runDirectory.appendingPathComponent(tombstoneName)
        }
        let sourceIdentity = try fixturePathIdentity(
            directoryDescriptor: parentDescriptor,
            name: sourceName,
            expected: .directory,
            operation: "fstatat-socket-directory-before-claim"
        )
        guard sourceIdentity == socketDirectoryIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "fstatat-socket-directory-before-claim",
                code: ESTALE
            )
        }
        let renameResult = sourceName.withCString { source in
            tombstoneName.withCString { tombstone in
                fixtureRenameExclusive(
                    oldDirectory: parentDescriptor,
                    oldName: source,
                    newDirectory: parentDescriptor,
                    newName: tombstone
                )
            }
        }
        guard renameResult == 0 else {
            throw FixtureCleanupError.filesystem(
                operation: "rename-socket-directory-for-cleanup",
                code: errno
            )
        }

        let claimedIdentity = try fixturePathIdentity(
            directoryDescriptor: parentDescriptor,
            name: tombstoneName,
            expected: .directory,
            operation: "fstatat-claimed-socket-directory"
        )
        guard claimedIdentity == socketDirectoryIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-claimed-socket-directory",
                code: ESTALE
            )
        }
        try requireDirectoryEntryAbsent(
            directoryDescriptor: parentDescriptor,
            name: sourceName,
            operation: "validate-socket-directory-vacancy"
        )
        return runDirectory.appendingPathComponent(tombstoneName)
    }

    private func removeClaimedSocketDirectory(
        _ claimedDirectory: URL,
        runDirectory: URL,
        expectedRunDirectoryIdentity: FixturePathIdentity
    ) throws {
        guard
            claimedDirectory.deletingLastPathComponent().standardizedFileURL.path
                == runDirectory.standardizedFileURL.path,
            !claimedDirectory.lastPathComponent.isEmpty
        else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-claimed-socket-directory-path",
                code: EINVAL
            )
        }
        if recoveryRunDescriptor == nil {
            try requireIdentity(
                runDirectory,
                expected: expectedRunDirectoryIdentity,
                operation: "lstat-run-directory-before-claimed-removal"
            )
        }

        let parentFlags = Int32(
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        let parentDescriptor: Int32
        if let recoveryRunDescriptor {
            parentDescriptor = fcntl(
                recoveryRunDescriptor,
                F_DUPFD_CLOEXEC,
                0
            )
        } else {
            parentDescriptor = runDirectory.path.withCString {
                open($0, parentFlags)
            }
        }
        guard parentDescriptor >= 0 else {
            throw FixtureCleanupError.filesystem(
                operation: "open-run-directory-for-claimed-removal",
                code: errno
            )
        }
        defer { _ = close(parentDescriptor) }

        let parentIdentity = try fixtureDescriptorIdentity(
            parentDescriptor,
            expected: .directory,
            operation: "fstat-run-directory-for-claimed-removal"
        )
        guard parentIdentity == expectedRunDirectoryIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "fstat-run-directory-for-claimed-removal",
                code: ESTALE
            )
        }

        let claimedName = claimedDirectory.lastPathComponent
        // POSIX has no conditional rmdir by inode. This private 0700 namespace
        // is cooperative lifecycle state, not a same-UID security boundary, so
        // keep the final identity check and unlink adjacent without suspension.
        let claimedIdentity = try fixturePathIdentity(
            directoryDescriptor: parentDescriptor,
            name: claimedName,
            expected: .directory,
            operation: "fstatat-claimed-socket-directory-before-removal"
        )
        guard claimedIdentity == socketDirectoryIdentity else {
            throw FixtureCleanupError.filesystem(
                operation: "validate-claimed-socket-directory",
                code: ESTALE
            )
        }
        guard
            claimedName.withCString({
                unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }) == 0
        else {
            throw FixtureCleanupError.filesystem(
                operation: "unlinkat-claimed-socket-directory",
                code: errno
            )
        }
        try requireDirectoryEntryAbsent(
            directoryDescriptor: parentDescriptor,
            name: claimedName,
            operation: "validate-claimed-socket-directory-absence"
        )
    }

    func release() {
        if let currentLockIdentity = try? fixturePathIdentity(
            directoryDescriptor: directoryDescriptor,
            name: lockName,
            expected: .regular,
            operation: "fstatat-socket-lock-on-release"
        ), currentLockIdentity == lockIdentity {
            _ = lockName.withCString {
                unlinkat(directoryDescriptor, $0, 0)
            }
        }
        _ = fixtureFlock(lockDescriptor, Int32(LOCK_UN))
        _ = close(lockDescriptor)
        _ = close(directoryDescriptor)
        if let recoveryRunDescriptor {
            _ = close(recoveryRunDescriptor)
        }
    }

    private func requireSocketDirectoryPathAbsent(
        operation: String
    ) throws {
        if let recoveryRunDescriptor {
            try requireDirectoryEntryAbsent(
                directoryDescriptor: recoveryRunDescriptor,
                name: socketDirectory.lastPathComponent,
                operation: operation
            )
        } else {
            try requirePathAbsent(
                socketDirectory,
                operation: operation
            )
        }
    }
}

private enum FixtureCleanupMode: Sendable, Equatable {
    case lifecycle
    case recovery(FixtureRecoveryJournalPhase)

    var recoveryJournalPhase: FixtureRecoveryJournalPhase? {
        guard case let .recovery(phase) = self else { return nil }
        return phase
    }

    var performsOwnershipGuard: Bool {
        switch self {
        case .lifecycle, .recovery(.innerOnly), .recovery(.unclaimed):
            return true
        case .recovery(.claimed), .recovery(.runRemoved):
            return false
        }
    }
}

package func cleanupRecoveredFixture(
    markerRecord: FixtureRecoveryMarkerRecord,
    configuration: FixtureRecoveryConfiguration,
    tmuxExecutable: ProcessExecutable,
    transport: any ProcessTransport,
    ownerLease: OwnerLease,
    pins: FixtureRecoveryDirectoryPins,
    journalPhase: FixtureRecoveryJournalPhase
) async throws -> FixtureRecoveryResult {
    defer { pins.release() }
    let ready = markerRecord.ready
    guard let token = UUID(uuidString: ready.token),
        token.uuidString == ready.token
    else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    let endpoint = TmuxEndpoint.socketPath(ready.socket.path)
    let incarnation = try ServerIncarnationID(
        endpoint: endpoint,
        token: token
    )
    let fixture = TmuxFixture(
        runDirectory: URL(
            fileURLWithPath: ready.runDirectory.path,
            isDirectory: true
        ),
        socketDirectory: URL(
            fileURLWithPath: ready.socketDirectory.path,
            isDirectory: true
        ),
        configurationFile: URL(
            fileURLWithPath: ready.configurationFile.path
        ),
        ownershipMarker: URL(
            fileURLWithPath: ready.ownershipMarker.path
        ),
        ownershipRecord: FixtureOwnershipRecord(
            marker: URL(fileURLWithPath: ready.ownershipMarker.path),
            token: token
        ),
        endpoint: endpoint,
        incarnation: incarnation
    )
    let identities = FixtureArtifactIdentities(
        configurationFile: fixturePathIdentity(ready.configurationFile),
        ownershipMarker: fixturePathIdentity(ready.ownershipMarker),
        runDirectory: fixturePathIdentity(ready.runDirectory),
        socketDirectory: fixturePathIdentity(ready.socketDirectory)
    )
    let startupState = FixtureStartupState()
    await startupState.recordInitialEndpointIdentity(
        fixturePathIdentity(ready.socket)
    )
    let lifecycleConfiguration = FixtureConfiguration(
        runRoot: fixture.runDirectory.deletingLastPathComponent(),
        tmuxExecutable: tmuxExecutable,
        childEnvironment: configuration.childEnvironment,
        startupDeadline: .seconds(0),
        cleanupDeadline: configuration.cleanupDeadline,
        checkpointInterval: configuration.checkpointInterval,
        timing: configuration.timing,
        checkpoints: configuration.checkpoints
    )
    let engine = FixtureCleanupEngine(
        fixture: fixture,
        configuration: lifecycleConfiguration,
        transport: transport,
        ownerLease: ownerLease,
        identities: identities,
        startupState: startupState,
        mode: .recovery(journalPhase),
        recoveryPins: pins
    )
    try await engine.result().get()
    return .cleaned
}

private struct FixtureCleanupEngine: Sendable {
    let fixture: TmuxFixture
    let configuration: FixtureConfiguration
    let transport: any ProcessTransport
    let ownerLease: OwnerLease
    let identities: FixtureArtifactIdentities
    let startupState: FixtureStartupState
    let mode: FixtureCleanupMode
    let recoveryPins: FixtureRecoveryDirectoryPins?

    func result() async -> Result<Void, FixtureCleanupError> {
        do {
            try await withFixtureDeadline(
                duration: configuration.cleanupDeadline,
                timing: configuration.timing
            ) {
                try await performCleanup()
            }
            return .success(())
        } catch is FixtureDeadlineReached {
            return .failure(.deadlineExceeded)
        } catch let error as FixtureCleanupError {
            return .failure(error)
        } catch {
            return .failure(.checkpointFailure)
        }
    }

    private func performCleanup() async throws {
        guard case let .socketPath(socketPath) = fixture.endpoint else {
            throw FixtureCleanupError.guardTransportFailure
        }
        if let recoveryPins,
            let endpointIdentity = await startupState.endpointIdentity,
            let journalPhase = mode.recoveryJournalPhase
        {
            try recoveryPins.validateForCleanup(
                fixture: fixture,
                identities: identities,
                endpointIdentity: endpointIdentity,
                ownerLease: ownerLease,
                journalPhase: journalPhase
            )
        }
        if mode.performsOwnershipGuard {
            let mismatchSentinel = UUID().uuidString
            let condition =
                "#{==:#{\(fixtureIncarnationOption)},"
                + "\(fixture.incarnation.token.uuidString)}"
            let matchingBranch = "kill-server"
            let mismatchingBranch = "display-message -p \(mismatchSentinel)"
            let guardRequest = try fixtureRequest(
                executable: configuration.tmuxExecutable,
                arguments: [
                    "-N", "-S", socketPath,
                    "if-shell", "-F", condition,
                    matchingBranch, mismatchingBranch,
                ],
                environment: configuration.childEnvironment.emitted()
            )
            let guardReply: ProcessReply
            do {
                guardReply = try await transport.run(guardRequest)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FixtureCleanupError.guardTransportFailure
            }
            try validateGuardReply(
                guardReply,
                mismatchSentinel: mismatchSentinel
            )
        }

        if let recoveryPins,
            let endpointIdentity = await startupState.endpointIdentity,
            let journalPhase = mode.recoveryJournalPhase
        {
            try recoveryPins.validateForCleanup(
                fixture: fixture,
                identities: identities,
                endpointIdentity: endpointIdentity,
                ownerLease: ownerLease,
                journalPhase: journalPhase,
                allowsMissingEndpoint: mode.performsOwnershipGuard
            )
        }

        let socketLock: FixtureSocketCleanupLock?
        if let recoveryPins, recoveryPins.socketDirectoryWasRemoved {
            guard mode.recoveryJournalPhase == .claimed else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-socket-directory-removal",
                    code: ESTALE
                )
            }
            socketLock = nil
        } else {
            socketLock = try await FixtureSocketCleanupLock.acquire(
                socketPath: socketPath,
                socketDirectory: fixture.socketDirectory,
                expectedDirectoryIdentity: identities.socketDirectory,
                retryInterval: configuration.checkpointInterval,
                onContention: configuration.checkpoints.socketLockContended,
                recoveryPins: recoveryPins
            )
        }
        defer { socketLock?.release() }

        let absenceRequest = try fixtureRequest(
            executable: configuration.tmuxExecutable,
            arguments: [
                "-N", "-S", socketPath,
                "display-message", "-p", "#{socket_path}",
            ],
            environment: configuration.childEnvironment.emitted()
        )
        while true {
            if let recoveryPins {
                try recoveryPins.validateRunPath(
                    expected: identities.runDirectory
                )
            }
            let reply: ProcessReply
            do {
                reply = try await transport.run(absenceRequest)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FixtureCleanupError.endpointProbeTransportFailure
            }
            switch reply.termination {
            case .exited(1):
                guard let endpointIdentity = await startupState.endpointIdentity else {
                    throw FixtureCleanupError.filesystem(
                        operation: "missing-socket-identity",
                        code: ESTALE
                    )
                }
                guard
                    try await fixtureEndpointIsAbsent(
                        socketPath: socketPath,
                        expectedIdentity: endpointIdentity
                    )
                else {
                    throw FixtureCleanupError.endpointProbeFailed(reply)
                }
                try await removeKnownArtifacts(
                    socketLock: socketLock,
                    endpointIdentity: endpointIdentity
                )
                return
            case .exited(0):
                try await Task.sleep(for: configuration.checkpointInterval)
            default:
                throw FixtureCleanupError.endpointProbeFailed(reply)
            }
        }
    }

    private func validateGuardReply(
        _ reply: ProcessReply,
        mismatchSentinel: String
    ) throws {
        if mode.recoveryJournalPhase != nil,
            reply.termination == .exited(1),
            reply.standardOutput.isEmpty,
            reply.standardError.isEmpty
        {
            return
        }
        guard fixtureReplySucceeded(reply) else {
            throw FixtureCleanupError.guardRequestFailed(reply)
        }
        if reply.standardOutput.isEmpty {
            return
        }
        let lines = fixtureReplyLines(reply)
        guard !lines.isEmpty else {
            throw FixtureCleanupError.malformedSentinel(reply)
        }
        guard lines.count == 1 else {
            throw FixtureCleanupError.extraSentinel(reply)
        }
        guard UUID(uuidString: lines[0]) != nil else {
            throw FixtureCleanupError.malformedSentinel(reply)
        }
        if lines[0] == mismatchSentinel {
            throw FixtureCleanupError.ownershipMismatch(reply)
        }
        throw FixtureCleanupError.malformedSentinel(reply)
    }

    private func removeKnownArtifacts(
        socketLock: FixtureSocketCleanupLock?,
        endpointIdentity: FixturePathIdentity
    ) async throws {
        let journalPins: FixtureRecoveryDirectoryPins
        let releasesJournalPins: Bool
        let initialJournalPhase: FixtureRecoveryJournalPhase
        if let recoveryPins {
            guard let journalPhase = mode.recoveryJournalPhase else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-journal-mode",
                    code: EINVAL
                )
            }
            if journalPhase != .claimed, socketLock == nil {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-recovery-socket-lock",
                    code: ESTALE
                )
            }
            journalPins = recoveryPins
            releasesJournalPins = false
            initialJournalPhase = journalPhase
        } else {
            guard socketLock != nil else {
                throw FixtureCleanupError.filesystem(
                    operation: "validate-lifecycle-socket-lock",
                    code: ESTALE
                )
            }
            do {
                let pins = try FixtureRecoveryDirectoryPins.acquire(
                    runDirectory: fixture.runDirectory
                )
                do {
                    try pins.adoptLifecycleJournal(ownerLease: ownerLease)
                    try pins.pinSocketDirectory()
                    try pins.validateForCleanup(
                        fixture: fixture,
                        identities: identities,
                        endpointIdentity: endpointIdentity,
                        ownerLease: ownerLease,
                        journalPhase: .unclaimed,
                        allowsMissingEndpoint: true
                    )
                } catch {
                    pins.release()
                    throw error
                }
                journalPins = pins
                releasesJournalPins = true
                initialJournalPhase = .unclaimed
            } catch let error as FixtureCleanupError {
                throw error
            } catch {
                throw FixtureCleanupError.filesystem(
                    operation: "prepare-lifecycle-journal",
                    code: ESTALE
                )
            }
        }
        defer {
            if releasesJournalPins {
                journalPins.release()
            }
        }
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.beforeRecoveryClaim
        )
        try journalPins.claimCleanup(ownerLease: ownerLease)
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.afterRecoveryClaimSynchronization
        )
        do {
            try await configuration.checkpoints.beforeSocketDirectoryRemoval()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FixtureCleanupError.checkpointFailure
        }

        if let socketLock {
            try await socketLock.removeSocketAndLock(
                expectedSocketIdentity: endpointIdentity,
                runDirectory: fixture.runDirectory,
                expectedRunDirectoryIdentity: identities.runDirectory,
                afterSocketIdentityValidation:
                    configuration.checkpoints.afterSocketIdentityValidation,
                beforeClaimedSocketDirectoryValidation:
                    configuration.checkpoints.beforeClaimedSocketDirectoryValidation
            )
        }

        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.beforeConfigurationRemoval
        )
        try journalPins.unlinkArtifact(
            name: fixture.configurationFile.lastPathComponent,
            expected: identities.configurationFile,
            operation: "configuration",
            allowsMissing: initialJournalPhase == .claimed
        )
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.afterConfigurationRemoval
        )
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.beforeRunDirectoryRemoval
        )
        try journalPins.removeRunDirectory(
            expected: identities.runDirectory,
            ownerLease: ownerLease
        )
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.afterRunDirectoryRemoval
        )
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.beforeRecoverySidecarRemoval
        )
        try journalPins.removeRecoverySidecar(
            ownerLease: ownerLease,
            requireRunAbsent: true
        )
        try await recoveryCleanupCheckpoint(
            configuration.checkpoints.afterRecoverySidecarRemoval
        )

        let closeResult = await ownerLease.closeResult()
        if case let .failure(error) = closeResult {
            throw FixtureCleanupError.ownerCloseFailed(error)
        }
    }

    private func recoveryCleanupCheckpoint(
        _ checkpoint: @Sendable () async throws -> Void
    ) async throws {
        do {
            try await checkpoint()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FixtureCleanupError.checkpointFailure
        }
    }
}

private func unlinkRecoveryArtifact(
    directoryDescriptor: Int32,
    name: String,
    expected: FixturePathIdentity,
    operation: String
) throws {
    let identity = try fixturePathIdentity(
        directoryDescriptor: directoryDescriptor,
        name: name,
        expected: expected.kind,
        operation: "fstatat-recovery-\(operation)"
    )
    guard identity == expected else {
        throw FixtureCleanupError.filesystem(
            operation: "validate-recovery-\(operation)",
            code: ESTALE
        )
    }
    guard name.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 else {
        throw FixtureCleanupError.filesystem(
            operation: "unlinkat-recovery-\(operation)",
            code: errno
        )
    }
    try requireDirectoryEntryAbsent(
        directoryDescriptor: directoryDescriptor,
        name: name,
        operation: "validate-recovery-\(operation)-absence"
    )
}

private func fixtureRequest(
    executable: ProcessExecutable,
    arguments: [String],
    environment: [String: String]
) throws -> ProcessRequest {
    try ProcessRequest(
        executable: executable,
        arguments: arguments,
        environment: environment,
        workingDirectory: nil,
        outputPolicy: .complete
    )
}

private func fixtureReplySucceeded(_ reply: ProcessReply) -> Bool {
    reply.termination == .exited(0) && reply.standardError.isEmpty
}

private func fixtureReplyLines(_ reply: ProcessReply) -> [String] {
    String(decoding: reply.standardOutput, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private func fixtureReplyToken(_ reply: ProcessReply) -> UUID? {
    guard fixtureReplySucceeded(reply) else { return nil }
    let lines = fixtureReplyLines(reply)
    guard lines.count == 1 else { return nil }
    return UUID(uuidString: lines[0])
}

private func fixtureEndpointIsAbsent(
    socketPath: String,
    expectedIdentity: FixturePathIdentity
) async throws -> Bool {
    let endpoint = URL(fileURLWithPath: socketPath)
    guard let beforeConnect = try fixtureSocketIdentityIfPresent(endpoint) else {
        return true
    }
    guard beforeConnect == expectedIdentity else {
        throw FixtureCleanupError.filesystem(
            operation: "validate-socket-identity",
            code: ESTALE
        )
    }

    #if canImport(Darwin)
        let socketType = SOCK_STREAM
    #else
        let socketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let descriptor = socket(AF_UNIX, socketType, 0)
    guard descriptor >= 0 else {
        throw FixtureCleanupError.filesystem(
            operation: "socket-endpoint-absence",
            code: errno
        )
    }
    defer { _ = close(descriptor) }
    let statusFlags = fcntl(descriptor, F_GETFL)
    let descriptorFlags = fcntl(descriptor, F_GETFD)
    guard
        statusFlags >= 0,
        descriptorFlags >= 0,
        fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0,
        fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
    else {
        throw FixtureCleanupError.filesystem(
            operation: "fcntl-endpoint-absence",
            code: errno
        )
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let pathBytes = Array(socketPath.utf8) + [UInt8(0)]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw FixtureCleanupError.filesystem(
            operation: "connect-endpoint-absence",
            code: ENAMETOOLONG
        )
    }
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: pathBytes)
    }

    let connectResult: Int32
    while true {
        try Task.checkCancellation()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 || errno != EINTR {
            connectResult = result
            break
        }
        await Task.yield()
    }
    try Task.checkCancellation()
    if connectResult == 0 {
        return false
    }
    let connectCode = errno
    if connectCode == EAGAIN || connectCode == EWOULDBLOCK
        || connectCode == EINPROGRESS || connectCode == EALREADY
        || connectCode == EISCONN
    {
        return false
    }
    guard connectCode == ECONNREFUSED || connectCode == ENOENT else {
        throw FixtureCleanupError.filesystem(
            operation: "connect-endpoint-absence",
            code: connectCode
        )
    }

    guard let afterConnect = try fixtureSocketIdentityIfPresent(endpoint) else {
        return true
    }
    guard afterConnect == expectedIdentity else {
        throw FixtureCleanupError.filesystem(
            operation: "validate-socket-identity",
            code: ESTALE
        )
    }
    guard connectCode == ECONNREFUSED else {
        throw FixtureCleanupError.filesystem(
            operation: "connect-endpoint-absence",
            code: connectCode
        )
    }
    return true
}

private func fixtureSocketIdentityIfPresent(
    _ endpoint: URL
) throws -> FixturePathIdentity? {
    do {
        return try fixturePathIdentity(endpoint, expected: .socket)
    } catch let FixtureCleanupError.filesystem(_, code) where code == ENOENT {
        return nil
    }
}

private func createPrivateDirectory(parent: URL, prefix: String) throws -> URL {
    for _ in 0..<32 {
        let suffix = fixtureDirectoryNonce()
        let candidate = parent.appendingPathComponent(
            "\(prefix)-\(suffix)"
        )
        let result = candidate.path.withCString {
            mkdir($0, mode_t(0o700))
        }
        if result == 0 {
            guard candidate.path.withCString({ chmod($0, mode_t(0o700)) }) == 0 else {
                let code = errno
                _ = removeDirectory(candidate)
                throw FixtureStartError.filesystem(
                    operation: "chmod-run-directory",
                    code: code
                )
            }
            return candidate
        }
        if errno != EEXIST {
            throw FixtureStartError.filesystem(
                operation: "mkdir-run-directory",
                code: errno
            )
        }
    }
    throw FixtureStartError.filesystem(
        operation: "mkdir-run-directory",
        code: EEXIST
    )
}

private func fixtureDirectoryNonce() -> String {
    var identifier = UUID().uuid
    return withUnsafeBytes(of: &identifier) { Data($0) }
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Lexical containment. A symlinked candidate can still resolve inside the
/// ancestor, so this rejects the plain mistake rather than proving isolation.
private func pathIsWithin(_ candidate: String, _ ancestor: URL) -> Bool {
    let candidateComponents = URL(fileURLWithPath: candidate)
        .standardizedFileURL
        .pathComponents
    let ancestorComponents = ancestor.standardizedFileURL.pathComponents
    guard candidateComponents.count >= ancestorComponents.count else {
        return false
    }
    return Array(candidateComponents.prefix(ancestorComponents.count))
        == ancestorComponents
}

private func createPrivateDirectory(at directory: URL) throws {
    guard directory.path.withCString({ mkdir($0, mode_t(0o700)) }) == 0 else {
        throw FixtureStartError.filesystem(
            operation: "mkdir-socket-directory",
            code: errno
        )
    }
    guard directory.path.withCString({ chmod($0, mode_t(0o700)) }) == 0 else {
        let code = errno
        _ = removeDirectory(directory)
        throw FixtureStartError.filesystem(
            operation: "chmod-socket-directory",
            code: code
        )
    }
}

private func writeExclusiveFile(
    _ file: URL,
    bytes: [UInt8],
    permissions: UInt16
) throws {
    let flags = Int32(O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW)
    var descriptor = file.path.withCString {
        open($0, flags, mode_t(permissions))
    }
    guard descriptor >= 0 else {
        throw FixtureStartError.filesystem(
            operation: "open-configuration",
            code: errno
        )
    }
    defer {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }

    do {
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw FixtureStartError.filesystem(
                operation: "fchmod-configuration",
                code: errno
            )
        }
        var written = 0
        try bytes.withUnsafeBytes { buffer in
            while written < buffer.count {
                let result = write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: written),
                    buffer.count - written
                )
                if result > 0 {
                    written += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw FixtureStartError.filesystem(
                        operation: "write-configuration",
                        code: errno
                    )
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw FixtureStartError.filesystem(
                operation: "fsync-configuration",
                code: errno
            )
        }
        let closeResult = close(descriptor)
        let closeCode = errno
        descriptor = -1
        guard closeResult == 0 else {
            throw FixtureStartError.filesystem(
                operation: "close-configuration",
                code: closeCode
            )
        }
    } catch {
        if descriptor >= 0 {
            _ = close(descriptor)
            descriptor = -1
        }
        _ = unlinkPath(file)
        throw error
    }
}

private func fixturePathIdentity(
    _ path: URL,
    expected: FixturePathKind
) throws -> FixturePathIdentity {
    var status = stat()
    let result = path.path.withCString { lstat($0, &status) }
    guard result == 0 else {
        throw FixtureCleanupError.filesystem(operation: "lstat", code: errno)
    }
    return try fixturePathIdentity(
        status: status,
        expected: expected,
        operation: "lstat-file-type"
    )
}

private func fixtureDescriptorIdentity(
    _ descriptor: Int32,
    expected: FixturePathKind,
    operation: String
) throws -> FixturePathIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw FixtureCleanupError.filesystem(
            operation: operation,
            code: errno
        )
    }
    return try fixturePathIdentity(
        status: status,
        expected: expected,
        operation: operation
    )
}

private func fixturePathIdentity(
    directoryDescriptor: Int32,
    name: String,
    expected: FixturePathKind,
    operation: String
) throws -> FixturePathIdentity {
    var status = stat()
    let result = name.withCString {
        fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        throw FixtureCleanupError.filesystem(
            operation: operation,
            code: errno
        )
    }
    return try fixturePathIdentity(
        status: status,
        expected: expected,
        operation: operation
    )
}

private func fixturePathIdentity(
    status: stat,
    expected: FixturePathKind,
    operation: String
) throws -> FixturePathIdentity {
    let mode = UInt32(status.st_mode)
    let kind: FixturePathKind
    switch mode & 0o170000 {
    case 0o040000:
        kind = .directory
    case 0o100000:
        kind = .regular
    case 0o140000:
        kind = .socket
    default:
        throw FixtureCleanupError.filesystem(
            operation: operation,
            code: EINVAL
        )
    }
    guard kind == expected else {
        throw FixtureCleanupError.filesystem(
            operation: operation,
            code: EINVAL
        )
    }
    return FixturePathIdentity(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        kind: kind,
        permissions: UInt16(mode & 0o777)
    )
}

private func fixtureFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    #if canImport(Darwin)
        Darwin.flock(descriptor, operation)
    #else
        linuxFlock(descriptor, operation)
    #endif
}

private func fixtureRenameExclusive(
    oldDirectory: Int32,
    oldName: UnsafePointer<CChar>,
    newDirectory: Int32,
    newName: UnsafePointer<CChar>
) -> Int32 {
    #if canImport(Darwin)
        renameatx_np(
            oldDirectory,
            oldName,
            newDirectory,
            newName,
            UInt32(RENAME_EXCL)
        )
    #else
        linuxRenameAt2(
            oldDirectory,
            oldName,
            newDirectory,
            newName,
            1
        )
    #endif
}

#if !canImport(Darwin)
    @_silgen_name("flock")
    private func linuxFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

    @_silgen_name("renameat2")
    private func linuxRenameAt2(
        _ oldDirectory: Int32,
        _ oldName: UnsafePointer<CChar>,
        _ newDirectory: Int32,
        _ newName: UnsafePointer<CChar>,
        _ flags: UInt32
    ) -> Int32
#endif

private func requirePathAbsent(
    _ path: URL,
    operation: String
) throws {
    var status = stat()
    let result = path.path.withCString { lstat($0, &status) }
    if result != 0, errno == ENOENT {
        return
    }
    throw FixtureCleanupError.filesystem(
        operation: operation,
        code: result == 0 ? ESTALE : errno
    )
}

private func requireDirectoryEntryAbsent(
    directoryDescriptor: Int32,
    name: String,
    operation: String
) throws {
    var status = stat()
    let result = name.withCString {
        fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    if result != 0, errno == ENOENT {
        return
    }
    throw FixtureCleanupError.filesystem(
        operation: operation,
        code: result == 0 ? ESTALE : errno
    )
}

private func requireIdentity(
    _ path: URL,
    expected: FixturePathIdentity,
    operation: String
) throws {
    do {
        let actual = try fixturePathIdentity(path, expected: expected.kind)
        guard actual == expected else {
            throw FixtureCleanupError.filesystem(
                operation: operation,
                code: ESTALE
            )
        }
    } catch let error as FixtureCleanupError {
        throw error
    } catch {
        throw FixtureCleanupError.filesystem(
            operation: operation,
            code: EINVAL
        )
    }
}

private func unlinkOrThrow(_ path: URL, operation: String) throws {
    guard path.path.withCString({ unlink($0) }) == 0 else {
        throw FixtureCleanupError.filesystem(operation: operation, code: errno)
    }
}

private func removeDirectoryOrThrow(_ path: URL, operation: String) throws {
    guard path.path.withCString({ rmdir($0) }) == 0 else {
        throw FixtureCleanupError.filesystem(operation: operation, code: errno)
    }
}

private func unlinkPath(_ path: URL) -> Int32 {
    path.path.withCString { unlink($0) }
}

private func removeDirectory(_ path: URL) -> Int32 {
    path.path.withCString { rmdir($0) }
}
