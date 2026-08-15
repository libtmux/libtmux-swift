import Foundation
import Testing

@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private let helperProtocolVersion = 2
private let helperOutputLimit = 16 * 1024
private let helperReadinessDeadline = Duration.seconds(30)
private let helperEnvironment = ["LC_ALL": "C"]
private let closeSentinelRecord = Array("libtmux-owner-close-sentinel-v1\n".utf8)
private let directoryFileType: UInt32 = 0o040000
private let regularFileType: UInt32 = 0o100000
private let fileTypeMask: UInt32 = 0o170000

private enum OwnerHelperMode: String, Decodable, Sendable, Equatable {
    case block
    case closeConcurrent = "close-concurrent"
    case closeSequential = "close-sequential"
    case execCheck = "exec-check"
    case probe
}

private enum OwnerHelperProbeOutcome: String, Decodable, Sendable, Equatable {
    case acquired
    case busy
}

private enum OwnerHelperExecOutcome: String, Decodable, Sendable, Equatable {
    case descriptorAbsent = "descriptor-absent"
}

private enum OwnerHelperLockKind: String, Decodable, Sendable, Equatable {
    case bsdExclusiveNonblocking = "flock-exclusive-nonblocking"
}

private enum OwnerHelperReadinessPublication: String, Decodable, Sendable, Equatable {
    case atomicNoReplace = "atomic-no-replace"
}

private enum OwnerHelperCloseOutcome: String, Decodable, Sendable, Equatable {
    case sentinelAuthenticated = "sentinel-authenticated"
}

enum InvalidReadyRecord: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case duplicate
    case noncanonical
    case partial
    case unterminated

    var testDescription: String { rawValue }

    var bytes: [UInt8] {
        switch self {
        case .duplicate:
            Array("{\"state\":\"ready\",\"version\":1}\n{\"state\":\"ready\",\"version\":1}\n".utf8)
        case .noncanonical:
            Array("{\"version\":1,\"state\":\"ready\"}\n".utf8)
        case .partial:
            Array("{\"state\":\"ready\"\n".utf8)
        case .unterminated:
            Array("{\"state\":\"ready\",\"version\":1}".utf8)
        }
    }
}

private struct OwnerHelperRecord: Decodable, Sendable, Equatable {
    let ownerProcessIdentifier: Int32
    let token: String
    let version: Int
}

private struct OwnerHelperIdentity: Decodable, Sendable, Equatable {
    let device: UInt64
    let fileType: String
    let inode: UInt64
    let permissions: UInt16
    let size: Int64
}

private struct OwnerHelperProbeReply: Decodable, Sendable {
    let identity: OwnerHelperIdentity
    let lockKind: OwnerHelperLockKind
    let mode: OwnerHelperMode
    let outcome: OwnerHelperProbeOutcome
    let protocolVersion: Int
    let record: OwnerHelperRecord
}

private struct OwnerHelperExecReply: Decodable, Sendable {
    let identity: OwnerHelperIdentity
    let matchingDescriptorCount: Int
    let mode: OwnerHelperMode
    let outcome: OwnerHelperExecOutcome
    let protocolVersion: Int
}

private struct OwnerHelperReadiness: Decodable, Sendable, Equatable {
    let leaderProcessIdentifier: Int32
    let mode: OwnerHelperMode
    let processGroupIdentifier: Int32
    let protocolVersion: Int
    let publication: OwnerHelperReadinessPublication
}

private struct OwnerHelperCloseReply: Decodable, Sendable {
    let cachedCloseResultCount: Int
    let closeResultCallerCount: Int
    let coalescedCloseResultCount: Int
    let descriptorCloseCallCount: Int
    let markerDescriptorCountAfterClose: Int
    let markerDescriptorCountBeforeClose: Int
    let mode: OwnerHelperMode
    let outcome: OwnerHelperCloseOutcome
    let protocolVersion: Int
    let sentinelBytesAfterRetries: [UInt8]
    let sentinelBytesBeforeRetries: [UInt8]
    let sentinelIdentityAfterRetries: OwnerHelperIdentity
    let sentinelIdentityBeforeRetries: OwnerHelperIdentity
    let sentinelIdentityWasReadWithFstatAfterRetries: Bool
    let sentinelRecordWasReadFromRetiredDescriptorAfterRetries: Bool
    let sentinelWasDuplicatedOntoRetiredDescriptorWithDup2: Bool
}

private enum BlockingHelperDeadlineError: Error, Sendable, Equatable {
    case exceeded(deadline: Duration, readiness: OwnerHelperReadiness)
}

private enum OwnerLeaseContractError: Error, Sendable, Equatable {
    case artifactDescriptorStillOpen(name: String, descriptors: [Int32])
    case directoryCreationFailed(code: Int32)
    case directoryEntryStatFailed(name: String, code: Int32)
    case directoryInventoryFailed
    case directoryOpenFailed(code: Int32)
    case directoryRemovalFailed(code: Int32)
    case directoryStreamCloseFailed(code: Int32)
    case descriptorLimitUnavailable(code: Int32)
    case helperDeadlineExceeded
    case helperExitedBeforeDeadline
    case helperUnavailable
    case invalidHelperReply
    case invalidReadinessFile
    case markerRemovalFailed(code: Int32)
    case markerStatFailed(code: Int32)
    case readinessDeadlineExceeded
    case unexpectedDirectory(String)
    case unexpectedScopeType
    case unexpectedOwnerLeaseError
    case unexpectedOwnerLeaseSuccess
}

private struct MarkerStat: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let size: Int64

    var fileType: UInt32 { mode & fileTypeMask }
    var permissions: UInt16 { UInt16(mode & 0o777) }
}

private struct OwnerLeaseTestScope: Sendable {
    let directory: URL
    let marker: URL

    static func create() throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-owner-lease-\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(directory.path, 0o700) == 0 else {
            throw OwnerLeaseContractError.directoryCreationFailed(code: errno)
        }
        return Self(
            directory: directory,
            marker: directory.appendingPathComponent("owner.json", isDirectory: false)
        )
    }

    func removeAllArtifacts() throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        if descriptor < 0 {
            if errno == ENOENT { return }
            if errno == ELOOP || errno == ENOTDIR {
                throw OwnerLeaseContractError.unexpectedScopeType
            }
            throw OwnerLeaseContractError.directoryOpenFailed(code: errno)
        }
        guard let stream = fdopendir(descriptor) else {
            let openCode = errno
            _ = close(descriptor)
            throw OwnerLeaseContractError.directoryOpenFailed(code: openCode)
        }

        let removalError: (any Error)?
        do {
            while true {
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 {
                        throw OwnerLeaseContractError.directoryInventoryFailed
                    }
                    break
                }
                let name = directoryEntryName(entry)
                if name == "." || name == ".." { continue }

                var childStatus = stat()
                let statResult = name.withCString {
                    fstatat(descriptor, $0, &childStatus, AT_SYMLINK_NOFOLLOW)
                }
                if statResult != 0 {
                    if errno == ENOENT { continue }
                    throw OwnerLeaseContractError.directoryEntryStatFailed(
                        name: name,
                        code: errno
                    )
                }
                guard UInt32(childStatus.st_mode) & fileTypeMask != directoryFileType else {
                    throw OwnerLeaseContractError.unexpectedDirectory(name)
                }
                let childIdentity = MarkerStat(
                    device: UInt64(childStatus.st_dev),
                    inode: UInt64(childStatus.st_ino),
                    mode: UInt32(childStatus.st_mode),
                    size: Int64(childStatus.st_size)
                )
                let retainedDescriptors = try matchingMarkerDescriptors(
                    markerStatus: childIdentity
                )
                guard retainedDescriptors.isEmpty else {
                    throw OwnerLeaseContractError.artifactDescriptorStillOpen(
                        name: name,
                        descriptors: retainedDescriptors
                    )
                }
                let unlinkResult = name.withCString { unlinkat(descriptor, $0, 0) }
                if unlinkResult != 0, errno != ENOENT {
                    throw OwnerLeaseContractError.markerRemovalFailed(code: errno)
                }
            }
            removalError = nil
        } catch {
            removalError = error
        }

        let closeResult = closedir(stream)
        let closeCode = errno
        if let removalError {
            if closeResult != 0 {
                Issue.record("scope directory close also failed: \(closeCode)")
            }
            throw removalError
        }
        guard closeResult == 0 else {
            throw OwnerLeaseContractError.directoryStreamCloseFailed(code: closeCode)
        }
        if rmdir(directory.path) != 0, errno != ENOENT {
            throw OwnerLeaseContractError.directoryRemovalFailed(code: errno)
        }
    }

    func artifactNames() throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw OwnerLeaseContractError.directoryInventoryFailed
        }
    }
}

private func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
    withUnsafePointer(to: entry.pointee.d_name) { name in
        name.withMemoryRebound(
            to: CChar.self,
            capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
        ) {
            String(cString: $0)
        }
    }
}

private func markerStat(at marker: URL) throws -> MarkerStat {
    var status = stat()
    guard lstat(marker.path, &status) == 0 else {
        throw OwnerLeaseContractError.markerStatFailed(code: errno)
    }
    return MarkerStat(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        mode: UInt32(status.st_mode),
        size: Int64(status.st_size)
    )
}

private func markerIsAbsent(at marker: URL) -> Bool {
    var status = stat()
    if lstat(marker.path, &status) == 0 { return false }
    return errno == ENOENT
}

private func authenticatedExecutable(at candidate: URL) -> String? {
    let path = candidate.path
    guard path.hasPrefix("/"),
        candidate.lastPathComponent == "fixture-owner-helper",
        candidate.standardizedFileURL.path == path,
        access(path, X_OK) == 0
    else {
        return nil
    }
    var status = stat()
    guard lstat(path, &status) == 0,
        UInt32(status.st_mode) & fileTypeMask == regularFileType,
        status.st_uid == geteuid(),
        UInt32(status.st_mode) & 0o022 == 0
    else {
        return nil
    }
    return path
}

private func fixtureOwnerHelperPath() throws -> String {
    guard
        let explicit = ProcessInfo.processInfo.environment[
            "LIBTMUX_FIXTURE_OWNER_HELPER"
        ],
        let path = authenticatedExecutable(
            at: URL(fileURLWithPath: explicit, isDirectory: false)
        )
    else {
        throw OwnerLeaseContractError.helperUnavailable
    }
    return path
}

private func ownerHelperRequest(arguments: [String]) throws -> ProcessRequest {
    try ProcessRequest(
        executable: .path(fixtureOwnerHelperPath()),
        arguments: arguments,
        environment: helperEnvironment,
        workingDirectory: nil,
        outputPolicy: .limited(maxBytesPerStream: helperOutputLimit)
    )
}

private enum OwnerHelperDeadlineEvent<Value: Sendable>: Sendable {
    case deadline
    case value(Value)
}

private func withOwnerHelperDeadline<Value: Sendable>(
    timeout: Duration = .seconds(30),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: OwnerHelperDeadlineEvent<Value>.self) { group in
        group.addTask { .value(try await operation()) }
        let deadlineGate = AsyncGate()
        group.addTask {
            do {
                try await deadlineGate.wait(timeout: timeout)
                throw OwnerLeaseContractError.helperExitedBeforeDeadline
            } catch AsyncGateError.timedOut {
                return .deadline
            }
        }
        defer { group.cancelAll() }
        guard let event = try await group.next() else {
            throw OwnerLeaseContractError.helperExitedBeforeDeadline
        }
        switch event {
        case .deadline:
            throw OwnerLeaseContractError.helperDeadlineExceeded
        case let .value(value):
            return value
        }
    }
}

private func decodeSingleLineReply<Reply: Decodable>(
    _ bytes: [UInt8],
    as replyType: Reply.Type = Reply.self
) throws -> Reply {
    guard bytes.last == 0x0A, !bytes.dropLast().contains(0x0A) else {
        throw OwnerLeaseContractError.invalidHelperReply
    }
    do {
        return try JSONDecoder().decode(replyType, from: Data(bytes.dropLast()))
    } catch {
        throw OwnerLeaseContractError.invalidHelperReply
    }
}

private func runOwnerHelper<Reply: Decodable & Sendable>(
    mode: OwnerHelperMode,
    marker: URL,
    as replyType: Reply.Type = Reply.self
) async throws -> Reply {
    let request = try ownerHelperRequest(
        arguments: [mode.rawValue, "--marker", marker.path]
    )
    let reply = try await withOwnerHelperDeadline {
        try await DirectSpawnTransport().run(request)
    }
    guard reply.termination == .exited(0), reply.standardError.isEmpty else {
        throw OwnerLeaseContractError.helperExitedBeforeDeadline
    }
    return try decodeSingleLineReply(reply.standardOutput, as: replyType)
}

private func waitForAtomicReadiness(
    at readinessFile: URL,
    timeout: Duration
) async throws -> OwnerHelperReadiness {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        try Task.checkCancellation()
        var status = stat()
        if lstat(readinessFile.path, &status) == 0 {
            guard UInt32(status.st_mode) & fileTypeMask == regularFileType,
                UInt16(UInt32(status.st_mode) & 0o777) == 0o600,
                status.st_size > 0,
                status.st_size <= Int64(helperOutputLimit)
            else {
                throw OwnerLeaseContractError.invalidReadinessFile
            }
            let bytes: [UInt8]
            do {
                bytes = Array(try Data(contentsOf: readinessFile))
            } catch {
                throw OwnerLeaseContractError.invalidReadinessFile
            }
            return try decodeSingleLineReply(bytes)
        }
        guard errno == ENOENT else {
            throw OwnerLeaseContractError.markerStatFailed(code: errno)
        }
        await Task.yield()
    }
    throw OwnerLeaseContractError.readinessDeadlineExceeded
}

private enum BlockingHelperEvent: Sendable {
    case deadline
    case helper(ProcessReply)
    case readiness(OwnerHelperReadiness)
}

private func runBlockingOwnerHelper(
    readinessFile: URL,
    deadline: Duration
) async throws {
    let request = try ownerHelperRequest(
        arguments: ["block", "--ready", readinessFile.path]
    )
    try await withThrowingTaskGroup(of: BlockingHelperEvent.self) { group in
        group.addTask {
            .helper(try await DirectSpawnTransport().run(request))
        }
        group.addTask {
            .readiness(
                try await waitForAtomicReadiness(
                    at: readinessFile,
                    timeout: helperReadinessDeadline
                )
            )
        }
        defer { group.cancelAll() }

        var readiness: OwnerHelperReadiness?
        while let event = try await group.next() {
            switch event {
            case .deadline:
                guard let readiness else {
                    throw OwnerLeaseContractError.invalidReadinessFile
                }
                throw BlockingHelperDeadlineError.exceeded(
                    deadline: deadline,
                    readiness: readiness
                )
            case .helper:
                throw OwnerLeaseContractError.helperExitedBeforeDeadline
            case let .readiness(value):
                guard readiness == nil else {
                    throw OwnerLeaseContractError.invalidReadinessFile
                }
                readiness = value
                let deadlineGate = AsyncGate()
                group.addTask {
                    do {
                        try await deadlineGate.wait(timeout: deadline)
                        throw OwnerLeaseContractError.helperExitedBeforeDeadline
                    } catch AsyncGateError.timedOut {
                        return .deadline
                    }
                }
            }
        }
        throw OwnerLeaseContractError.helperExitedBeforeDeadline
    }
}

private func processIsAbsent(_ processIdentifier: Int32) -> Bool {
    errno = 0
    return kill(processIdentifier, 0) == -1 && errno == ESRCH
}

private func processGroupIsAbsent(_ processGroupIdentifier: Int32) -> Bool {
    errno = 0
    return kill(-processGroupIdentifier, 0) == -1 && errno == ESRCH
}

private func descriptorScanUpperBound() throws -> Int32 {
    errno = 0
    let openMaximum = sysconf(Int32(_SC_OPEN_MAX))
    let code = errno
    guard openMaximum > 0, openMaximum <= Int(Int32.max) else {
        throw OwnerLeaseContractError.descriptorLimitUnavailable(code: code)
    }
    return Int32(openMaximum)
}

private func matchingMarkerDescriptors(
    markerStatus: MarkerStat
) throws -> [Int32] {
    var matches: [Int32] = []
    let upperBound = try descriptorScanUpperBound()
    for descriptor in 0..<upperBound {
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0 else { continue }
        if UInt64(descriptorStatus.st_dev) == markerStatus.device,
            UInt64(descriptorStatus.st_ino) == markerStatus.inode
        {
            matches.append(descriptor)
        }
    }
    return matches
}

private func retainedIdentityMarkerStat(_ lease: OwnerLease) -> MarkerStat {
    let identity = lease.identity
    return MarkerStat(
        device: identity.device,
        inode: identity.inode,
        mode: regularFileType | UInt32(identity.permissions),
        size: identity.size
    )
}

private func authenticateDescriptorCount(
    markerStatus: MarkerStat,
    expected: Int
) -> Bool {
    do {
        let remaining = try matchingMarkerDescriptors(markerStatus: markerStatus)
        guard remaining.count == expected else {
            Issue.record("owner lease close left an unexpected marker descriptor count")
            return false
        }
    } catch {
        Issue.record("owner lease descriptor scan failed after close: \(error)")
        return false
    }
    return true
}

private func closeLease(_ lease: OwnerLease) async throws {
    let result = await lease.closeResult()
    try result.get()
}

private func closeAndAuthenticate(
    _ lease: OwnerLease,
    markerStatus: MarkerStat,
    remainingMarkerDescriptorCount: Int
) async -> Bool {
    do {
        try await closeLease(lease)
    } catch {
        Issue.record("owner lease close could not be authenticated: \(error)")
        return false
    }
    guard let closed = lease.checkpoints?.closed else {
        Issue.record("owner lease omitted its close checkpoint")
        return false
    }
    guard closed.descriptorCloseAttemptCount == 1 else {
        Issue.record("owner lease close checkpoint reported multiple descriptor closes")
        return false
    }
    return authenticateDescriptorCount(
        markerStatus: markerStatus,
        expected: remainingMarkerDescriptorCount
    )
}

private func expectCloseReply(
    _ reply: OwnerHelperCloseReply,
    mode: OwnerHelperMode,
    closeResultCallerCount: Int,
    cachedCloseResultCount: Int,
    coalescedCloseResultCount: Int
) {
    #expect(reply.protocolVersion == helperProtocolVersion)
    #expect(reply.mode == mode)
    #expect(reply.outcome == .sentinelAuthenticated)
    #expect(reply.closeResultCallerCount == closeResultCallerCount)
    #expect(reply.cachedCloseResultCount == cachedCloseResultCount)
    #expect(reply.coalescedCloseResultCount == coalescedCloseResultCount)
    #expect(reply.descriptorCloseCallCount == 1)
    #expect(reply.markerDescriptorCountBeforeClose == 1)
    #expect(reply.markerDescriptorCountAfterClose == 0)
    #expect(reply.sentinelWasDuplicatedOntoRetiredDescriptorWithDup2)
    #expect(reply.sentinelIdentityWasReadWithFstatAfterRetries)
    #expect(reply.sentinelRecordWasReadFromRetiredDescriptorAfterRetries)
    #expect(reply.sentinelIdentityAfterRetries == reply.sentinelIdentityBeforeRetries)
    #expect(reply.sentinelIdentityAfterRetries.fileType == "regular")
    #expect(reply.sentinelIdentityAfterRetries.permissions == 0o600)
    #expect(reply.sentinelIdentityAfterRetries.size == Int64(closeSentinelRecord.count))
    #expect(reply.sentinelBytesBeforeRetries == closeSentinelRecord)
    #expect(reply.sentinelBytesAfterRetries == closeSentinelRecord)
}

private func expectHelperIdentity(
    _ helperIdentity: OwnerHelperIdentity,
    equals markerStatus: MarkerStat
) {
    #expect(helperIdentity.device == markerStatus.device)
    #expect(helperIdentity.inode == markerStatus.inode)
    #expect(helperIdentity.fileType == "regular")
    #expect(helperIdentity.permissions == markerStatus.permissions)
    #expect(helperIdentity.size == markerStatus.size)
}

private func expectProbeReply(
    _ reply: OwnerHelperProbeReply,
    outcome: OwnerHelperProbeOutcome,
    token: UUID,
    ownerProcessIdentifier: Int32,
    markerStatus: MarkerStat
) {
    #expect(reply.protocolVersion == helperProtocolVersion)
    #expect(reply.mode == .probe)
    #expect(reply.lockKind == .bsdExclusiveNonblocking)
    #expect(reply.outcome == outcome)
    #expect(reply.record.version == 1)
    #expect(reply.record.token == token.uuidString)
    #expect(reply.record.ownerProcessIdentifier == ownerProcessIdentifier)
    expectHelperIdentity(reply.identity, equals: markerStatus)
}

private func acquireOwnerLease(
    scope: OwnerLeaseTestScope,
    token: UUID
) throws -> OwnerLease {
    do {
        return try OwnerLease.acquire(marker: scope.marker, token: token)
    } catch {
        do {
            try scope.removeAllArtifacts()
        } catch {
            Issue.record("owner lease acquisition cleanup also failed: \(error)")
        }
        throw error
    }
}

private func cleanupAfterFailure(
    lease: OwnerLease,
    scope: OwnerLeaseTestScope,
    alreadyClosed: Bool
) async {
    guard let markerStatus = try? markerStat(at: scope.marker) else {
        if !alreadyClosed {
            await closeWithoutAuthentication(lease)
        }
        recordPreservedOwnerArtifacts(in: scope)
        return
    }
    guard
        await closeAndAuthenticate(
            lease,
            markerStatus: markerStatus,
            remainingMarkerDescriptorCount: 0
        )
    else {
        recordPreservedOwnerArtifacts(in: scope)
        return
    }
    do {
        try scope.removeAllArtifacts()
    } catch {
        Issue.record("owner lease test artifact cleanup failed: \(error)")
    }
}

private func cleanupScopeAfterFailure(_ scope: OwnerLeaseTestScope) {
    do {
        try scope.removeAllArtifacts()
    } catch {
        Issue.record("owner lease test artifact cleanup failed: \(error)")
    }
}

private func recordPreservedOwnerArtifacts(in scope: OwnerLeaseTestScope) {
    let scopeName = scope.directory.lastPathComponent
    let markerName = scope.marker.lastPathComponent
    Issue.record(
        "preserved unauthenticated owner artifacts at \(scopeName)/\(markerName)"
    )
}

private func closeWithoutAuthentication(_ lease: OwnerLease) async {
    do {
        try await closeLease(lease)
    } catch {
        Issue.record("unauthenticated owner lease close also failed: \(error)")
    }
}

private func acceptsSendable<Value: Sendable>(_ value: Value) {
    _ = value
}

@Suite("BSD owner lease contract", .timeLimit(.minutes(1)))
struct OwnerLeaseContractTests {
    @Test("scope cleanup preserves an artifact with a live task descriptor")
    func scopeCleanupPreservesLiveDescriptor() throws {
        let scope = try OwnerLeaseTestScope.create()
        let artifact = scope.directory.appendingPathComponent(
            "retained-artifact",
            isDirectory: false
        )
        let descriptor = open(
            artifact.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            cleanupScopeAfterFailure(scope)
            throw OwnerLeaseContractError.directoryOpenFailed(code: errno)
        }
        var descriptorNeedsClose = true
        var cleanupAuthorized = false
        do {
            let before = try markerStat(at: artifact)
            let observedError: OwnerLeaseContractError?
            do {
                try scope.removeAllArtifacts()
                observedError = nil
            } catch let error as OwnerLeaseContractError {
                observedError = error
            }
            guard let observedError else {
                throw OwnerLeaseContractError.unexpectedOwnerLeaseSuccess
            }
            #expect(
                observedError
                    == .artifactDescriptorStillOpen(
                        name: artifact.lastPathComponent,
                        descriptors: [descriptor]
                    )
            )
            #expect(try markerStat(at: artifact) == before)
            var rootStatus = stat()
            #expect(lstat(scope.directory.path, &rootStatus) == 0)
            #expect(UInt32(rootStatus.st_mode) & fileTypeMask == directoryFileType)

            let closeResult = close(descriptor)
            let closeCode = errno
            descriptorNeedsClose = false
            guard closeResult == 0 else {
                recordPreservedOwnerArtifacts(in: scope)
                throw OwnerLeaseContractError.directoryStreamCloseFailed(code: closeCode)
            }
            cleanupAuthorized = true
            try scope.removeAllArtifacts()
            #expect(markerIsAbsent(at: artifact))
            #expect(markerIsAbsent(at: scope.directory))
        } catch {
            if descriptorNeedsClose {
                descriptorNeedsClose = false
                if close(descriptor) == 0 {
                    cleanupAuthorized = true
                } else {
                    recordPreservedOwnerArtifacts(in: scope)
                }
            }
            if cleanupAuthorized {
                cleanupScopeAfterFailure(scope)
            }
            throw error
        }
    }

    @Test("publication prepares the locked descriptor before marker visibility")
    func publicationPreparesLockedDescriptorBeforeMarkerVisibility() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let token = UUID(uuidString: "7A67F268-C6CB-42C5-863B-C9CF9E80DF9A")!
        let ownerProcessIdentifier = getpid()
        let lease = try acquireOwnerLease(scope: scope, token: token)
        var closed = false
        do {
            acceptsSendable(lease)
            acceptsSendable(lease.record)
            acceptsSendable(lease.identity)
            acceptsSendable(lease.checkpoints)

            #expect(lease.marker == scope.marker)
            #expect(lease.record.version == 1)
            #expect(lease.record.token == token)
            #expect(lease.record.ownerProcessIdentifier == ownerProcessIdentifier)

            let prepared = try #require(lease.checkpoints).prepared
            let expectedOpenFlags = Int32(
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
            )
            let expectedRecord = Array(
                ("{\"ownerProcessIdentifier\":\(ownerProcessIdentifier),"
                    + "\"token\":\"\(token.uuidString)\",\"version\":1}\n").utf8
            )
            #expect(prepared.markerIdentityBeforePublication == nil)
            #expect(prepared.openFlags == expectedOpenFlags)
            #expect(prepared.descriptorFlags & FD_CLOEXEC == FD_CLOEXEC)
            #expect(prepared.lock == .bsdExclusiveNonblocking)
            #expect(prepared.permissionsWereSetWithFchmod)
            #expect(prepared.descriptorIdentityWasReadWithFstat)
            #expect(prepared.descriptorIdentity.fileType == .regular)
            #expect(prepared.descriptorIdentity.permissions == 0o600)
            #expect(prepared.recordBytes == expectedRecord)
            #expect(prepared.bytesWritten == expectedRecord.count)
            #expect(prepared.descriptorIdentity.size == Int64(expectedRecord.count))
            #expect(prepared.recordWasWrittenThroughRetainedDescriptor)
            #expect(prepared.wasTruncated)
            #expect(prepared.wasSynchronized)

            let published = try #require(lease.checkpoints).published
            #expect(published.method == .linkatThenUnlink)
            #expect(published.stagingPathWasRemoved)
            #expect(published.descriptorIdentity == prepared.descriptorIdentity)
            #expect(published.pathIdentity == prepared.descriptorIdentity)
            #expect(published.pathIdentityWasReadWithLstat)
            #expect(lease.identity == published.pathIdentity)
            switch published.directorySynchronization {
            case .synchronized, .unsupported:
                break
            }

            let publicStatus = try markerStat(at: scope.marker)
            #expect(publicStatus.fileType == regularFileType)
            #expect(publicStatus.permissions == 0o600)
            #expect(publicStatus.device == lease.identity.device)
            #expect(publicStatus.inode == lease.identity.inode)
            #expect(publicStatus.size == lease.identity.size)
            #expect(try matchingMarkerDescriptors(markerStatus: publicStatus).count == 1)

            try await closeLease(lease)
            closed = true
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test("ready publication appends one fsynced canonical record")
    func readyPublicationAppendsOneFsyncedCanonicalRecord() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let lease = try acquireOwnerLease(scope: scope, token: UUID())
        var closed = false
        do {
            let preparingBytes = try #require(lease.checkpoints).prepared.recordBytes
            let readyBytes = Array(
                "{\"state\":\"ready\",\"version\":1}\n".utf8
            )

            let ready = try await lease.publishReadyRecord(readyBytes)

            #expect(ready.recordBytes == readyBytes)
            #expect(ready.bytesWritten == readyBytes.count)
            #expect(ready.writeOffset == Int64(preparingBytes.count))
            #expect(ready.recordWasWrittenThroughRetainedDescriptor)
            #expect(ready.wasSynchronized)
            #expect(ready.descriptorIdentity == ready.pathIdentity)
            #expect(ready.pathIdentityWasReadWithLstat)
            #expect(
                ready.descriptorIdentity.size
                    == Int64(preparingBytes.count + readyBytes.count)
            )
            #expect(lease.checkpoints?.ready == ready)
            #expect(
                try Data(contentsOf: scope.marker)
                    == Data(preparingBytes + readyBytes)
            )

            try await closeLease(lease)
            closed = true
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test(
        "ready publication rejects a malformed record before writing",
        arguments: InvalidReadyRecord.allCases
    )
    func readyPublicationRejectsMalformedRecord(
        _ invalidRecord: InvalidReadyRecord
    ) async throws {
        let scope = try OwnerLeaseTestScope.create()
        let lease = try acquireOwnerLease(scope: scope, token: UUID())
        var closed = false
        do {
            let preparingBytes = try #require(lease.checkpoints).prepared.recordBytes

            do {
                _ = try await lease.publishReadyRecord(invalidRecord.bytes)
                Issue.record("invalid ready record unexpectedly published")
            } catch let error as OwnerLeaseReadyPublicationError {
                #expect(error == .invalidRecord)
            } catch {
                Issue.record("unexpected ready publication error: \(error)")
            }

            #expect(lease.checkpoints?.ready == nil)
            #expect(try Data(contentsOf: scope.marker) == Data(preparingBytes))

            try await closeLease(lease)
            closed = true
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test("ready publication rejects a duplicate append without mutation")
    func readyPublicationRejectsDuplicateAppend() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let lease = try acquireOwnerLease(scope: scope, token: UUID())
        var closed = false
        do {
            let readyBytes = Array(
                "{\"state\":\"ready\",\"version\":1}\n".utf8
            )
            _ = try await lease.publishReadyRecord(readyBytes)
            let publishedBytes = try Data(contentsOf: scope.marker)

            do {
                _ = try await lease.publishReadyRecord(readyBytes)
                Issue.record("duplicate ready record unexpectedly published")
            } catch let error as OwnerLeaseReadyPublicationError {
                #expect(error == .readyAlreadyPublished)
            } catch {
                Issue.record("unexpected ready publication error: \(error)")
            }

            #expect(try Data(contentsOf: scope.marker) == publishedBytes)

            try await closeLease(lease)
            closed = true
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test("ready publication serializes with descriptor close")
    func readyPublicationSerializesWithDescriptorClose() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let synchronizationReached = AsyncGate()
        let releaseSynchronization = AsyncGate()
        let lease = try OwnerLease.acquire(
            marker: scope.marker,
            token: UUID(),
            beforeReadySynchronization: {
                await synchronizationReached.open()
                try? await releaseSynchronization.wait(timeout: .seconds(30))
            }
        )
        let readyBytes = Array(
            "{\"state\":\"ready\",\"version\":1}\n".utf8
        )
        let publication = Task {
            try await lease.publishReadyRecord(readyBytes)
        }
        var closeCompleted = false
        do {
            try await synchronizationReached.wait(timeout: .seconds(30))
            let closing = Task { await lease.closeResult() }
            await Task.yield()

            let liveStatus = try markerStat(at: scope.marker)
            #expect(lease.checkpoints?.closed == nil)
            #expect(
                try matchingMarkerDescriptors(markerStatus: liveStatus).count == 1
            )

            await releaseSynchronization.open()
            let ready = try await publication.value
            try await closing.value.get()
            closeCompleted = true

            #expect(ready.wasSynchronized)
            #expect(lease.checkpoints?.ready == ready)
            #expect(
                try matchingMarkerDescriptors(markerStatus: liveStatus).isEmpty
            )
            try scope.removeAllArtifacts()
        } catch {
            await releaseSynchronization.open()
            _ = try? await publication.value
            await cleanupAfterFailure(
                lease: lease,
                scope: scope,
                alreadyClosed: closeCompleted
            )
            throw error
        }
    }

    @Test("an external nonblocking flock probe reports busy then acquired")
    func externalProbeReportsBSDLockAvailability() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let token = UUID(uuidString: "E9FE035C-360B-4B02-8C55-F7DD7C892D5C")!
        let ownerProcessIdentifier = getpid()
        let lease = try acquireOwnerLease(scope: scope, token: token)
        var closed = false
        do {
            let liveStatus = try markerStat(at: scope.marker)
            let busy: OwnerHelperProbeReply = try await runOwnerHelper(
                mode: .probe,
                marker: scope.marker
            )
            expectProbeReply(
                busy,
                outcome: .busy,
                token: token,
                ownerProcessIdentifier: ownerProcessIdentifier,
                markerStatus: liveStatus
            )

            try await closeLease(lease)
            closed = true

            let acquired: OwnerHelperProbeReply = try await runOwnerHelper(
                mode: .probe,
                marker: scope.marker
            )
            expectProbeReply(
                acquired,
                outcome: .acquired,
                token: token,
                ownerProcessIdentifier: ownerProcessIdentifier,
                markerStatus: liveStatus
            )
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test("opening and closing the marker does not release the live lease lock")
    func reopeningMarkerDoesNotReleaseLiveLeaseLock() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let token = UUID(uuidString: "46B8D1EF-1E8B-48A5-A0A8-DBD963765526")!
        let ownerProcessIdentifier = getpid()
        let lease = try acquireOwnerLease(scope: scope, token: token)
        var closed = false
        do {
            let liveStatus = try markerStat(at: scope.marker)
            _ = try Data(contentsOf: scope.marker)

            let busy: OwnerHelperProbeReply = try await runOwnerHelper(
                mode: .probe,
                marker: scope.marker
            )
            expectProbeReply(
                busy,
                outcome: .busy,
                token: token,
                ownerProcessIdentifier: ownerProcessIdentifier,
                markerStatus: liveStatus
            )

            try await closeLease(lease)
            closed = true
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test("exec does not inherit a descriptor for the live marker inode")
    func execDoesNotInheritMarkerDescriptor() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let token = UUID(uuidString: "667CCF94-312C-4CD1-9CE0-035DE526F944")!
        let lease = try acquireOwnerLease(scope: scope, token: token)
        var closed = false
        do {
            let liveStatus = try markerStat(at: scope.marker)
            let reply: OwnerHelperExecReply = try await runOwnerHelper(
                mode: .execCheck,
                marker: scope.marker
            )
            #expect(reply.protocolVersion == helperProtocolVersion)
            #expect(reply.mode == .execCheck)
            #expect(reply.outcome == .descriptorAbsent)
            #expect(reply.matchingDescriptorCount == 0)
            expectHelperIdentity(reply.identity, equals: liveStatus)

            try await closeLease(lease)
            closed = true
            try scope.removeAllArtifacts()
        } catch {
            await cleanupAfterFailure(lease: lease, scope: scope, alreadyClosed: closed)
            throw error
        }
    }

    @Test("deadline cancellation reaps the helper and its private process group")
    func blockingHelperDeadlineReapsPrivateProcessGroup() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let readinessFile = scope.directory.appendingPathComponent(
            "helper-ready.json",
            isDirectory: false
        )
        let deadline = Duration.milliseconds(25)
        do {
            #expect(markerIsAbsent(at: readinessFile))
            let observedError: BlockingHelperDeadlineError
            do {
                try await runBlockingOwnerHelper(
                    readinessFile: readinessFile,
                    deadline: deadline
                )
                throw OwnerLeaseContractError.helperExitedBeforeDeadline
            } catch let error as BlockingHelperDeadlineError {
                observedError = error
            }

            let observedDeadline: Duration
            let readiness: OwnerHelperReadiness
            switch observedError {
            case let .exceeded(deadline, value):
                observedDeadline = deadline
                readiness = value
            }
            #expect(
                observedError
                    == .exceeded(deadline: deadline, readiness: readiness)
            )
            #expect(observedDeadline == deadline)
            #expect(readiness.protocolVersion == helperProtocolVersion)
            #expect(readiness.mode == .block)
            #expect(readiness.publication == .atomicNoReplace)
            #expect(readiness.leaderProcessIdentifier > 0)
            #expect(
                readiness.leaderProcessIdentifier
                    == readiness.processGroupIdentifier
            )
            #expect(readiness.processGroupIdentifier != getpgrp())
            #expect(processIsAbsent(readiness.leaderProcessIdentifier))
            #expect(processGroupIsAbsent(readiness.processGroupIdentifier))
            try scope.removeAllArtifacts()
        } catch {
            cleanupScopeAfterFailure(scope)
            throw error
        }
    }

    @Test("isolated sequential close retries preserve the dup2 sentinel")
    func isolatedSequentialCloseRetriesPreserveSentinel() async throws {
        let scope = try OwnerLeaseTestScope.create()
        do {
            let reply: OwnerHelperCloseReply = try await runOwnerHelper(
                mode: .closeSequential,
                marker: scope.marker
            )
            expectCloseReply(
                reply,
                mode: .closeSequential,
                closeResultCallerCount: 3,
                cachedCloseResultCount: 2,
                coalescedCloseResultCount: 0
            )
            #expect(markerIsAbsent(at: scope.marker))
            #expect(try scope.artifactNames().isEmpty)
            try scope.removeAllArtifacts()
        } catch {
            cleanupScopeAfterFailure(scope)
            throw error
        }
    }

    @Test("isolated concurrent close calls coalesce around one descriptor close")
    func isolatedConcurrentCloseCallsCoalesce() async throws {
        let scope = try OwnerLeaseTestScope.create()
        do {
            let reply: OwnerHelperCloseReply = try await runOwnerHelper(
                mode: .closeConcurrent,
                marker: scope.marker
            )
            expectCloseReply(
                reply,
                mode: .closeConcurrent,
                closeResultCallerCount: 16,
                cachedCloseResultCount: 0,
                coalescedCloseResultCount: 15
            )
            #expect(markerIsAbsent(at: scope.marker))
            #expect(try scope.artifactNames().isEmpty)
            try scope.removeAllArtifacts()
        } catch {
            cleanupScopeAfterFailure(scope)
            throw error
        }
    }

    @Test("duplicate live acquisition preserves the active owner lease")
    func duplicateLiveAcquisitionPreservesOwner() async throws {
        let scope = try OwnerLeaseTestScope.create()
        let ownerToken = UUID(uuidString: "69E3B5F4-D38F-4162-9317-F81A3111CD91")!
        let ownerProcessIdentifier = getpid()
        let owner = try acquireOwnerLease(scope: scope, token: ownerToken)
        var unexpectedLease: OwnerLease?
        do {
            let before = try markerStat(at: scope.marker)
            let recordBefore = owner.record
            let checkpointsBefore = owner.checkpoints
            #expect(try matchingMarkerDescriptors(markerStatus: before).count == 1)

            let busyBefore: OwnerHelperProbeReply = try await runOwnerHelper(
                mode: .probe,
                marker: scope.marker
            )
            expectProbeReply(
                busyBefore,
                outcome: .busy,
                token: ownerToken,
                ownerProcessIdentifier: ownerProcessIdentifier,
                markerStatus: before
            )

            let observedError: OwnerLeaseAcquisitionError
            do {
                unexpectedLease = try OwnerLease.acquire(
                    marker: scope.marker,
                    token: UUID(uuidString: "C4BB8FB5-0995-46BE-A47E-46ECB7CF8E7A")!
                )
                throw OwnerLeaseContractError.unexpectedOwnerLeaseSuccess
            } catch let error as OwnerLeaseAcquisitionError {
                observedError = error
            } catch {
                throw OwnerLeaseContractError.unexpectedOwnerLeaseError
            }
            #expect(observedError == .markerAlreadyExists)

            let busyAfter: OwnerHelperProbeReply = try await runOwnerHelper(
                mode: .probe,
                marker: scope.marker
            )
            expectProbeReply(
                busyAfter,
                outcome: .busy,
                token: ownerToken,
                ownerProcessIdentifier: ownerProcessIdentifier,
                markerStatus: before
            )

            let after = try markerStat(at: scope.marker)
            #expect(after.device == before.device)
            #expect(after.inode == before.inode)
            #expect(after.size == before.size)
            #expect(after.mode == before.mode)
            #expect(try matchingMarkerDescriptors(markerStatus: after).count == 1)
            #expect(owner.record == recordBefore)
            #expect(owner.checkpoints == checkpointsBefore)

            try await closeLease(owner)
            let acquired: OwnerHelperProbeReply = try await runOwnerHelper(
                mode: .probe,
                marker: scope.marker
            )
            expectProbeReply(
                acquired,
                outcome: .acquired,
                token: ownerToken,
                ownerProcessIdentifier: ownerProcessIdentifier,
                markerStatus: after
            )
            try scope.removeAllArtifacts()
        } catch {
            let unexpectedCloseAuthenticated: Bool
            if let unexpectedLease {
                unexpectedCloseAuthenticated = await closeAndAuthenticate(
                    unexpectedLease,
                    markerStatus: retainedIdentityMarkerStat(unexpectedLease),
                    remainingMarkerDescriptorCount: 0
                )
            } else {
                unexpectedCloseAuthenticated = true
            }
            let ownerCloseAuthenticated = await closeAndAuthenticate(
                owner,
                markerStatus: retainedIdentityMarkerStat(owner),
                remainingMarkerDescriptorCount: 0
            )
            if unexpectedCloseAuthenticated, ownerCloseAuthenticated {
                cleanupScopeAfterFailure(scope)
            } else {
                recordPreservedOwnerArtifacts(in: scope)
            }
            throw error
        }
    }

    @Test("duplicate publication returns markerAlreadyExists without replacement")
    func duplicatePublicationReturnsTypedError() async throws {
        let scope = try OwnerLeaseTestScope.create()
        var existingStatus: MarkerStat?
        var unexpectedLease: OwnerLease?
        do {
            let existingContent = Data("existing-owner\n".utf8)
            try existingContent.write(to: scope.marker)
            guard chmod(scope.marker.path, 0o600) == 0 else {
                throw OwnerLeaseContractError.markerStatFailed(code: errno)
            }
            let before = try markerStat(at: scope.marker)
            existingStatus = before
            let observedError: OwnerLeaseAcquisitionError

            do {
                unexpectedLease = try OwnerLease.acquire(
                    marker: scope.marker,
                    token: UUID(uuidString: "86524295-62DD-42FC-897A-030617503EC1")!
                )
                throw OwnerLeaseContractError.unexpectedOwnerLeaseSuccess
            } catch let error as OwnerLeaseAcquisitionError {
                observedError = error
            } catch {
                throw OwnerLeaseContractError.unexpectedOwnerLeaseError
            }

            #expect(observedError == .markerAlreadyExists)
            let after = try markerStat(at: scope.marker)
            #expect(after == before)
            #expect(try Data(contentsOf: scope.marker) == existingContent)
            #expect(try scope.artifactNames() == [scope.marker.lastPathComponent])
            try scope.removeAllArtifacts()
            #expect(markerIsAbsent(at: scope.marker))
        } catch {
            guard let unexpectedLease else {
                cleanupScopeAfterFailure(scope)
                throw error
            }
            let unexpectedCloseAuthenticated = await closeAndAuthenticate(
                unexpectedLease,
                markerStatus: retainedIdentityMarkerStat(unexpectedLease),
                remainingMarkerDescriptorCount: 0
            )
            let publicIdentityAuthenticated: Bool
            if let existingStatus {
                publicIdentityAuthenticated = authenticateDescriptorCount(
                    markerStatus: existingStatus,
                    expected: 0
                )
            } else {
                publicIdentityAuthenticated = false
            }
            if unexpectedCloseAuthenticated, publicIdentityAuthenticated {
                cleanupScopeAfterFailure(scope)
            } else {
                recordPreservedOwnerArtifacts(in: scope)
            }
            throw error
        }
    }
}
