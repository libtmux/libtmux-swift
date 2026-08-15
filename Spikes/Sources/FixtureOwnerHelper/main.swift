import Foundation
import SpikeSupport
import TransportBakeoff

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private let protocolVersion = 2
private let maximumRecordSize = 16 * 1024
private let fileTypeMask: UInt32 = 0o170000
private let regularFileType: UInt32 = 0o100000
private let sentinelRecord = Array("libtmux-owner-close-sentinel-v1\n".utf8)

private enum HelperError: Error {
    case descriptorLimitUnavailable(code: Int32)
    case invalidArguments
    case invalidFile
    case invalidRecord
    case systemCall(operation: String, code: Int32)
    case timedOut
    case unexpectedCloseAccounting
    case unexpectedDescriptorCount
}

private struct FileIdentity: Codable, Sendable, Equatable {
    let device: UInt64
    let fileType: String
    let inode: UInt64
    let permissions: UInt16
    let size: Int64
}

private struct OwnerRecord: Codable, Sendable {
    let ownerProcessIdentifier: Int32
    let token: String
    let version: Int
}

private struct ProbeReply: Codable, Sendable {
    let identity: FileIdentity
    let lockKind: String
    let mode: String
    let outcome: String
    let protocolVersion: Int
    let record: OwnerRecord
}

private struct ExecReply: Codable, Sendable {
    let identity: FileIdentity
    let matchingDescriptorCount: Int
    let mode: String
    let outcome: String
    let protocolVersion: Int
}

private struct ReadinessReply: Codable, Sendable {
    let leaderProcessIdentifier: Int32
    let mode: String
    let processGroupIdentifier: Int32
    let protocolVersion: Int
    let publication: String
}

package enum FixtureOwnerRecoveryExitStatus: Int32, Sendable, Equatable {
    case success = 0
    case preserved = 1
    case rejected = 2
    case busy = 75
}

package struct FixtureOwnerRecoveryReply: Codable, Sendable, Equatable {
    package let mode: String
    package let outcome: String
    package let protocolVersion: Int
    package let reason: String?
}

package struct FixtureOwnerRecoveryDisposition: Sendable, Equatable {
    package let reply: FixtureOwnerRecoveryReply
    package let status: FixtureOwnerRecoveryExitStatus
}

package enum FixtureOwnerRecoveryRequestError: Error, Sendable, Equatable {
    case invalidArguments
    case invalidRunDirectory
    case invalidTmuxExecutable
}

package struct FixtureOwnerRecoveryRequest: Sendable, Equatable {
    package let runDirectory: URL
    package let expectedTmuxExecutable: ProcessExecutable?
}

package func fixtureOwnerRecoveryDisposition(
    for result: FixtureRecoveryResult
) -> FixtureOwnerRecoveryDisposition {
    let outcome: String
    switch result {
    case .alreadyAbsent:
        outcome = "already-absent"
    case .cleaned:
        outcome = "cleaned"
    }
    return FixtureOwnerRecoveryDisposition(
        reply: FixtureOwnerRecoveryReply(
            mode: "recover",
            outcome: outcome,
            protocolVersion: 2,
            reason: nil
        ),
        status: .success
    )
}

package func fixtureOwnerRecoveryDisposition(
    for error: FixtureRecoveryError
) -> FixtureOwnerRecoveryDisposition {
    let status: FixtureOwnerRecoveryExitStatus
    let outcome: String
    let reason: String
    switch error {
    case .artifactIdentityChanged:
        status = .rejected
        outcome = "rejected"
        reason = "artifact-identity-changed"
    case .cleanupStateUnverifiable:
        status = .preserved
        outcome = "preserved"
        reason = "cleanup-state-unverifiable"
    case .cleanupFailed:
        status = .preserved
        outcome = "preserved"
        reason = "cleanup-failed"
    case .filesystem:
        status = .preserved
        outcome = "preserved"
        reason = "filesystem"
    case .invalidMarker:
        status = .rejected
        outcome = "rejected"
        reason = "invalid-marker"
    case .invalidRunDirectory:
        status = .rejected
        outcome = "rejected"
        reason = "invalid-run-directory"
    case .invalidTmuxExecutable:
        status = .rejected
        outcome = "rejected"
        reason = "invalid-tmux-executable"
    case .markerBusy:
        status = .busy
        outcome = "busy"
        reason = "owner-lock-busy"
    case .ownerCloseFailed:
        status = .preserved
        outcome = "preserved"
        reason = "owner-close-failed"
    case .tmuxExecutableMismatch:
        status = .rejected
        outcome = "rejected"
        reason = "tmux-executable-mismatch"
    }
    return FixtureOwnerRecoveryDisposition(
        reply: FixtureOwnerRecoveryReply(
            mode: "recover",
            outcome: outcome,
            protocolVersion: 2,
            reason: reason
        ),
        status: status
    )
}

package func fixtureOwnerRecoveryJSONLine(
    _ reply: FixtureOwnerRecoveryReply
) throws -> [UInt8] {
    try canonicalJSONLine(reply)
}

package func fixtureOwnerRecoveryRequest(
    arguments: [String]
) throws -> FixtureOwnerRecoveryRequest {
    guard arguments.count == 3 || arguments.count == 5,
        arguments[0] == "recover",
        arguments[1] == "--run-directory"
    else {
        throw FixtureOwnerRecoveryRequestError.invalidArguments
    }
    let runDirectory = try fixtureOwnerRecoveryRunDirectory(arguments[2])
    let expectedTmuxExecutable: ProcessExecutable?
    if arguments.count == 5 {
        guard arguments[3] == "--expected-tmux-executable",
            let path = fixtureOwnerRecoveryExactPath(arguments[4])
        else {
            throw FixtureOwnerRecoveryRequestError.invalidTmuxExecutable
        }
        expectedTmuxExecutable = .path(path)
    } else {
        expectedTmuxExecutable = nil
    }
    return FixtureOwnerRecoveryRequest(
        runDirectory: runDirectory,
        expectedTmuxExecutable: expectedTmuxExecutable
    )
}

package func fixtureOwnerRecoveryTransport() -> any ProcessTransport {
    SwiftSubprocessTransport()
}

package func fixtureOwnerRecover(
    request: FixtureOwnerRecoveryRequest,
    transport: any ProcessTransport
) async -> FixtureOwnerRecoveryDisposition {
    do {
        let result = try await FixtureRecovery.recover(
            configuration: FixtureRecoveryConfiguration(
                runDirectory: request.runDirectory,
                expectedTmuxExecutable: request.expectedTmuxExecutable,
                childEnvironment: FixtureChildEnvironment(
                    path: "/usr/bin:/bin",
                    temporaryDirectory: "/tmp",
                    developerDirectory: nil,
                    sdkRoot: nil
                ),
                cleanupDeadline: .seconds(5),
                checkpointInterval: .milliseconds(10)
            ),
            transport: transport
        )
        return fixtureOwnerRecoveryDisposition(for: result)
    } catch let error as FixtureRecoveryError {
        return fixtureOwnerRecoveryDisposition(for: error)
    } catch {
        return FixtureOwnerRecoveryDisposition(
            reply: FixtureOwnerRecoveryReply(
                mode: "recover",
                outcome: "preserved",
                protocolVersion: 2,
                reason: "unexpected-failure"
            ),
            status: .preserved
        )
    }
}

private func fixtureOwnerRecoveryRunDirectory(
    _ rawPath: String
) throws -> URL {
    guard let path = fixtureOwnerRecoveryExactPath(rawPath) else {
        throw FixtureOwnerRecoveryRequestError.invalidRunDirectory
    }
    let runDirectory = URL(fileURLWithPath: path, isDirectory: true)
    let name = runDirectory.lastPathComponent
    guard name.hasPrefix("f-"), name.count > 2 else {
        throw FixtureOwnerRecoveryRequestError.invalidRunDirectory
    }

    var status = stat()
    let lstatResult = path.withCString { pointer in
        lstat(pointer, &status)
    }
    if lstatResult == 0 {
        guard UInt32(status.st_mode) & 0o170000 == 0o040000 else {
            throw FixtureOwnerRecoveryRequestError.invalidRunDirectory
        }
    } else if errno != ENOENT {
        throw FixtureOwnerRecoveryRequestError.invalidRunDirectory
    }
    return runDirectory
}

private func fixtureOwnerRecoveryExactPath(_ rawPath: String) -> String? {
    guard rawPath.hasPrefix("/") else { return nil }
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
    guard path == rawPath else { return nil }
    return path
}

private struct CloseReply: Codable, Sendable {
    let cachedCloseResultCount: Int
    let closeResultCallerCount: Int
    let coalescedCloseResultCount: Int
    let descriptorCloseCallCount: Int
    let markerDescriptorCountAfterClose: Int
    let markerDescriptorCountBeforeClose: Int
    let mode: String
    let outcome: String
    let protocolVersion: Int
    let sentinelBytesAfterRetries: [UInt8]
    let sentinelBytesBeforeRetries: [UInt8]
    let sentinelIdentityAfterRetries: FileIdentity
    let sentinelIdentityBeforeRetries: FileIdentity
    let sentinelIdentityWasReadWithFstatAfterRetries: Bool
    let sentinelRecordWasReadFromRetiredDescriptorAfterRetries: Bool
    let sentinelWasDuplicatedOntoRetiredDescriptorWithDup2: Bool
}

private struct Sentinel {
    let descriptor: Int32
    let identity: FileIdentity
    let path: URL
}

private actor DescriptorCloseHook {
    private let descriptorClosed = AsyncGate()
    private let releaseClose = AsyncGate()
    private let shouldBlock: Bool
    private let sourceDescriptor: Int32
    private var duplicationSucceeded = false
    private var retiredDescriptor: Int32?

    init(sourceDescriptor: Int32, shouldBlock: Bool) {
        self.sourceDescriptor = sourceDescriptor
        self.shouldBlock = shouldBlock
    }

    func install(retiredDescriptor: Int32) {
        self.retiredDescriptor = retiredDescriptor
    }

    func afterDescriptorClose() async {
        if let retiredDescriptor, retiredDescriptor != sourceDescriptor {
            var result: Int32
            repeat {
                result = dup2(sourceDescriptor, retiredDescriptor)
            } while result < 0 && errno == EINTR
            duplicationSucceeded = result == retiredDescriptor
        }
        await descriptorClosed.open()
        if shouldBlock {
            try? await releaseClose.wait(timeout: .seconds(30))
        }
    }

    func waitForDescriptorClose() async throws {
        do {
            try await descriptorClosed.wait(timeout: .seconds(5))
        } catch {
            throw HelperError.timedOut
        }
    }

    func release() async {
        await releaseClose.open()
    }

    func didDuplicateDescriptor() -> Bool {
        duplicationSucceeded
    }
}

private func systemCallError(_ operation: String) -> HelperError {
    .systemCall(operation: operation, code: errno)
}

private func canonicalJSONLine<Value: Encodable>(_ value: Value) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = Array(try encoder.encode(value))
    guard !bytes.contains(0x0A) else { throw HelperError.invalidRecord }
    bytes.append(0x0A)
    return bytes
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = write(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw systemCallError("write")
            }
        }
    }
}

private func readExactly(
    from descriptor: Int32,
    size: Int64
) throws -> [UInt8] {
    guard size >= 0, size <= Int64(maximumRecordSize) else {
        throw HelperError.invalidRecord
    }
    var bytes = [UInt8](repeating: 0, count: Int(size))
    try bytes.withUnsafeMutableBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            let count = pread(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset,
                off_t(offset)
            )
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count == 0 {
                throw HelperError.invalidRecord
            } else {
                throw systemCallError("pread")
            }
        }
    }
    return bytes
}

private func identity(from status: stat) throws -> FileIdentity {
    let mode = UInt32(status.st_mode)
    guard mode & fileTypeMask == regularFileType, status.st_size >= 0 else {
        throw HelperError.invalidFile
    }
    return FileIdentity(
        device: UInt64(status.st_dev),
        fileType: "regular",
        inode: UInt64(status.st_ino),
        permissions: UInt16(mode & 0o777),
        size: Int64(status.st_size)
    )
}

private func descriptorIdentity(_ descriptor: Int32) throws -> FileIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw systemCallError("fstat")
    }
    return try identity(from: status)
}

private func pathIdentity(_ path: String) throws -> FileIdentity {
    var status = stat()
    guard lstat(path, &status) == 0 else {
        throw systemCallError("lstat")
    }
    return try identity(from: status)
}

private func descriptorScanUpperBound() throws -> Int32 {
    errno = 0
    let openMaximum = sysconf(Int32(_SC_OPEN_MAX))
    let code = errno
    guard openMaximum > 0, openMaximum <= Int(Int32.max) else {
        throw HelperError.descriptorLimitUnavailable(code: code)
    }
    return Int32(openMaximum)
}

private func matchingDescriptors(for identity: FileIdentity) throws -> [Int32] {
    let upperBound = try descriptorScanUpperBound()
    var matches: [Int32] = []
    for descriptor in 0..<upperBound {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { continue }
        if UInt64(status.st_dev) == identity.device,
            UInt64(status.st_ino) == identity.inode
        {
            matches.append(descriptor)
        }
    }
    return matches
}

private func closeDescriptor(_ descriptor: Int32) throws {
    guard close(descriptor) == 0 else {
        throw systemCallError("close")
    }
}

private func unlinkIfPresent(_ path: String) throws {
    if unlink(path) != 0, errno != ENOENT {
        throw systemCallError("unlink")
    }
}

private func synchronizeDirectory(containing path: URL) throws {
    let directory = path.deletingLastPathComponent()
    let descriptor = open(
        directory.path,
        O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
    )
    guard descriptor >= 0 else { throw systemCallError("open-directory") }

    let syncResult = fsync(descriptor)
    let syncCode = errno
    let closeResult = close(descriptor)
    let closeCode = errno
    if syncResult != 0, syncCode != EINVAL, syncCode != ENOTSUP {
        throw HelperError.systemCall(operation: "fsync-directory", code: syncCode)
    }
    guard closeResult == 0 else {
        throw HelperError.systemCall(operation: "close-directory", code: closeCode)
    }
}

private func atomicPublish(_ bytes: [UInt8], to destination: URL) throws {
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
        ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
        isDirectory: false
    )
    var stagingExists = false
    var descriptorIsOpen = false
    let descriptor = open(
        staging.path,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0 else { throw systemCallError("open-staging") }
    stagingExists = true
    descriptorIsOpen = true
    defer {
        if descriptorIsOpen { _ = close(descriptor) }
        if stagingExists { _ = unlink(staging.path) }
    }

    guard fchmod(descriptor, 0o600) == 0 else {
        throw systemCallError("fchmod-staging")
    }
    try writeAll(bytes, to: descriptor)
    guard fsync(descriptor) == 0 else { throw systemCallError("fsync-staging") }
    let closeResult = close(descriptor)
    let closeCode = errno
    descriptorIsOpen = false
    guard closeResult == 0 else {
        throw HelperError.systemCall(operation: "close-staging", code: closeCode)
    }

    let linkResult = staging.path.withCString { stagingPath in
        destination.path.withCString { destinationPath in
            linkat(AT_FDCWD, stagingPath, AT_FDCWD, destinationPath, 0)
        }
    }
    guard linkResult == 0 else { throw systemCallError("linkat") }
    guard unlink(staging.path) == 0 else { throw systemCallError("unlink-staging") }
    stagingExists = false
    try synchronizeDirectory(containing: destination)
}

private func validatedPath(_ value: String) throws -> URL {
    let url = URL(fileURLWithPath: value, isDirectory: false)
    guard value.hasPrefix("/"), url.standardizedFileURL.path == value else {
        throw HelperError.invalidArguments
    }
    return url
}

private func probe(marker: URL) throws -> ProbeReply {
    let publicIdentity = try pathIdentity(marker.path)
    let descriptor = open(marker.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw systemCallError("open-marker") }
    defer { _ = close(descriptor) }

    let openedIdentity = try descriptorIdentity(descriptor)
    guard openedIdentity == publicIdentity else { throw HelperError.invalidFile }
    let recordBytes = try readExactly(from: descriptor, size: openedIdentity.size)
    let record: OwnerRecord
    do {
        record = try JSONDecoder().decode(OwnerRecord.self, from: Data(recordBytes))
    } catch {
        throw HelperError.invalidRecord
    }

    let lockResult = flock(descriptor, LOCK_EX | LOCK_NB)
    let lockCode = errno
    let outcome: String
    if lockResult == 0 {
        outcome = "acquired"
    } else if lockCode == EWOULDBLOCK {
        outcome = "busy"
    } else {
        throw HelperError.systemCall(operation: "flock-lock", code: lockCode)
    }

    return ProbeReply(
        identity: openedIdentity,
        lockKind: "flock-exclusive-nonblocking",
        mode: "probe",
        outcome: outcome,
        protocolVersion: protocolVersion,
        record: record
    )
}

private func checkExecInheritance(marker: URL) throws -> ExecReply {
    let identity = try pathIdentity(marker.path)
    return ExecReply(
        identity: identity,
        matchingDescriptorCount: try matchingDescriptors(for: identity).count,
        mode: "exec-check",
        outcome: "descriptor-absent",
        protocolVersion: protocolVersion
    )
}

private func createSentinel(nextTo marker: URL) throws -> Sentinel {
    let path = marker.deletingLastPathComponent().appendingPathComponent(
        ".owner-close-sentinel.\(UUID().uuidString)",
        isDirectory: false
    )
    let descriptor = open(
        path.path,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0 else { throw systemCallError("open-sentinel") }
    do {
        guard fchmod(descriptor, 0o600) == 0 else {
            throw systemCallError("fchmod-sentinel")
        }
        try writeAll(sentinelRecord, to: descriptor)
        guard fsync(descriptor) == 0 else { throw systemCallError("fsync-sentinel") }
        let identity = try descriptorIdentity(descriptor)
        guard identity.permissions == 0o600,
            identity.size == Int64(sentinelRecord.count)
        else {
            throw HelperError.invalidFile
        }
        return Sentinel(descriptor: descriptor, identity: identity, path: path)
    } catch {
        _ = close(descriptor)
        _ = unlink(path.path)
        throw error
    }
}

private func waitForCoalescedCallers(
    _ lease: OwnerLease,
    expected: Int
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if lease.checkpoints?.closed?.coalescedCloseResultCount == expected {
            return
        }
        await Task.yield()
    }
    throw HelperError.timedOut
}

private func closeSequentially(_ lease: OwnerLease) async throws {
    for _ in 0..<3 {
        let result = await lease.closeResult()
        try result.get()
    }
}

private func closeConcurrently(
    _ lease: OwnerLease,
    hook: DescriptorCloseHook
) async throws {
    let firstClose = Task { await lease.closeResult() }
    do {
        try await hook.waitForDescriptorClose()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<15 {
                group.addTask {
                    let result = await lease.closeResult()
                    try result.get()
                }
            }
            do {
                try await waitForCoalescedCallers(lease, expected: 15)
                await hook.release()
                try await group.waitForAll()
            } catch {
                await hook.release()
                group.cancelAll()
                throw error
            }
        }
        let firstResult = await firstClose.value
        try firstResult.get()
    } catch {
        await hook.release()
        _ = await firstClose.value
        throw error
    }
}

private func exerciseClose(marker: URL, concurrent: Bool) async throws -> CloseReply {
    let sentinel = try createSentinel(nextTo: marker)
    let bytesBeforeRetries = try readExactly(
        from: sentinel.descriptor,
        size: sentinel.identity.size
    )
    let hook = DescriptorCloseHook(
        sourceDescriptor: sentinel.descriptor,
        shouldBlock: concurrent
    )

    let lease: OwnerLease
    do {
        lease = try OwnerLease.acquire(
            marker: marker,
            token: UUID(),
            afterDescriptorClose: { await hook.afterDescriptorClose() }
        )
    } catch {
        _ = close(sentinel.descriptor)
        _ = unlink(sentinel.path.path)
        throw error
    }

    let markerIdentity = FileIdentity(
        device: lease.identity.device,
        fileType: "regular",
        inode: lease.identity.inode,
        permissions: lease.identity.permissions,
        size: lease.identity.size
    )
    let markerDescriptorsBeforeClose = try matchingDescriptors(for: markerIdentity)
    guard markerDescriptorsBeforeClose.count == 1,
        let retiredDescriptor = markerDescriptorsBeforeClose.first,
        retiredDescriptor != sentinel.descriptor
    else {
        throw HelperError.unexpectedDescriptorCount
    }
    await hook.install(retiredDescriptor: retiredDescriptor)

    if concurrent {
        try await closeConcurrently(lease, hook: hook)
    } else {
        try await closeSequentially(lease)
    }

    let markerDescriptorCountAfterClose = try matchingDescriptors(for: markerIdentity).count
    let sentinelIdentityAfterRetries = try descriptorIdentity(retiredDescriptor)
    let sentinelBytesAfterRetries = try readExactly(
        from: retiredDescriptor,
        size: sentinelIdentityAfterRetries.size
    )
    guard let closed = lease.checkpoints?.closed else {
        throw HelperError.unexpectedCloseAccounting
    }
    let expectedCached = concurrent ? 0 : 2
    let expectedCoalesced = concurrent ? 15 : 0
    guard closed.descriptorCloseAttemptCount == 1,
        closed.cachedCloseResultCount == expectedCached,
        closed.coalescedCloseResultCount == expectedCoalesced
    else {
        throw HelperError.unexpectedCloseAccounting
    }

    let duplicationSucceeded = await hook.didDuplicateDescriptor()
    guard close(retiredDescriptor) == 0 else {
        throw systemCallError("close-retired-descriptor")
    }
    try closeDescriptor(sentinel.descriptor)
    try unlinkIfPresent(marker.path)
    try unlinkIfPresent(sentinel.path.path)
    try synchronizeDirectory(containing: marker)

    return CloseReply(
        cachedCloseResultCount: closed.cachedCloseResultCount,
        closeResultCallerCount: concurrent ? 16 : 3,
        coalescedCloseResultCount: closed.coalescedCloseResultCount,
        descriptorCloseCallCount: closed.descriptorCloseAttemptCount,
        markerDescriptorCountAfterClose: markerDescriptorCountAfterClose,
        markerDescriptorCountBeforeClose: markerDescriptorsBeforeClose.count,
        mode: concurrent ? "close-concurrent" : "close-sequential",
        outcome: "sentinel-authenticated",
        protocolVersion: protocolVersion,
        sentinelBytesAfterRetries: sentinelBytesAfterRetries,
        sentinelBytesBeforeRetries: bytesBeforeRetries,
        sentinelIdentityAfterRetries: sentinelIdentityAfterRetries,
        sentinelIdentityBeforeRetries: sentinel.identity,
        sentinelIdentityWasReadWithFstatAfterRetries: true,
        sentinelRecordWasReadFromRetiredDescriptorAfterRetries: true,
        sentinelWasDuplicatedOntoRetiredDescriptorWithDup2: duplicationSucceeded
    )
}

private func block(readinessPath: URL) throws -> Never {
    let readiness = ReadinessReply(
        leaderProcessIdentifier: getpid(),
        mode: "block",
        processGroupIdentifier: getpgrp(),
        protocolVersion: protocolVersion,
        publication: "atomic-no-replace"
    )
    try atomicPublish(try canonicalJSONLine(readiness), to: readinessPath)
    while true { _ = pause() }
}

private func recoveryRejection(
    reason: String
) -> FixtureOwnerRecoveryDisposition {
    FixtureOwnerRecoveryDisposition(
        reply: FixtureOwnerRecoveryReply(
            mode: "recover",
            outcome: "rejected",
            protocolVersion: 2,
            reason: reason
        ),
        status: .rejected
    )
}

private func recoveryRequestRejection(
    _ error: FixtureOwnerRecoveryRequestError
) -> FixtureOwnerRecoveryDisposition {
    switch error {
    case .invalidArguments:
        return recoveryRejection(reason: "invalid-arguments")
    case .invalidRunDirectory:
        return recoveryRejection(reason: "invalid-run-directory")
    case .invalidTmuxExecutable:
        return recoveryRejection(reason: "invalid-tmux-executable")
    }
}

package func fixtureOwnerRecoveryExecutableIsAuthenticated(
    at path: String,
    effectiveUserID: uid_t
) -> Bool {
    guard path.hasPrefix("/"),
        URL(fileURLWithPath: path).standardizedFileURL.path == path,
        URL(fileURLWithPath: path).lastPathComponent == "fixture-owner-helper",
        access(path, X_OK) == 0
    else {
        return false
    }
    var status = stat()
    let result = path.withCString { pointer in
        lstat(pointer, &status)
    }
    return result == 0
        && UInt32(status.st_mode) & 0o170000 == 0o100000
        && status.st_uid == effectiveUserID
        && UInt32(status.st_mode) & 0o022 == 0
}

private func recoveryExecutableIsAuthenticated() -> Bool {
    fixtureOwnerRecoveryExecutableIsAuthenticated(
        at: CommandLine.arguments[0],
        effectiveUserID: geteuid()
    )
}

private func runRecoveryHelper(arguments: [String]) async throws -> Int32 {
    let disposition: FixtureOwnerRecoveryDisposition
    if !recoveryExecutableIsAuthenticated() {
        disposition = recoveryRejection(
            reason: "helper-authentication-failed"
        )
    } else {
        do {
            let request = try fixtureOwnerRecoveryRequest(arguments: arguments)
            disposition = await fixtureOwnerRecover(
                request: request,
                transport: fixtureOwnerRecoveryTransport()
            )
        } catch let error as FixtureOwnerRecoveryRequestError {
            disposition = recoveryRequestRejection(error)
        }
    }
    try writeAll(
        try fixtureOwnerRecoveryJSONLine(disposition.reply),
        to: STDOUT_FILENO
    )
    return disposition.status.rawValue
}

private func runHelper() async throws -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else { throw HelperError.invalidArguments }

    switch mode {
    case "recover":
        return try await runRecoveryHelper(arguments: arguments)
    case "probe", "exec-check", "close-sequential", "close-concurrent":
        guard arguments.count == 3, arguments[1] == "--marker" else {
            throw HelperError.invalidArguments
        }
        let marker = try validatedPath(arguments[2])
        let output: [UInt8]
        switch mode {
        case "probe":
            output = try canonicalJSONLine(probe(marker: marker))
        case "exec-check":
            output = try canonicalJSONLine(checkExecInheritance(marker: marker))
        case "close-sequential":
            output = try canonicalJSONLine(
                await exerciseClose(marker: marker, concurrent: false)
            )
        case "close-concurrent":
            output = try canonicalJSONLine(
                await exerciseClose(marker: marker, concurrent: true)
            )
        default:
            throw HelperError.invalidArguments
        }
        try writeAll(output, to: STDOUT_FILENO)
        return 0
    case "block":
        guard arguments.count == 3, arguments[1] == "--ready" else {
            throw HelperError.invalidArguments
        }
        try block(readinessPath: validatedPath(arguments[2]))
    default:
        throw HelperError.invalidArguments
    }
}

private func main() async -> Int32 {
    do {
        return try await runHelper()
    } catch {
        return 1
    }
}

exit(await main())
