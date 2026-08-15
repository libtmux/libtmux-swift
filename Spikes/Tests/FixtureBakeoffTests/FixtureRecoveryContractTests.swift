import Foundation
import Testing

@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
    import os
#else
    import Glibc
    import Synchronization
#endif

private let recoveryTmuxExecutable = ProcessExecutable.path(
    "/opt/libtmux-tests/bin/tmux"
)
private let recoveryChildEnvironment = FixtureChildEnvironment(
    path: "/opt/libtmux-tests/bin:/usr/bin",
    temporaryDirectory: "/opt/libtmux-tests/scratch",
    developerDirectory: nil,
    sdkRoot: nil
)
private let recoveryMarkerToken = "7A67F268-C6CB-42C5-863B-C9CF9E80DF9A"
private let forcedRecoveryCloseError = OwnerLeaseCloseError.systemCall(
    operation: "close-owner",
    code: EIO
)
private let canonicalPreparingRecord =
    "{\"ownerProcessIdentifier\":123,\"token\":\"\(recoveryMarkerToken)\",\"version\":1}\n"
private let canonicalReadyRecord =
    "{\"configurationFile\":{\"device\":1,\"inode\":11,\"kind\":\"regular\","
    + "\"path\":\"/tmp/f-recovery/tmux.conf\",\"permissions\":384},"
    + "\"ownershipMarker\":{\"device\":1,\"inode\":12,\"kind\":\"regular\","
    + "\"path\":\"/tmp/f-recovery/owner.json\",\"permissions\":384},"
    + "\"runDirectory\":{\"device\":1,\"inode\":10,\"kind\":\"directory\","
    + "\"path\":\"/tmp/f-recovery\",\"permissions\":448},"
    + "\"socket\":{\"device\":1,\"inode\":14,\"kind\":\"socket\","
    + "\"path\":\"/tmp/f-recovery/s/s\",\"permissions\":493},"
    + "\"socketDirectory\":{\"device\":1,\"inode\":13,\"kind\":\"directory\","
    + "\"path\":\"/tmp/f-recovery/s\",\"permissions\":448},"
    + "\"state\":\"ready\",\"tmuxExecutablePath\":\"/opt/tmux/bin/tmux\","
    + "\"token\":\"\(recoveryMarkerToken)\",\"version\":1}\n"

enum MalformedRecoveryMarker: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case duplicateReady
    case missingReady
    case noncanonicalPreparing
    case noncanonicalReady
    case partialReady

    var testDescription: String { rawValue }

    var bytes: [UInt8] {
        switch self {
        case .duplicateReady:
            Array(
                (canonicalPreparingRecord + canonicalReadyRecord
                    + canonicalReadyRecord).utf8
            )
        case .missingReady:
            Array(canonicalPreparingRecord.utf8)
        case .noncanonicalPreparing:
            Array(
                (canonicalPreparingRecord.replacingOccurrences(
                    of: "{\"ownerProcessIdentifier\"",
                    with: "{ \"ownerProcessIdentifier\""
                ) + canonicalReadyRecord).utf8
            )
        case .noncanonicalReady:
            Array(
                (canonicalPreparingRecord
                    + canonicalReadyRecord.replacingOccurrences(
                        of: "{\"configurationFile\"",
                        with: "{ \"configurationFile\""
                    )).utf8
            )
        case .partialReady:
            Array(
                (canonicalPreparingRecord
                    + String(canonicalReadyRecord.dropLast(17))).utf8
            )
        }
    }
}

enum RecoveryExecutableExpectation: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case absent
    case nameBased

    var testDescription: String { rawValue }

    var executable: ProcessExecutable? {
        switch self {
        case .absent:
            nil
        case .nameBased:
            .name("tmux")
        }
    }
}

private actor RecoveryInvocationProbe: ProcessTransport {
    private(set) var invocationCount = 0

    func run(_ request: ProcessRequest) async throws -> ProcessReply {
        invocationCount += 1
        return ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(0)
        )
    }
}

private final class RecoveryCloseLockObservation: Sendable {
    #if canImport(Darwin)
        private let lock = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    #else
        private let lock = Mutex<Bool?>(nil)
    #endif

    func record(_ markerLockWasBusy: Bool) {
        lock.withLock { $0 = markerLockWasBusy }
    }

    var markerLockWasBusy: Bool? {
        lock.withLock { $0 }
    }
}

private actor RecoveryScriptedTransport: ProcessTransport {
    private let beforeReply: (@Sendable (Int) async throws -> Void)?
    private let marker: URL?
    private var replies: [ProcessReply]
    private(set) var requests: [ProcessRequest] = []
    private(set) var markerLockWasBusy: [Bool] = []

    init(
        replies: [ProcessReply],
        marker: URL? = nil,
        beforeReply: (@Sendable (Int) async throws -> Void)? = nil
    ) {
        self.replies = replies
        self.marker = marker
        self.beforeReply = beforeReply
    }

    func run(_ request: ProcessRequest) async throws -> ProcessReply {
        let requestIndex = requests.count
        requests.append(request)
        try await beforeReply?(requestIndex)
        if let marker {
            markerLockWasBusy.append(
                try recoveryMarkerLockIsBusy(marker)
            )
        }
        guard !replies.isEmpty else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        return replies.removeFirst()
    }
}

private struct RecoveryLockScope {
    let runDirectory: URL
    let marker: URL

    static func create() throws -> Self {
        let runDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("f-\(UUID().uuidString)")
        guard mkdir(runDirectory.path, 0o700) == 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        return Self(
            runDirectory: runDirectory,
            marker: runDirectory.appendingPathComponent("owner.json")
        )
    }

    func removeMarkerAndDirectory() {
        if unlink(marker.path) != 0, errno != ENOENT {
            Issue.record("failed to remove recovery lock marker")
        }
        if rmdir(runDirectory.path) != 0, errno != ENOENT {
            Issue.record("failed to remove recovery lock directory")
        }
    }
}

enum RecoveryArtifactReplacement: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case configurationFile
    case ownershipMarker
    case runDirectory
    case socket
    case socketDirectory

    var testDescription: String { rawValue }
}

enum RecoverySocketDirectoryInvalidity: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case missing
    case regularFile
    case simultaneousReadyAndClaimed

    var testDescription: String { rawValue }
}

enum RecoverableSocketDirectoryState: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case claimedEmpty
    case claimedWithEntries
    case ready

    var testDescription: String { rawValue }
}

enum RecoveryJournalState: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case claimedBothSocketDirectories
    case claimedNoSocketDirectory
    case claimedReady
    case claimedTombstoneEmpty
    case claimedTombstoneWithEntries
    case differentMarkerInodes
    case innerOnlyReady
    case missingAll
    case missingMarkers
    case runRemoved
    case unclaimed

    var testDescription: String { rawValue }
}

private struct RecoveryPathSnapshot: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
}

private final class RecoveryReadyScope {
    let runDirectory: URL
    let socketDirectory: URL
    let configurationFile: URL
    let ownershipMarker: URL
    let socketPath: URL
    let sidecar: URL
    let token: UUID

    private init(runDirectory: URL, token: UUID) {
        self.runDirectory = runDirectory
        socketDirectory = runDirectory.appendingPathComponent("s")
        configurationFile = runDirectory.appendingPathComponent("tmux.conf")
        ownershipMarker = runDirectory.appendingPathComponent("owner.json")
        socketPath = runDirectory.appendingPathComponent("s/s")
        sidecar = runDirectory.deletingLastPathComponent()
            .appendingPathComponent(".\(runDirectory.lastPathComponent).owner.json")
        self.token = token
    }

    static func create(
        recordedTmuxExecutablePath: String = "/opt/libtmux-tests/bin/tmux"
    ) async throws -> RecoveryReadyScope {
        let runDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("f-\(UUID().uuidString)")
        let token = UUID()
        let scope = RecoveryReadyScope(
            runDirectory: runDirectory,
            token: token
        )
        do {
            try recoveryCreatePrivateDirectory(scope.runDirectory)
            try recoveryCreatePrivateDirectory(scope.socketDirectory)
            try recoveryWriteExclusiveFile(
                scope.configurationFile,
                bytes: Array("set-option -g status off\n".utf8)
            )
            let lease = try OwnerLease.acquire(
                marker: scope.ownershipMarker,
                token: token
            )
            do {
                try recoveryCreateSocket(scope.socketPath)
                let record = FixtureRecoveryReadyRecord(
                    configurationFile: try recoveryArtifactRecord(
                        scope.configurationFile,
                        kind: .regular
                    ),
                    ownershipMarker: try recoveryArtifactRecord(
                        scope.ownershipMarker,
                        kind: .regular
                    ),
                    runDirectory: try recoveryArtifactRecord(
                        scope.runDirectory,
                        kind: .directory
                    ),
                    socket: try recoveryArtifactRecord(
                        scope.socketPath,
                        kind: .socket
                    ),
                    socketDirectory: try recoveryArtifactRecord(
                        scope.socketDirectory,
                        kind: .directory
                    ),
                    tmuxExecutablePath: recordedTmuxExecutablePath,
                    token: lease.record.token
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var readyBytes = [UInt8](try encoder.encode(record))
                readyBytes.append(0x0A)
                _ = try await lease.publishReadyRecord(readyBytes)
                try await lease.closeResult().get()
            } catch {
                _ = await lease.closeResult()
                throw error
            }
            return scope
        } catch {
            scope.removeArtifacts()
            throw error
        }
    }

    func replace(_ artifact: RecoveryArtifactReplacement) throws {
        switch artifact {
        case .configurationFile:
            let replacement = runDirectory.appendingPathComponent(
                ".configuration-replacement-\(UUID().uuidString)"
            )
            let bytes = try [UInt8](Data(contentsOf: configurationFile))
            try recoveryWriteExclusiveFile(replacement, bytes: bytes)
            guard rename(replacement.path, configurationFile.path) == 0 else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        case .ownershipMarker:
            let replacement = runDirectory.appendingPathComponent(
                ".owner-replacement-\(UUID().uuidString)"
            )
            let bytes = try [UInt8](Data(contentsOf: ownershipMarker))
            try recoveryWriteExclusiveFile(replacement, bytes: bytes)
            guard rename(replacement.path, ownershipMarker.path) == 0 else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        case .runDirectory:
            let displaced = runDirectory.deletingLastPathComponent()
                .appendingPathComponent(
                    ".run-replacement-\(UUID().uuidString)"
                )
            guard rename(runDirectory.path, displaced.path) == 0 else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
            do {
                try recoveryCreatePrivateDirectory(runDirectory)
                for name in ["owner.json", "tmux.conf", "s"] {
                    guard
                        rename(
                            displaced.appendingPathComponent(name).path,
                            runDirectory.appendingPathComponent(name).path
                        ) == 0
                    else {
                        throw FixtureRecoveryMarkerError.invalidRecord
                    }
                }
                guard rmdir(displaced.path) == 0 else {
                    throw FixtureRecoveryMarkerError.invalidRecord
                }
            } catch {
                recoveryRemoveArtifacts(at: displaced)
                throw error
            }
        case .socket:
            let replacement = socketDirectory.appendingPathComponent(
                ".socket-replacement-\(UUID().uuidString)"
            )
            try recoveryCreateSocket(replacement)
            guard rename(replacement.path, socketPath.path) == 0 else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        case .socketDirectory:
            let displaced = runDirectory.appendingPathComponent(
                ".socket-directory-replacement-\(UUID().uuidString)"
            )
            guard rename(socketDirectory.path, displaced.path) == 0 else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
            do {
                try recoveryCreatePrivateDirectory(socketDirectory)
                guard
                    rename(
                        displaced.appendingPathComponent("s").path,
                        socketPath.path
                    ) == 0,
                    rmdir(displaced.path) == 0
                else {
                    throw FixtureRecoveryMarkerError.invalidRecord
                }
            } catch {
                recoveryRemoveArtifacts(at: displaced)
                throw error
            }
        }
    }

    func invalidateSocketDirectory(
        _ invalidity: RecoverySocketDirectoryInvalidity
    ) throws {
        if invalidity == .simultaneousReadyAndClaimed {
            try recoveryCreatePrivateDirectory(
                runDirectory.appendingPathComponent("c")
            )
            return
        }
        guard unlink(socketPath.path) == 0,
            rmdir(socketDirectory.path) == 0
        else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        if invalidity == .regularFile {
            try recoveryWriteExclusiveFile(
                socketDirectory,
                bytes: []
            )
        }
    }

    func prepareSocketDirectory(
        for state: RecoverableSocketDirectoryState
    ) throws {
        guard state != .ready else { return }
        try claimCleanup()
        let claimedDirectory = runDirectory.appendingPathComponent("c")
        if state == .claimedWithEntries {
            try recoveryWriteExclusiveFile(
                socketDirectory.appendingPathComponent("s.lock"),
                bytes: []
            )
        }
        guard rename(socketDirectory.path, claimedDirectory.path) == 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        if state == .claimedEmpty {
            guard
                unlink(
                    claimedDirectory.appendingPathComponent("s").path
                ) == 0
            else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        }
    }

    func prepareJournalState(_ journalState: RecoveryJournalState) throws {
        switch journalState {
        case .innerOnlyReady:
            return
        case .unclaimed:
            try publishSidecar()
        case .claimedReady:
            try claimCleanup()
        case .claimedTombstoneWithEntries:
            try claimCleanup()
            try recoveryWriteExclusiveFile(
                socketDirectory.appendingPathComponent("s.lock"),
                bytes: []
            )
            guard
                rename(
                    socketDirectory.path,
                    runDirectory.appendingPathComponent("c").path
                ) == 0
            else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        case .claimedTombstoneEmpty:
            try claimCleanup()
            let claimedDirectory = runDirectory.appendingPathComponent("c")
            guard rename(socketDirectory.path, claimedDirectory.path) == 0,
                unlink(claimedDirectory.appendingPathComponent("s").path) == 0
            else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        case .claimedNoSocketDirectory:
            try claimCleanup()
            guard unlink(socketPath.path) == 0,
                rmdir(socketDirectory.path) == 0
            else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        case .claimedBothSocketDirectories:
            try claimCleanup()
            try recoveryCreatePrivateDirectory(
                runDirectory.appendingPathComponent("c")
            )
        case .runRemoved:
            try publishSidecar()
            try FileManager.default.removeItem(at: runDirectory)
        case .missingAll:
            try FileManager.default.removeItem(at: runDirectory)
        case .missingMarkers:
            guard unlink(ownershipMarker.path) == 0 else {
                throw FixtureRecoveryMarkerError.invalidRecord
            }
            try recoverySynchronizeDirectory(runDirectory)
        case .differentMarkerInodes:
            try recoveryWriteExclusiveFile(
                sidecar,
                bytes: [UInt8](try Data(contentsOf: ownershipMarker))
            )
            try recoverySynchronizeDirectory(
                runDirectory.deletingLastPathComponent()
            )
        }
    }

    private func publishSidecar() throws {
        guard link(ownershipMarker.path, sidecar.path) == 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        try recoverySynchronizeDirectory(
            runDirectory.deletingLastPathComponent()
        )
    }

    private func claimCleanup() throws {
        try publishSidecar()
        guard unlink(ownershipMarker.path) == 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        try recoverySynchronizeDirectory(runDirectory)
    }

    func snapshot() throws -> [String: RecoveryPathSnapshot] {
        try Dictionary(
            uniqueKeysWithValues: [
                runDirectory,
                socketDirectory,
                configurationFile,
                ownershipMarker,
                socketPath,
            ].map { path in
                (path.path, try recoveryPathSnapshot(path))
            }
        )
    }

    func removeArtifacts() {
        recoveryRemoveArtifacts(at: runDirectory)
        if unlink(sidecar.path) != 0, errno != ENOENT {
            Issue.record("failed to remove recovery sidecar")
        }
    }
}

private func recoveryCreatePrivateDirectory(_ directory: URL) throws {
    guard mkdir(directory.path, 0o700) == 0,
        chmod(directory.path, 0o700) == 0
    else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
}

private func recoverySynchronizeDirectory(_ directory: URL) throws {
    let descriptor = open(
        directory.path,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
}

private func recoveryMarkerLockIsBusy(_ marker: URL) throws -> Bool {
    let descriptor = open(marker.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    defer { _ = close(descriptor) }
    let result = recoveryTestFlock(
        descriptor,
        Int32(LOCK_EX | LOCK_NB)
    )
    if result == 0 {
        _ = recoveryTestFlock(descriptor, Int32(LOCK_UN))
        return false
    }
    guard errno == EAGAIN || errno == EWOULDBLOCK else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    return true
}

private func recoveryTestFlock(
    _ descriptor: Int32,
    _ operation: Int32
) -> Int32 {
    #if canImport(Darwin)
        Darwin.flock(descriptor, operation)
    #else
        linuxRecoveryTestFlock(descriptor, operation)
    #endif
}

#if !canImport(Darwin)
    @_silgen_name("flock")
    private func linuxRecoveryTestFlock(
        _ descriptor: Int32,
        _ operation: Int32
    ) -> Int32
#endif

private func recoveryWriteExclusiveFile(
    _ file: URL,
    bytes: [UInt8]
) throws {
    let descriptor = open(
        file.path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    defer { _ = close(descriptor) }
    guard fchmod(descriptor, 0o600) == 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
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
                throw FixtureRecoveryMarkerError.invalidRecord
            }
        }
    }
    guard fsync(descriptor) == 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
}

private func recoveryCreateSocket(_ path: URL) throws {
    #if canImport(Darwin)
        let socketType = SOCK_STREAM
    #else
        let socketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let descriptor = socket(AF_UNIX, socketType, 0)
    guard descriptor >= 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    defer { _ = close(descriptor) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let pathBytes = Array(path.path.utf8) + [UInt8(0)]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: pathBytes)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard bindResult == 0, chmod(path.path, 0o600) == 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
}

private func recoveryArtifactRecord(
    _ path: URL,
    kind: FixtureRecoveryArtifactKind
) throws -> FixtureRecoveryArtifactRecord {
    var status = stat()
    guard lstat(path.path, &status) == 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    return FixtureRecoveryArtifactRecord(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        kind: kind,
        path: path.path,
        permissions: UInt16(UInt32(status.st_mode) & 0o777)
    )
}

private func recoveryPathSnapshot(_ path: URL) throws -> RecoveryPathSnapshot {
    var status = stat()
    guard lstat(path.path, &status) == 0 else {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
    return RecoveryPathSnapshot(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        mode: UInt32(status.st_mode)
    )
}

private func recoveryRemoveArtifacts(at runDirectory: URL) {
    try? FileManager.default.removeItem(at: runDirectory)
}

private func makeRecoveryConfiguration(
    runDirectory: URL,
    expectedTmuxExecutable: ProcessExecutable? = recoveryTmuxExecutable,
    ownerDescriptorClose: @escaping OwnerLeaseDescriptorClose = ownerLeaseDescriptorClose
) -> FixtureRecoveryConfiguration {
    FixtureRecoveryConfiguration(
        runDirectory: runDirectory,
        expectedTmuxExecutable: expectedTmuxExecutable,
        childEnvironment: recoveryChildEnvironment,
        cleanupDeadline: .seconds(30),
        checkpointInterval: .milliseconds(1),
        ownerDescriptorClose: ownerDescriptorClose
    )
}

private func forcedFailingRecoveryClose(
    _ descriptor: Int32
) -> Result<Void, OwnerLeaseCloseError> {
    guard close(descriptor) == 0 else {
        return .failure(
            .systemCall(operation: "close-owner", code: errno)
        )
    }
    return .failure(forcedRecoveryCloseError)
}

@Suite("Fixture crash recovery")
struct FixtureRecoveryContractTests {
    @Test("recovery preserves a fixture whose owner lock remains live")
    func recoveryPreservesLiveOwnerLock() async throws {
        let scope = try RecoveryLockScope.create()
        let lease = try OwnerLease.acquire(marker: scope.marker, token: UUID())
        let markerBefore = try Data(contentsOf: scope.marker)
        let transport = RecoveryInvocationProbe()
        var leaseClosed = false
        do {
            do {
                _ = try await FixtureRecovery.recover(
                    configuration: makeRecoveryConfiguration(
                        runDirectory: scope.runDirectory
                    ),
                    transport: transport
                )
                Issue.record("live fixture owner lock unexpectedly recovered")
            } catch let error as FixtureRecoveryError {
                #expect(error == .markerBusy)
            } catch {
                Issue.record("unexpected live-owner recovery error: \(error)")
            }

            #expect(try Data(contentsOf: scope.marker) == markerBefore)
            #expect(await transport.invocationCount == 0)
            try await lease.closeResult().get()
            leaseClosed = true
            scope.removeMarkerAndDirectory()
        } catch {
            if !leaseClosed {
                _ = await lease.closeResult()
            }
            scope.removeMarkerAndDirectory()
            throw error
        }
    }

    @Test("recovered owner exposes only observed recovery evidence")
    func recoveredOwnerEvidenceIsTruthful() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        let pins = try FixtureRecoveryDirectoryPins.acquire(
            runDirectory: scope.runDirectory
        )
        defer { pins.release() }
        let claim = try pins.withRunDescriptor { runDescriptor in
            try OwnerLease.claimRecoveryMarker(
                marker: scope.ownershipMarker,
                directoryDescriptor: runDescriptor,
                markerName: "owner.json"
            )
        }
        var leaseClosed = false
        do {
            #expect(claim.lease.checkpoints == nil)
            let recovery = try #require(claim.lease.recoveryCheckpoint)
            #expect(recovery.lock == .bsdExclusiveNonblocking)
            #expect(
                recovery.markerBytes
                    == [UInt8](try Data(contentsOf: scope.ownershipMarker))
            )
            #expect(recovery.bytesRead == recovery.markerBytes.count)
            #expect(recovery.recordWasReadThroughRetainedDescriptor)
            #expect(recovery.descriptorIdentity == recovery.pathIdentity)
            #expect(recovery.pathIdentityWasReadWithFstatat)
            #expect(recovery.closed == nil)
            try await claim.lease.closeResult().get()
            leaseClosed = true
            #expect(claim.lease.checkpoints == nil)
            let closed = try #require(
                claim.lease.recoveryCheckpoint?.closed
            )
            #expect(closed.descriptorCloseAttemptCount == 1)
        } catch {
            if !leaseClosed {
                _ = await claim.lease.closeResult()
            }
            throw error
        }
    }

    @Test("recovery directory pins release once across concurrent callers")
    func recoveryDirectoryPinsReleaseOnce() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        let pins = try FixtureRecoveryDirectoryPins.acquire(
            runDirectory: scope.runDirectory
        )
        try pins.pinSocketDirectory()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    pins.release()
                }
            }
        }
        let sentinelDescriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard sentinelDescriptor >= 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        defer { _ = close(sentinelDescriptor) }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    pins.release()
                }
            }
        }
        #expect(fcntl(sentinelDescriptor, F_GETFD) >= 0)
        do {
            _ = try pins.withRunDescriptor { descriptor in
                fcntl(descriptor, F_GETFD)
            }
            Issue.record("released recovery pins unexpectedly exposed an fd")
        } catch let error as FixtureRecoveryDirectoryPinError {
            #expect(error == .released)
        } catch {
            Issue.record("unexpected released-pin error: \(error)")
        }
    }

    @Test(
        "recovery reports an already absent fixture without executable validation",
        arguments: RecoveryExecutableExpectation.allCases
    )
    func recoveryReportsAlreadyAbsent(
        _ expectation: RecoveryExecutableExpectation
    ) async throws {
        let runDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("f-\(UUID().uuidString)")
        let transport = RecoveryInvocationProbe()

        let result = try await FixtureRecovery.recover(
            configuration: makeRecoveryConfiguration(
                runDirectory: runDirectory,
                expectedTmuxExecutable: expectation.executable
            ),
            transport: transport
        )

        #expect(result == .alreadyAbsent)
        #expect(await transport.invocationCount == 0)
    }

    @Test(
        "run-removed recovery validates authority without executable validation",
        arguments: RecoveryExecutableExpectation.allCases
    )
    func recoveryFinalizesRunRemovedWithoutExecutableValidation(
        _ expectation: RecoveryExecutableExpectation
    ) async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.runRemoved)
        let transport = RecoveryInvocationProbe()

        let result = try await FixtureRecovery.recover(
            configuration: makeRecoveryConfiguration(
                runDirectory: scope.runDirectory,
                expectedTmuxExecutable: expectation.executable
            ),
            transport: transport
        )

        #expect(result == .cleaned)
        #expect(await transport.invocationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: scope.runDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
    }

    @Test("nil expectation uses the absolute executable recorded by the fixture")
    func recoveryUsesRecordedExecutableWithoutExpectation() async throws {
        let recordedPath = "/opt/libtmux-recorded/bin/private-tmux"
        #expect(ProcessExecutable.path(recordedPath) != recoveryTmuxExecutable)
        #expect(
            !recoveryChildEnvironment.path.split(separator: ":").contains {
                recordedPath.hasPrefix("\($0)/")
            }
        )
        let scope = try await RecoveryReadyScope.create(
            recordedTmuxExecutablePath: recordedPath
        )
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.unclaimed)
        let transport = RecoveryScriptedTransport(
            replies: [
                ProcessReply(
                    standardOutput: [],
                    standardError: [],
                    termination: .exited(0)
                ),
                ProcessReply(
                    standardOutput: [],
                    standardError: [],
                    termination: .exited(1)
                ),
            ],
            marker: scope.sidecar
        )

        let result = try await FixtureRecovery.recover(
            configuration: makeRecoveryConfiguration(
                runDirectory: scope.runDirectory,
                expectedTmuxExecutable: nil
            ),
            transport: transport
        )

        #expect(result == .cleaned)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(
            requests.allSatisfy {
                $0.executable == .path(recordedPath)
            }
        )
        #expect(requests.first?.arguments.contains("if-shell") == true)
        #expect(requests.last?.arguments.contains("if-shell") == false)
        #expect(await transport.markerLockWasBusy == [true, true])
    }

    @Test(
        "recovery obeys the durable journal state table",
        arguments: RecoveryJournalState.allCases
    )
    func recoveryObeysDurableJournalState(
        _ journalState: RecoveryJournalState
    ) async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(journalState)
        let noDaemon = ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(1)
        )
        let transport = RecoveryScriptedTransport(
            replies: [noDaemon, noDaemon],
            marker: scope.sidecar
        )

        switch journalState {
        case .innerOnlyReady, .unclaimed:
            let result = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            #expect(result == .cleaned)
            let requests = await transport.requests
            #expect(requests.count == 2)
            #expect(requests.first?.arguments.contains("if-shell") == true)
            #expect(requests.first?.arguments.contains("kill-server") == true)
            #expect(requests.last?.arguments.contains("if-shell") == false)
            #expect(await transport.markerLockWasBusy == [true, true])
            #expect(!FileManager.default.fileExists(atPath: scope.runDirectory.path))
            #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
        case .claimedReady, .claimedTombstoneWithEntries,
            .claimedTombstoneEmpty, .claimedNoSocketDirectory:
            let result = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            #expect(result == .cleaned)
            let requests = await transport.requests
            #expect(requests.count == 1)
            #expect(requests.first?.arguments.contains("if-shell") == false)
            #expect(requests.first?.arguments.contains("kill-server") == false)
            #expect(await transport.markerLockWasBusy == [true])
            #expect(!FileManager.default.fileExists(atPath: scope.runDirectory.path))
            #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
        case .runRemoved:
            let result = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            #expect(result == .cleaned)
            #expect(await transport.requests.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
        case .missingAll:
            let result = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            #expect(result == .alreadyAbsent)
            #expect(await transport.requests.isEmpty)
        case .missingMarkers:
            do {
                _ = try await FixtureRecovery.recover(
                    configuration: makeRecoveryConfiguration(
                        runDirectory: scope.runDirectory
                    ),
                    transport: transport
                )
                Issue.record("markerless run directory unexpectedly recovered")
            } catch let error as FixtureRecoveryError {
                #expect(error == .cleanupStateUnverifiable)
            }
            #expect(await transport.requests.isEmpty)
            #expect(FileManager.default.fileExists(atPath: scope.runDirectory.path))
            #expect(FileManager.default.fileExists(atPath: scope.socketDirectory.path))
            #expect(FileManager.default.fileExists(atPath: scope.configurationFile.path))
        case .differentMarkerInodes, .claimedBothSocketDirectories:
            do {
                _ = try await FixtureRecovery.recover(
                    configuration: makeRecoveryConfiguration(
                        runDirectory: scope.runDirectory
                    ),
                    transport: transport
                )
                Issue.record("invalid journal state unexpectedly recovered")
            } catch let error as FixtureRecoveryError {
                #expect(error == .artifactIdentityChanged)
            }
            #expect(await transport.requests.isEmpty)
            #expect(FileManager.default.fileExists(atPath: scope.runDirectory.path))
            #expect(FileManager.default.fileExists(atPath: scope.sidecar.path))
        }
    }

    @Test("successful recovery guard permits the owned endpoint to disappear")
    func recoveryContinuesAfterGuardRemovesOwnedEndpoint() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.unclaimed)
        let socketPath = scope.socketPath.path
        let transport = RecoveryScriptedTransport(
            replies: [
                ProcessReply(
                    standardOutput: [],
                    standardError: [],
                    termination: .exited(0)
                ),
                ProcessReply(
                    standardOutput: [],
                    standardError: [],
                    termination: .exited(1)
                ),
            ],
            marker: scope.sidecar,
            beforeReply: { requestIndex in
                guard requestIndex == 0 else { return }
                guard unlink(socketPath) == 0 else {
                    throw FixtureRecoveryMarkerError.invalidRecord
                }
            }
        )

        let result = try await FixtureRecovery.recover(
            configuration: makeRecoveryConfiguration(
                runDirectory: scope.runDirectory
            ),
            transport: transport
        )

        #expect(result == .cleaned)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.first?.arguments.contains("if-shell") == true)
        #expect(requests.first?.arguments.contains("kill-server") == true)
        #expect(
            requests.last?.arguments
                == [
                    "-N", "-S", scope.socketPath.path,
                    "display-message", "-p", "#{socket_path}",
                ]
        )
        #expect(!requests.flatMap(\.arguments).contains("start-server"))
        #expect(await transport.markerLockWasBusy == [true, true])
        #expect(!FileManager.default.fileExists(atPath: scope.runDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
    }

    @Test("recovery rejects an endpoint replacement after the successful guard")
    func recoveryRejectsPostGuardEndpointReplacement() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.unclaimed)
        let socketPath = scope.socketPath.path
        let displacedSocket = scope.socketDirectory.appendingPathComponent(
            "owned-socket"
        )
        let ownedIdentity = try recoveryPathSnapshot(scope.socketPath)
        let transport = RecoveryScriptedTransport(
            replies: [
                ProcessReply(
                    standardOutput: [],
                    standardError: [],
                    termination: .exited(0)
                )
            ],
            marker: scope.sidecar,
            beforeReply: { requestIndex in
                guard requestIndex == 0 else { return }
                guard rename(socketPath, displacedSocket.path) == 0 else {
                    throw FixtureRecoveryMarkerError.invalidRecord
                }
                try recoveryCreateSocket(URL(fileURLWithPath: socketPath))
            }
        )

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            Issue.record("post-guard endpoint replacement unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(
                error
                    == .cleanupFailed(
                        .filesystem(
                            operation: "validate-recovery-artifacts",
                            code: ESTALE
                        )
                    )
            )
        }

        let replacementIdentity = try recoveryPathSnapshot(scope.socketPath)
        #expect(replacementIdentity != ownedIdentity)
        #expect(try recoveryPathSnapshot(displacedSocket) == ownedIdentity)
        #expect(await transport.requests.count == 1)
        #expect(await transport.markerLockWasBusy == [true])
        #expect(FileManager.default.fileExists(atPath: scope.runDirectory.path))
        #expect(FileManager.default.fileExists(atPath: scope.sidecar.path))
    }

    @Test("recovery preserves a cleaned result when final owner close fails")
    func recoveryComposesCleanedResultWithCloseFailure() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.runRemoved)
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory,
                    ownerDescriptorClose: forcedFailingRecoveryClose
                ),
                transport: transport
            )
            Issue.record("recovery close failure unexpectedly succeeded")
        } catch let error as FixtureRecoveryError {
            #expect(
                error
                    == .ownerCloseFailed(
                        primary: .result(.cleaned),
                        close: forcedRecoveryCloseError
                    )
            )
        }

        #expect(await transport.invocationCount == 0)
        #expect(!FileManager.default.fileExists(atPath: scope.runDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
    }

    @Test("recovery preserves its primary failure when owner close also fails")
    func recoveryComposesPrimaryFailureWithCloseFailure() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.unclaimed)
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory,
                    expectedTmuxExecutable: .path(
                        "/opt/libtmux-tests/bin/other-tmux"
                    ),
                    ownerDescriptorClose: forcedFailingRecoveryClose
                ),
                transport: transport
            )
            Issue.record("recovery primary and close failures were lost")
        } catch let error as FixtureRecoveryError {
            #expect(
                error
                    == .ownerCloseFailed(
                        primary: .failure(.tmuxExecutableMismatch),
                        close: forcedRecoveryCloseError
                    )
            )
        }

        #expect(await transport.invocationCount == 0)
        #expect(FileManager.default.fileExists(atPath: scope.runDirectory.path))
        #expect(FileManager.default.fileExists(atPath: scope.sidecar.path))
    }

    @Test(
        "recovery preserves every fixture whose recorded artifact was replaced",
        arguments: RecoveryArtifactReplacement.allCases
    )
    func recoveryPreservesReplacedArtifact(
        _ replacement: RecoveryArtifactReplacement
    ) async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.replace(replacement)
        let markerBefore = try Data(contentsOf: scope.ownershipMarker)
        let snapshotBefore = try scope.snapshot()
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            Issue.record("fixture with a replaced artifact unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(error == .artifactIdentityChanged)
        } catch {
            Issue.record("unexpected replacement recovery error: \(error)")
        }

        #expect(try Data(contentsOf: scope.ownershipMarker) == markerBefore)
        #expect(try scope.snapshot() == snapshotBefore)
        #expect(await transport.invocationCount == 0)
    }

    @Test("initial recovery authentication rejects a missing recorded endpoint")
    func recoveryPreservesMissingRecordedEndpoint() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        let markerBefore = try Data(contentsOf: scope.ownershipMarker)
        let runBefore = try recoveryPathSnapshot(scope.runDirectory)
        let configurationBefore = try recoveryPathSnapshot(
            scope.configurationFile
        )
        let markerIdentityBefore = try recoveryPathSnapshot(
            scope.ownershipMarker
        )
        let socketDirectoryBefore = try recoveryPathSnapshot(
            scope.socketDirectory
        )
        guard unlink(scope.socketPath.path) == 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            Issue.record("missing recorded endpoint unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(error == .artifactIdentityChanged)
        } catch {
            Issue.record("unexpected missing-endpoint recovery error: \(error)")
        }

        #expect(try Data(contentsOf: scope.ownershipMarker) == markerBefore)
        #expect(try recoveryPathSnapshot(scope.runDirectory) == runBefore)
        #expect(
            try recoveryPathSnapshot(scope.configurationFile)
                == configurationBefore
        )
        #expect(
            try recoveryPathSnapshot(scope.ownershipMarker)
                == markerIdentityBefore
        )
        #expect(
            try recoveryPathSnapshot(scope.socketDirectory)
                == socketDirectoryBefore
        )
        var status = stat()
        #expect(lstat(scope.socketPath.path, &status) != 0)
        #expect(errno == ENOENT)
        #expect(!FileManager.default.fileExists(atPath: scope.sidecar.path))
        #expect(await transport.invocationCount == 0)
    }

    @Test(
        "recovery preserves missing and wrong-kind socket directories",
        arguments: RecoverySocketDirectoryInvalidity.allCases
    )
    func recoveryPreservesInvalidSocketDirectory(
        _ invalidity: RecoverySocketDirectoryInvalidity
    ) async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.invalidateSocketDirectory(invalidity)
        let markerBefore = try Data(contentsOf: scope.ownershipMarker)
        let runBefore = try recoveryPathSnapshot(scope.runDirectory)
        let configurationBefore = try recoveryPathSnapshot(
            scope.configurationFile
        )
        let markerIdentityBefore = try recoveryPathSnapshot(
            scope.ownershipMarker
        )
        let socketDirectoryBefore = try? recoveryPathSnapshot(
            scope.socketDirectory
        )
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            Issue.record("invalid socket directory unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            switch invalidity {
            case .missing:
                #expect(error == .cleanupStateUnverifiable)
            case .regularFile, .simultaneousReadyAndClaimed:
                #expect(error == .artifactIdentityChanged)
            }
        } catch {
            Issue.record("unexpected socket-directory error: \(error)")
        }

        #expect(try Data(contentsOf: scope.ownershipMarker) == markerBefore)
        #expect(try recoveryPathSnapshot(scope.runDirectory) == runBefore)
        #expect(
            try recoveryPathSnapshot(scope.configurationFile)
                == configurationBefore
        )
        #expect(
            try recoveryPathSnapshot(scope.ownershipMarker)
                == markerIdentityBefore
        )
        switch invalidity {
        case .missing:
            var status = stat()
            #expect(lstat(scope.socketDirectory.path, &status) != 0)
            #expect(errno == ENOENT)
        case .regularFile:
            let expected = try #require(socketDirectoryBefore)
            #expect(
                try recoveryPathSnapshot(scope.socketDirectory)
                    == expected
            )
        case .simultaneousReadyAndClaimed:
            let expected = try #require(socketDirectoryBefore)
            #expect(
                try recoveryPathSnapshot(scope.socketDirectory)
                    == expected
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: scope.runDirectory
                        .appendingPathComponent("c").path
                )
            )
        }
        #expect(await transport.invocationCount == 0)
    }

    @Test("recovery revalidates the nonselected cleanup entry")
    func recoveryRevalidatesNonselectedCleanupEntry() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        let claimedDirectory = scope.runDirectory.appendingPathComponent("c")
        let noDaemon = ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(1)
        )
        let transport = RecoveryScriptedTransport(
            replies: [noDaemon, noDaemon],
            marker: scope.ownershipMarker,
            beforeReply: { requestIndex in
                if requestIndex == 0 {
                    try recoveryCreatePrivateDirectory(claimedDirectory)
                }
            }
        )

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            Issue.record("simultaneous cleanup entries unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(
                error
                    == .cleanupFailed(
                        .filesystem(
                            operation: "validate-recovery-artifacts",
                            code: ESTALE
                        )
                    )
            )
        } catch {
            Issue.record("unexpected cleanup-entry revalidation error: \(error)")
        }

        #expect(await transport.requests.count == 1)
        #expect(await transport.markerLockWasBusy == [true])
        #expect(FileManager.default.fileExists(atPath: scope.socketDirectory.path))
        #expect(FileManager.default.fileExists(atPath: claimedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: scope.socketPath.path))
        #expect(FileManager.default.fileExists(atPath: scope.configurationFile.path))
        #expect(FileManager.default.fileExists(atPath: scope.ownershipMarker.path))
    }

    @Test("recovery preserves a fixture when the executable path differs")
    func recoveryPreservesExecutableMismatch() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareJournalState(.unclaimed)
        let markerBefore = try Data(contentsOf: scope.ownershipMarker)
        let snapshotBefore = try scope.snapshot()
        let transport = RecoveryInvocationProbe()
        let lockObservation = RecoveryCloseLockObservation()
        let sidecar = scope.sidecar

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory,
                    expectedTmuxExecutable: .path(
                        "/opt/libtmux-tests/bin/other-tmux"
                    ),
                    ownerDescriptorClose: { descriptor in
                        lockObservation.record(
                            (try? recoveryMarkerLockIsBusy(sidecar)) == true
                        )
                        return ownerLeaseDescriptorClose(descriptor)
                    }
                ),
                transport: transport
            )
            Issue.record("fixture with an executable mismatch unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(error == .tmuxExecutableMismatch)
        } catch {
            Issue.record("unexpected executable-mismatch error: \(error)")
        }

        #expect(try Data(contentsOf: scope.ownershipMarker) == markerBefore)
        #expect(try scope.snapshot() == snapshotBefore)
        #expect(try recoveryMarkerLockIsBusy(scope.sidecar) == false)
        #expect(lockObservation.markerLockWasBusy == true)
        #expect(await transport.invocationCount == 0)
    }

    @Test("recovery rejects a name-based executable before transport")
    func recoveryRejectsNameExecutable() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        let markerBefore = try Data(contentsOf: scope.ownershipMarker)
        let snapshotBefore = try scope.snapshot()
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory,
                    expectedTmuxExecutable: .name("tmux")
                ),
                transport: transport
            )
            Issue.record("name-based executable unexpectedly recovered a fixture")
        } catch let error as FixtureRecoveryError {
            #expect(error == .invalidTmuxExecutable)
        } catch {
            Issue.record("unexpected name-executable error: \(error)")
        }

        #expect(try Data(contentsOf: scope.ownershipMarker) == markerBefore)
        #expect(try scope.snapshot() == snapshotBefore)
        #expect(await transport.invocationCount == 0)
    }

    @Test(
        "recovery removes every authenticated cleanup namespace state",
        arguments: RecoverableSocketDirectoryState.allCases
    )
    func recoveryRemovesValidatedStaleFixture(
        _ socketDirectoryState: RecoverableSocketDirectoryState
    ) async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.prepareSocketDirectory(for: socketDirectoryState)
        let noDaemon = ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(1)
        )
        let transport = RecoveryScriptedTransport(
            replies: [noDaemon, noDaemon],
            marker: scope.sidecar
        )

        let result = try await FixtureRecovery.recover(
            configuration: makeRecoveryConfiguration(
                runDirectory: scope.runDirectory
            ),
            transport: transport
        )

        #expect(result == .cleaned)
        #expect(
            !FileManager.default.fileExists(
                atPath: scope.runDirectory.path
            )
        )
        let requests = await transport.requests
        let environment = [
            "LC_ALL": "C",
            "PATH": recoveryChildEnvironment.path,
            "TMPDIR": recoveryChildEnvironment.temporaryDirectory,
        ]
        let absenceRequest: ProcessRequest
        switch socketDirectoryState {
        case .ready:
            #expect(await transport.markerLockWasBusy == [true, true])
            #expect(requests.count == 2)
            guard requests.count == 2 else { return }
            let guardRequest = requests[0]
            #expect(guardRequest.executable == recoveryTmuxExecutable)
            #expect(guardRequest.environment == environment)
            #expect(guardRequest.workingDirectory == nil)
            #expect(guardRequest.outputPolicy == .complete)
            #expect(guardRequest.arguments.count == 8)
            if guardRequest.arguments.count == 8 {
                #expect(
                    Array(guardRequest.arguments.prefix(5))
                        == [
                            "-N", "-S", scope.socketPath.path,
                            "if-shell", "-F",
                        ]
                )
                #expect(
                    guardRequest.arguments[5]
                        == "#{==:#{@libtmux_swift_incarnation},\(scope.token.uuidString)}"
                )
                #expect(guardRequest.arguments[6] == "kill-server")
                #expect(
                    guardRequest.arguments[7].hasPrefix(
                        "display-message -p "
                    )
                )
            }
            absenceRequest = requests[1]
        case .claimedEmpty, .claimedWithEntries:
            #expect(await transport.markerLockWasBusy == [true])
            #expect(requests.count == 1)
            guard requests.count == 1 else { return }
            #expect(!requests[0].arguments.contains("if-shell"))
            #expect(!requests[0].arguments.contains("kill-server"))
            absenceRequest = requests[0]
        }
        #expect(absenceRequest.executable == recoveryTmuxExecutable)
        #expect(absenceRequest.environment == environment)
        #expect(absenceRequest.workingDirectory == nil)
        #expect(absenceRequest.outputPolicy == .complete)
        #expect(
            absenceRequest.arguments
                == [
                    "-N", "-S", scope.socketPath.path,
                    "display-message", "-p", "#{socket_path}",
                ]
        )
        #expect(!requests.flatMap(\.arguments).contains("start-server"))
    }

    @Test("recovery rejects a claimed-directory name without its recorded identity")
    func recoveryRejectsNameOnlyClaimedDirectory() async throws {
        let scope = try await RecoveryReadyScope.create()
        defer { scope.removeArtifacts() }
        try scope.replace(.socketDirectory)
        let claimedDirectory = scope.runDirectory.appendingPathComponent("c")
        guard rename(scope.socketDirectory.path, claimedDirectory.path) == 0 else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        let markerBefore = try Data(contentsOf: scope.ownershipMarker)
        let claimedBefore = try recoveryPathSnapshot(claimedDirectory)
        let socketBefore = try recoveryPathSnapshot(
            claimedDirectory.appendingPathComponent("s")
        )
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: scope.runDirectory
                ),
                transport: transport
            )
            Issue.record("name-only claimed directory unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(error == .artifactIdentityChanged)
        } catch {
            Issue.record("unexpected name-only claimed-directory error: \(error)")
        }

        #expect(try Data(contentsOf: scope.ownershipMarker) == markerBefore)
        #expect(try recoveryPathSnapshot(claimedDirectory) == claimedBefore)
        #expect(
            try recoveryPathSnapshot(
                claimedDirectory.appendingPathComponent("s")
            ) == socketBefore
        )
        #expect(await transport.invocationCount == 0)
    }

    @Test("marker decoder accepts exactly two canonical committed records")
    func markerDecoderAcceptsCommittedRecord() throws {
        let marker = try FixtureRecovery.decodeMarker(
            Array((canonicalPreparingRecord + canonicalReadyRecord).utf8)
        )

        #expect(marker.preparing.ownerProcessIdentifier == 123)
        #expect(marker.preparing.token.uuidString == recoveryMarkerToken)
        #expect(marker.preparing.version == 1)
        #expect(marker.ready.state == "ready")
        #expect(marker.ready.token == recoveryMarkerToken)
        #expect(marker.ready.version == 1)
        #expect(marker.ready.tmuxExecutablePath == "/opt/tmux/bin/tmux")
        #expect(marker.ready.runDirectory.path == "/tmp/f-recovery")
        #expect(marker.ready.configurationFile.path == "/tmp/f-recovery/tmux.conf")
        #expect(marker.ready.ownershipMarker.path == "/tmp/f-recovery/owner.json")
        #expect(marker.ready.socketDirectory.path == "/tmp/f-recovery/s")
        #expect(marker.ready.socket.path == "/tmp/f-recovery/s/s")
    }

    @Test(
        "marker decoder rejects every uncommitted record shape",
        arguments: MalformedRecoveryMarker.allCases
    )
    func markerDecoderRejectsUncommittedRecord(
        _ malformed: MalformedRecoveryMarker
    ) throws {
        do {
            _ = try FixtureRecovery.decodeMarker(malformed.bytes)
            Issue.record("uncommitted recovery marker unexpectedly decoded")
        } catch let error as FixtureRecoveryMarkerError {
            #expect(error == .invalidRecord)
        } catch {
            Issue.record("unexpected marker error: \(error)")
        }
    }

    @Test("recovery rejects a nonfixture directory before mutation")
    func rejectsNonfixtureDirectoryBeforeMutation() async throws {
        let runDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ordinary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer {
            if rmdir(runDirectory.path) != 0 {
                Issue.record("failed to remove recovery test directory")
            }
        }
        var before = stat()
        #expect(lstat(runDirectory.path, &before) == 0)
        let transport = RecoveryInvocationProbe()

        do {
            _ = try await FixtureRecovery.recover(
                configuration: makeRecoveryConfiguration(
                    runDirectory: runDirectory
                ),
                transport: transport
            )
            Issue.record("nonfixture directory unexpectedly recovered")
        } catch let error as FixtureRecoveryError {
            #expect(error == .invalidRunDirectory)
        } catch {
            Issue.record("unexpected recovery error: \(error)")
        }

        var after = stat()
        #expect(lstat(runDirectory.path, &after) == 0)
        #expect(UInt64(before.st_dev) == UInt64(after.st_dev))
        #expect(UInt64(before.st_ino) == UInt64(after.st_ino))
        #expect(await transport.invocationCount == 0)
    }
}
