import Foundation

#if canImport(Darwin)
    import Darwin
    import os
#else
    import Glibc
    import Synchronization
#endif

package enum OwnerLeaseFileType: Sendable, Equatable {
    case regular
}

package struct OwnerLeaseRecord: Codable, Sendable, Equatable {
    package let ownerProcessIdentifier: Int32
    package let token: UUID
    package let version: Int
}

package struct OwnerLeaseIdentity: Sendable, Equatable {
    package let device: UInt64
    package let fileType: OwnerLeaseFileType
    package let inode: UInt64
    package let permissions: UInt16
    package let size: Int64
}

package enum OwnerLeaseLock: Sendable, Equatable {
    case bsdExclusiveNonblocking
}

package enum OwnerLeasePublicationMethod: Sendable, Equatable {
    case linkatThenUnlink
}

package enum OwnerLeaseDirectorySynchronization: Sendable, Equatable {
    case synchronized
    case unsupported
}

package struct OwnerLeasePreparedCheckpoint: Sendable, Equatable {
    package let markerIdentityBeforePublication: OwnerLeaseIdentity?
    package let openFlags: Int32
    package let descriptorFlags: Int32
    package let lock: OwnerLeaseLock
    package let permissionsWereSetWithFchmod: Bool
    package let descriptorIdentityWasReadWithFstat: Bool
    package let descriptorIdentity: OwnerLeaseIdentity
    package let recordBytes: [UInt8]
    package let bytesWritten: Int
    package let recordWasWrittenThroughRetainedDescriptor: Bool
    package let wasTruncated: Bool
    package let wasSynchronized: Bool
}

package struct OwnerLeasePublishedCheckpoint: Sendable, Equatable {
    package let method: OwnerLeasePublicationMethod
    package let stagingPathWasRemoved: Bool
    package let descriptorIdentity: OwnerLeaseIdentity
    package let pathIdentity: OwnerLeaseIdentity
    package let pathIdentityWasReadWithLstat: Bool
    package let directorySynchronization: OwnerLeaseDirectorySynchronization
}

package struct OwnerLeaseReadyCheckpoint: Sendable, Equatable {
    package let recordBytes: [UInt8]
    package let bytesWritten: Int
    package let writeOffset: Int64
    package let recordWasWrittenThroughRetainedDescriptor: Bool
    package let wasSynchronized: Bool
    package let descriptorIdentity: OwnerLeaseIdentity
    package let pathIdentity: OwnerLeaseIdentity
    package let pathIdentityWasReadWithLstat: Bool
    package let recoverySidecarIdentity: OwnerLeaseIdentity?
    package let recoverySidecarWasLinkedToRetainedDescriptor: Bool
    package let recoverySidecarParentSynchronization: OwnerLeaseDirectorySynchronization?
}

package struct OwnerLeaseClosedCheckpoint: Sendable, Equatable {
    package let descriptorCloseAttemptCount: Int
    package let cachedCloseResultCount: Int
    package let coalescedCloseResultCount: Int
}

package struct OwnerLeaseCheckpoints: Sendable, Equatable {
    package let prepared: OwnerLeasePreparedCheckpoint
    package let published: OwnerLeasePublishedCheckpoint
    package let ready: OwnerLeaseReadyCheckpoint?
    package let closed: OwnerLeaseClosedCheckpoint?
}

package struct OwnerLeaseRecoveryCheckpoint: Sendable, Equatable {
    package let descriptorFlags: Int32
    package let lock: OwnerLeaseLock
    package let markerBytes: [UInt8]
    package let bytesRead: Int
    package let recordWasReadThroughRetainedDescriptor: Bool
    package let descriptorIdentity: OwnerLeaseIdentity
    package let pathIdentity: OwnerLeaseIdentity
    package let pathIdentityWasReadWithFstatat: Bool
    package let closed: OwnerLeaseClosedCheckpoint?
}

package enum OwnerLeaseAcquisitionError: Error, Sendable, Equatable {
    case invalidMarkerPath
    case invariantViolation(String)
    case markerAlreadyExists
    case systemCall(operation: String, code: Int32)
}

package enum OwnerLeaseCloseError: Error, Sendable, Equatable {
    case systemCall(operation: String, code: Int32)
}

package enum OwnerLeaseReadyPublicationError: Error, Sendable, Equatable {
    case checkpointFailure
    case invalidRecord
    case invariantViolation(String)
    case leaseClosing
    case readyAlreadyPublished
    case systemCall(operation: String, code: Int32)
}

package enum OwnerLeaseRecoveryClaimError: Error, Sendable, Equatable {
    case identityChanged
    case invalidMarker
    case markerBusy
    case systemCall(operation: String, code: Int32)
}

package struct OwnerLeaseRecoveryClaim: Sendable {
    package let lease: OwnerLease
    package let markerRecord: FixtureRecoveryMarkerRecord
}

package typealias OwnerLeaseAfterDescriptorClose = @Sendable () async -> Void
package typealias OwnerLeaseBeforeReadySynchronization = @Sendable () async -> Void
package typealias OwnerLeaseDescriptorClose =
    @Sendable (Int32) -> Result<
        Void,
        OwnerLeaseCloseError
    >

package func ownerLeaseDescriptorClose(
    _ descriptor: Int32
) -> Result<Void, OwnerLeaseCloseError> {
    if ownerClose(descriptor) == 0 {
        return .success(())
    }
    return .failure(
        .systemCall(operation: "close-owner", code: errno)
    )
}

package final class OwnerLease: Sendable {
    package let marker: URL
    package let record: OwnerLeaseRecord
    package let identity: OwnerLeaseIdentity

    private let closeCoordinator: OwnerLeaseCloseCoordinator

    package var checkpoints: OwnerLeaseCheckpoints? {
        closeCoordinator.checkpoints
    }

    package var recoveryCheckpoint: OwnerLeaseRecoveryCheckpoint? {
        closeCoordinator.recoveryCheckpoint
    }

    private init(
        marker: URL,
        record: OwnerLeaseRecord,
        identity: OwnerLeaseIdentity,
        checkpoints: OwnerLeaseCheckpoints?,
        recoveryCheckpoint: OwnerLeaseRecoveryCheckpoint? = nil,
        descriptor: Int32,
        descriptorClose: @escaping OwnerLeaseDescriptorClose,
        beforeReadySynchronization: OwnerLeaseBeforeReadySynchronization?,
        afterDescriptorClose: OwnerLeaseAfterDescriptorClose?
    ) {
        self.marker = marker
        self.record = record
        self.identity = identity
        closeCoordinator = OwnerLeaseCloseCoordinator(
            marker: marker,
            descriptor: descriptor,
            descriptorClose: descriptorClose,
            checkpoints: checkpoints,
            recoveryCheckpoint: recoveryCheckpoint,
            beforeReadySynchronization: beforeReadySynchronization,
            afterDescriptorClose: afterDescriptorClose
        )
    }

    package static func acquire(
        marker: URL,
        token: UUID,
        descriptorClose: @escaping OwnerLeaseDescriptorClose = ownerLeaseDescriptorClose,
        beforeReadySynchronization: OwnerLeaseBeforeReadySynchronization? = nil,
        afterDescriptorClose: OwnerLeaseAfterDescriptorClose? = nil
    ) throws -> OwnerLease {
        guard marker.isFileURL, marker.path.hasPrefix("/") else {
            throw OwnerLeaseAcquisitionError.invalidMarkerPath
        }
        let markerName = marker.lastPathComponent
        guard !markerName.isEmpty, markerName != ".", markerName != ".." else {
            throw OwnerLeaseAcquisitionError.invalidMarkerPath
        }

        let parent = marker.deletingLastPathComponent()
        let directoryFlags = Int32(O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        let directoryDescriptor = parent.path.withCString {
            open($0, directoryFlags)
        }
        guard directoryDescriptor >= 0 else {
            throw ownerAcquisitionSystemCall("open-parent", errno)
        }
        defer { _ = ownerClose(directoryDescriptor) }

        let openFlags = Int32(O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW)
        let stagingName = ".\(markerName).owner-\(UUID().uuidString).staging"
        let descriptor = stagingName.withCString {
            openat(directoryDescriptor, $0, openFlags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw ownerAcquisitionSystemCall("openat-staging", errno)
        }

        var stagingExists = true
        var markerWasPublished = false
        var preparedIdentity: OwnerLeaseIdentity?

        do {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw ownerAcquisitionSystemCall("fchmod-staging", errno)
            }
            let initialIdentity = try ownerIdentityFromDescriptor(descriptor)
            guard initialIdentity.fileType == .regular,
                initialIdentity.permissions == 0o600
            else {
                throw OwnerLeaseAcquisitionError.invariantViolation(
                    "staging descriptor is not a 0600 regular file"
                )
            }

            let descriptorFlags = fcntl(descriptor, F_GETFD)
            guard descriptorFlags >= 0 else {
                throw ownerAcquisitionSystemCall("fcntl-getfd", errno)
            }
            guard descriptorFlags & FD_CLOEXEC == FD_CLOEXEC else {
                throw OwnerLeaseAcquisitionError.invariantViolation(
                    "staging descriptor is not close-on-exec"
                )
            }

            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw ownerAcquisitionSystemCall("flock-lock", errno)
            }

            let record = OwnerLeaseRecord(
                ownerProcessIdentifier: getpid(),
                token: token,
                version: 1
            )
            let recordBytes = Array(
                ("{\"ownerProcessIdentifier\":\(record.ownerProcessIdentifier),"
                    + "\"token\":\"\(record.token.uuidString)\",\"version\":1}\n").utf8
            )

            guard ftruncate(descriptor, 0) == 0 else {
                throw ownerAcquisitionSystemCall("ftruncate-record", errno)
            }
            guard lseek(descriptor, 0, SEEK_SET) == 0 else {
                throw ownerAcquisitionSystemCall("lseek-record", errno)
            }
            let bytesWritten = try ownerWriteAll(descriptor, bytes: recordBytes)
            guard fsync(descriptor) == 0 else {
                throw ownerAcquisitionSystemCall("fsync-record", errno)
            }

            let descriptorIdentity = try ownerIdentityFromDescriptor(descriptor)
            preparedIdentity = descriptorIdentity
            guard descriptorIdentity.device == initialIdentity.device,
                descriptorIdentity.inode == initialIdentity.inode,
                descriptorIdentity.fileType == .regular,
                descriptorIdentity.permissions == 0o600,
                descriptorIdentity.size == Int64(recordBytes.count)
            else {
                throw OwnerLeaseAcquisitionError.invariantViolation(
                    "prepared descriptor identity changed unexpectedly"
                )
            }

            if try ownerPathExistsWithoutFollowing(marker) {
                throw OwnerLeaseAcquisitionError.markerAlreadyExists
            }
            let markerIdentityBeforePublication: OwnerLeaseIdentity? = nil
            let prepared = OwnerLeasePreparedCheckpoint(
                markerIdentityBeforePublication: markerIdentityBeforePublication,
                openFlags: openFlags,
                descriptorFlags: descriptorFlags,
                lock: .bsdExclusiveNonblocking,
                permissionsWereSetWithFchmod: true,
                descriptorIdentityWasReadWithFstat: true,
                descriptorIdentity: descriptorIdentity,
                recordBytes: recordBytes,
                bytesWritten: bytesWritten,
                recordWasWrittenThroughRetainedDescriptor: true,
                wasTruncated: true,
                wasSynchronized: true
            )

            let linkResult = stagingName.withCString { stagingPath in
                markerName.withCString { markerPath in
                    linkat(
                        directoryDescriptor,
                        stagingPath,
                        directoryDescriptor,
                        markerPath,
                        0
                    )
                }
            }
            guard linkResult == 0 else {
                let code = errno
                if code == EEXIST {
                    throw OwnerLeaseAcquisitionError.markerAlreadyExists
                }
                throw ownerAcquisitionSystemCall("linkat-publish", code)
            }
            markerWasPublished = true

            let unlinkStagingResult = stagingName.withCString {
                unlinkat(directoryDescriptor, $0, 0)
            }
            guard unlinkStagingResult == 0 else {
                throw ownerAcquisitionSystemCall("unlinkat-staging", errno)
            }
            stagingExists = false

            let pathIdentity = try ownerIdentityFromPath(marker)
            guard pathIdentity == descriptorIdentity else {
                throw OwnerLeaseAcquisitionError.invariantViolation(
                    "published path does not name the retained descriptor inode"
                )
            }

            let directorySynchronization: OwnerLeaseDirectorySynchronization
            if fsync(directoryDescriptor) == 0 {
                directorySynchronization = .synchronized
            } else {
                let code = errno
                guard ownerDirectorySynchronizationIsUnsupported(code) else {
                    throw ownerAcquisitionSystemCall("fsync-parent", code)
                }
                directorySynchronization = .unsupported
            }

            let published = OwnerLeasePublishedCheckpoint(
                method: .linkatThenUnlink,
                stagingPathWasRemoved: true,
                descriptorIdentity: descriptorIdentity,
                pathIdentity: pathIdentity,
                pathIdentityWasReadWithLstat: true,
                directorySynchronization: directorySynchronization
            )
            let checkpoints = OwnerLeaseCheckpoints(
                prepared: prepared,
                published: published,
                ready: nil,
                closed: nil
            )
            return OwnerLease(
                marker: marker,
                record: record,
                identity: pathIdentity,
                checkpoints: checkpoints,
                descriptor: descriptor,
                descriptorClose: descriptorClose,
                beforeReadySynchronization: beforeReadySynchronization,
                afterDescriptorClose: afterDescriptorClose
            )
        } catch {
            if markerWasPublished,
                let preparedIdentity,
                (try? ownerIdentityFromPath(marker)) == preparedIdentity
            {
                _ = markerName.withCString {
                    unlinkat(directoryDescriptor, $0, 0)
                }
            }
            if stagingExists {
                _ = stagingName.withCString {
                    unlinkat(directoryDescriptor, $0, 0)
                }
            }
            _ = ownerClose(descriptor)
            throw error
        }
    }

    package static func claimRecoveryMarker(
        marker: URL,
        directoryDescriptor: Int32,
        markerName: String,
        descriptorClose: @escaping OwnerLeaseDescriptorClose = ownerLeaseDescriptorClose
    ) throws -> OwnerLeaseRecoveryClaim {
        guard marker.isFileURL,
            marker.path.hasPrefix("/"),
            marker.lastPathComponent == markerName,
            !markerName.isEmpty,
            markerName != ".",
            markerName != ".."
        else {
            throw OwnerLeaseRecoveryClaimError.invalidMarker
        }
        let flags = Int32(O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        let descriptor = markerName.withCString {
            openat(directoryDescriptor, $0, flags)
        }
        guard descriptor >= 0 else {
            throw ownerRecoverySystemCall("openat-owner", errno)
        }

        var transferred = false
        defer {
            if !transferred {
                _ = ownerClose(descriptor)
            }
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR {
                continue
            }
            if code == EAGAIN || code == EWOULDBLOCK {
                throw OwnerLeaseRecoveryClaimError.markerBusy
            }
            throw ownerRecoverySystemCall("flock-owner", code)
        }

        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0 else {
            throw ownerRecoverySystemCall("fcntl-owner", errno)
        }
        guard descriptorFlags & FD_CLOEXEC == FD_CLOEXEC else {
            throw OwnerLeaseRecoveryClaimError.identityChanged
        }
        let currentIdentity = try ownerRecoveryIdentityFromDescriptor(
            descriptor,
            operation: "fstat-owner"
        )
        let pathIdentity = try ownerRecoveryIdentityFromDirectoryEntry(
            directoryDescriptor: directoryDescriptor,
            name: markerName,
            operation: "fstatat-owner"
        )
        guard currentIdentity == pathIdentity,
            currentIdentity.fileType == .regular,
            currentIdentity.permissions == 0o600,
            currentIdentity.size >= 0,
            currentIdentity.size <= 64 * 1024
        else {
            throw OwnerLeaseRecoveryClaimError.identityChanged
        }

        let markerBytes = try ownerRecoveryReadAll(
            descriptor,
            count: Int(currentIdentity.size)
        )
        let finalDescriptorIdentity = try ownerRecoveryIdentityFromDescriptor(
            descriptor,
            operation: "fstat-owner-after-read"
        )
        let finalPathIdentity = try ownerRecoveryIdentityFromDirectoryEntry(
            directoryDescriptor: directoryDescriptor,
            name: markerName,
            operation: "fstatat-owner-after-read"
        )
        guard finalDescriptorIdentity == currentIdentity,
            finalPathIdentity == currentIdentity
        else {
            throw OwnerLeaseRecoveryClaimError.identityChanged
        }

        let markerRecord: FixtureRecoveryMarkerRecord
        do {
            markerRecord = try FixtureRecovery.decodeMarker(markerBytes)
        } catch {
            throw OwnerLeaseRecoveryClaimError.invalidMarker
        }
        let recoveryCheckpoint = OwnerLeaseRecoveryCheckpoint(
            descriptorFlags: descriptorFlags,
            lock: .bsdExclusiveNonblocking,
            markerBytes: markerBytes,
            bytesRead: markerBytes.count,
            recordWasReadThroughRetainedDescriptor: true,
            descriptorIdentity: currentIdentity,
            pathIdentity: currentIdentity,
            pathIdentityWasReadWithFstatat: true,
            closed: nil
        )
        let lease = OwnerLease(
            marker: marker,
            record: markerRecord.preparing,
            identity: currentIdentity,
            checkpoints: nil,
            recoveryCheckpoint: recoveryCheckpoint,
            descriptor: descriptor,
            descriptorClose: descriptorClose,
            beforeReadySynchronization: nil,
            afterDescriptorClose: nil
        )
        transferred = true
        return OwnerLeaseRecoveryClaim(
            lease: lease,
            markerRecord: markerRecord
        )
    }

    package func closeResult() async -> Result<Void, OwnerLeaseCloseError> {
        await closeCoordinator.closeResult()
    }

    package func publishReadyRecord(
        _ recordBytes: [UInt8],
        recoverySidecar: URL? = nil,
        afterReadyRecordSynchronization: @escaping @Sendable () async throws -> Void = {},
        afterRecoverySidecarSynchronization: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> OwnerLeaseReadyCheckpoint {
        try await closeCoordinator.publishReadyRecord(
            recordBytes,
            recoverySidecar: recoverySidecar,
            afterReadyRecordSynchronization: afterReadyRecordSynchronization,
            afterRecoverySidecarSynchronization:
                afterRecoverySidecarSynchronization
        )
    }
}

private enum OwnerLeaseClosePhase: Sendable {
    case open
    case closing(Task<Result<Void, OwnerLeaseCloseError>, Never>)
    case closed(Result<Void, OwnerLeaseCloseError>)
}

private enum OwnerLeaseReadyPhase: Sendable {
    case unpublished
    case publishing(
        Task<
            Result<OwnerLeaseReadyCheckpoint, OwnerLeaseReadyPublicationError>,
            Never
        >
    )
    case published
    case failed
}

private struct OwnerLeaseCloseState: Sendable {
    var closePhase: OwnerLeaseClosePhase = .open
    var readyPhase: OwnerLeaseReadyPhase = .unpublished
    var checkpoints: OwnerLeaseCheckpoints?
    var recoveryCheckpoint: OwnerLeaseRecoveryCheckpoint?
    var descriptorCloseAttemptCount = 0
    var cachedCloseResultCount = 0
    var coalescedCloseResultCount = 0

    mutating func refreshClosedCheckpoint() {
        let closed = OwnerLeaseClosedCheckpoint(
            descriptorCloseAttemptCount: descriptorCloseAttemptCount,
            cachedCloseResultCount: cachedCloseResultCount,
            coalescedCloseResultCount: coalescedCloseResultCount
        )
        if let current = checkpoints {
            checkpoints = OwnerLeaseCheckpoints(
                prepared: current.prepared,
                published: current.published,
                ready: current.ready,
                closed: closed
            )
        }
        if let current = recoveryCheckpoint {
            recoveryCheckpoint = OwnerLeaseRecoveryCheckpoint(
                descriptorFlags: current.descriptorFlags,
                lock: current.lock,
                markerBytes: current.markerBytes,
                bytesRead: current.bytesRead,
                recordWasReadThroughRetainedDescriptor:
                    current.recordWasReadThroughRetainedDescriptor,
                descriptorIdentity: current.descriptorIdentity,
                pathIdentity: current.pathIdentity,
                pathIdentityWasReadWithFstatat:
                    current.pathIdentityWasReadWithFstatat,
                closed: closed
            )
        }
    }
}

private enum OwnerLeaseCloseDecision: Sendable {
    case cached(Result<Void, OwnerLeaseCloseError>)
    case wait(Task<Result<Void, OwnerLeaseCloseError>, Never>)
}

private enum OwnerLeaseReadyDecision: Sendable {
    case reject(OwnerLeaseReadyPublicationError)
    case wait(
        Task<
            Result<OwnerLeaseReadyCheckpoint, OwnerLeaseReadyPublicationError>,
            Never
        >
    )
}

private final class OwnerLeaseCloseCoordinator: Sendable {
    private let marker: URL
    private let descriptor: Int32
    private let descriptorClose: OwnerLeaseDescriptorClose
    private let beforeReadySynchronization: OwnerLeaseBeforeReadySynchronization?
    private let afterDescriptorClose: OwnerLeaseAfterDescriptorClose?

    #if canImport(Darwin)
        private let state: OSAllocatedUnfairLock<OwnerLeaseCloseState>
    #else
        private let state: Mutex<OwnerLeaseCloseState>
    #endif

    init(
        marker: URL,
        descriptor: Int32,
        descriptorClose: @escaping OwnerLeaseDescriptorClose,
        checkpoints: OwnerLeaseCheckpoints?,
        recoveryCheckpoint: OwnerLeaseRecoveryCheckpoint?,
        beforeReadySynchronization: OwnerLeaseBeforeReadySynchronization?,
        afterDescriptorClose: OwnerLeaseAfterDescriptorClose?
    ) {
        self.marker = marker
        self.descriptor = descriptor
        self.descriptorClose = descriptorClose
        self.beforeReadySynchronization = beforeReadySynchronization
        self.afterDescriptorClose = afterDescriptorClose
        #if canImport(Darwin)
            state = OSAllocatedUnfairLock(
                initialState: OwnerLeaseCloseState(
                    checkpoints: checkpoints,
                    recoveryCheckpoint: recoveryCheckpoint
                )
            )
        #else
            state = Mutex(
                OwnerLeaseCloseState(
                    checkpoints: checkpoints,
                    recoveryCheckpoint: recoveryCheckpoint
                )
            )
        #endif
    }

    var checkpoints: OwnerLeaseCheckpoints? {
        state.withLock { $0.checkpoints }
    }

    var recoveryCheckpoint: OwnerLeaseRecoveryCheckpoint? {
        state.withLock { $0.recoveryCheckpoint }
    }

    func publishReadyRecord(
        _ recordBytes: [UInt8],
        recoverySidecar: URL?,
        afterReadyRecordSynchronization: @escaping @Sendable () async throws -> Void,
        afterRecoverySidecarSynchronization: @escaping @Sendable () async throws -> Void
    ) async throws -> OwnerLeaseReadyCheckpoint {
        guard ownerReadyRecordIsCanonical(recordBytes) else {
            throw OwnerLeaseReadyPublicationError.invalidRecord
        }
        let decision = state.withLock { state -> OwnerLeaseReadyDecision in
            guard case .open = state.closePhase else {
                return .reject(.leaseClosing)
            }
            guard case .unpublished = state.readyPhase else {
                return .reject(.readyAlreadyPublished)
            }
            guard let checkpoints = state.checkpoints else {
                return .reject(
                    .invariantViolation(
                        "recovered lease cannot publish a ready record"
                    )
                )
            }
            let preparedIdentity = checkpoints.prepared.descriptorIdentity
            let task = Task { [self] in
                let result:
                    Result<
                        OwnerLeaseReadyCheckpoint,
                        OwnerLeaseReadyPublicationError
                    >
                do {
                    result = .success(
                        try await performReadyPublication(
                            recordBytes,
                            preparedIdentity: preparedIdentity,
                            recoverySidecar: recoverySidecar,
                            afterReadyRecordSynchronization:
                                afterReadyRecordSynchronization,
                            afterRecoverySidecarSynchronization:
                                afterRecoverySidecarSynchronization
                        )
                    )
                } catch let error as OwnerLeaseReadyPublicationError {
                    result = .failure(error)
                } catch {
                    result = .failure(
                        .invariantViolation("unexpected ready publication error")
                    )
                }
                finishReadyPublication(result)
                return result
            }
            state.readyPhase = .publishing(task)
            return .wait(task)
        }

        switch decision {
        case let .reject(error):
            throw error
        case let .wait(task):
            return try await task.value.get()
        }
    }

    func closeResult() async -> Result<Void, OwnerLeaseCloseError> {
        let decision = state.withLock { state -> OwnerLeaseCloseDecision in
            switch state.closePhase {
            case .open:
                let readyPublication:
                    Task<
                        Result<
                            OwnerLeaseReadyCheckpoint,
                            OwnerLeaseReadyPublicationError
                        >,
                        Never
                    >?
                if case let .publishing(task) = state.readyPhase {
                    readyPublication = task
                } else {
                    readyPublication = nil
                }
                let task = Task { [self] in
                    if let readyPublication {
                        _ = await readyPublication.value
                    }
                    let result = descriptorClose(descriptor)
                    noteDescriptorCloseAttempt()
                    if let afterDescriptorClose {
                        await afterDescriptorClose()
                    }
                    return result
                }
                state.closePhase = .closing(task)
                return .wait(task)
            case let .closing(task):
                state.coalescedCloseResultCount += 1
                if state.checkpoints?.closed != nil
                    || state.recoveryCheckpoint?.closed != nil
                {
                    state.refreshClosedCheckpoint()
                }
                return .wait(task)
            case let .closed(result):
                state.cachedCloseResultCount += 1
                state.refreshClosedCheckpoint()
                return .cached(result)
            }
        }

        switch decision {
        case let .cached(result):
            return result
        case let .wait(task):
            let result = await task.value
            state.withLock { state in
                if case .closing = state.closePhase {
                    state.closePhase = .closed(result)
                    state.refreshClosedCheckpoint()
                }
            }
            return result
        }
    }

    private func noteDescriptorCloseAttempt() {
        state.withLock { state in
            state.descriptorCloseAttemptCount += 1
            state.refreshClosedCheckpoint()
        }
    }

    private func performReadyPublication(
        _ recordBytes: [UInt8],
        preparedIdentity: OwnerLeaseIdentity,
        recoverySidecar: URL?,
        afterReadyRecordSynchronization: @escaping @Sendable () async throws -> Void,
        afterRecoverySidecarSynchronization: @escaping @Sendable () async throws -> Void
    ) async throws -> OwnerLeaseReadyCheckpoint {
        let initialDescriptorIdentity = try ownerReadyIdentityFromDescriptor(
            descriptor,
            operation: "fstat-before-ready"
        )
        guard initialDescriptorIdentity == preparedIdentity else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "retained descriptor changed before ready publication"
            )
        }
        let initialPathIdentity = try ownerReadyIdentityFromPath(
            marker,
            operation: "lstat-before-ready"
        )
        guard initialPathIdentity == preparedIdentity else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "marker path changed before ready publication"
            )
        }

        let writeOffset = preparedIdentity.size
        let bytesWritten = try ownerWriteReadyAll(
            descriptor,
            bytes: recordBytes,
            offset: writeOffset
        )
        let expectedSize = writeOffset + Int64(recordBytes.count)
        let writtenIdentity = try ownerReadyIdentityFromDescriptor(
            descriptor,
            operation: "fstat-after-ready-write"
        )
        guard writtenIdentity.device == preparedIdentity.device,
            writtenIdentity.inode == preparedIdentity.inode,
            writtenIdentity.fileType == .regular,
            writtenIdentity.permissions == 0o600,
            writtenIdentity.size == expectedSize
        else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "retained descriptor changed during ready publication"
            )
        }

        if let beforeReadySynchronization {
            await beforeReadySynchronization()
        }
        guard fsync(descriptor) == 0 else {
            throw ownerReadySystemCall("fsync-ready", errno)
        }
        do {
            try await afterReadyRecordSynchronization()
        } catch {
            throw OwnerLeaseReadyPublicationError.checkpointFailure
        }

        let descriptorIdentity = try ownerReadyIdentityFromDescriptor(
            descriptor,
            operation: "fstat-ready"
        )
        let pathIdentity = try ownerReadyIdentityFromPath(
            marker,
            operation: "lstat-ready"
        )
        guard descriptorIdentity == writtenIdentity,
            pathIdentity == descriptorIdentity
        else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "marker path changed during ready publication"
            )
        }
        let sidecarPublication = try publishRecoverySidecar(
            recoverySidecar,
            expectedIdentity: descriptorIdentity
        )
        if sidecarPublication != nil {
            do {
                try await afterRecoverySidecarSynchronization()
            } catch {
                throw OwnerLeaseReadyPublicationError.checkpointFailure
            }
        }
        return OwnerLeaseReadyCheckpoint(
            recordBytes: recordBytes,
            bytesWritten: bytesWritten,
            writeOffset: writeOffset,
            recordWasWrittenThroughRetainedDescriptor: true,
            wasSynchronized: true,
            descriptorIdentity: descriptorIdentity,
            pathIdentity: pathIdentity,
            pathIdentityWasReadWithLstat: true,
            recoverySidecarIdentity: sidecarPublication?.identity,
            recoverySidecarWasLinkedToRetainedDescriptor:
                sidecarPublication != nil,
            recoverySidecarParentSynchronization:
                sidecarPublication?.directorySynchronization
        )
    }

    private func publishRecoverySidecar(
        _ sidecar: URL?,
        expectedIdentity: OwnerLeaseIdentity
    ) throws -> (
        identity: OwnerLeaseIdentity,
        directorySynchronization: OwnerLeaseDirectorySynchronization
    )? {
        guard let sidecar else { return nil }
        let runDirectory = marker.deletingLastPathComponent()
        let parentDirectory = runDirectory.deletingLastPathComponent()
        let runName = runDirectory.lastPathComponent
        let markerName = marker.lastPathComponent
        let sidecarName = sidecar.lastPathComponent
        guard markerName == "owner.json",
            runName.hasPrefix("f-"),
            runName.count > 2,
            sidecar.deletingLastPathComponent() == parentDirectory,
            sidecarName == ".\(runName).owner.json"
        else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "invalid recovery sidecar path"
            )
        }

        let directoryFlags = Int32(
            O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW
        )
        let parentDescriptor = parentDirectory.path.withCString {
            open($0, directoryFlags)
        }
        guard parentDescriptor >= 0 else {
            throw ownerReadySystemCall("open-recovery-parent", errno)
        }
        defer { _ = ownerClose(parentDescriptor) }
        let runDescriptor = runName.withCString {
            openat(parentDescriptor, $0, directoryFlags)
        }
        guard runDescriptor >= 0 else {
            throw ownerReadySystemCall("openat-recovery-run", errno)
        }
        defer { _ = ownerClose(runDescriptor) }

        let innerIdentity = try ownerReadyIdentityFromDirectoryEntry(
            directoryDescriptor: runDescriptor,
            name: markerName,
            operation: "fstatat-owner-before-sidecar"
        )
        guard innerIdentity == expectedIdentity else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "marker changed before recovery sidecar publication"
            )
        }
        do {
            _ = try ownerReadyIdentityFromDirectoryEntry(
                directoryDescriptor: parentDescriptor,
                name: sidecarName,
                operation: "fstatat-recovery-sidecar-vacancy"
            )
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "recovery sidecar already exists"
            )
        } catch let OwnerLeaseReadyPublicationError.systemCall(_, code)
            where code == ENOENT
        {}

        let linkResult = markerName.withCString { inner in
            sidecarName.withCString { journal in
                linkat(
                    runDescriptor,
                    inner,
                    parentDescriptor,
                    journal,
                    0
                )
            }
        }
        guard linkResult == 0 else {
            throw ownerReadySystemCall("linkat-recovery-sidecar", errno)
        }
        let finalInnerIdentity = try ownerReadyIdentityFromDirectoryEntry(
            directoryDescriptor: runDescriptor,
            name: markerName,
            operation: "fstatat-owner-after-sidecar"
        )
        let sidecarIdentity = try ownerReadyIdentityFromDirectoryEntry(
            directoryDescriptor: parentDescriptor,
            name: sidecarName,
            operation: "fstatat-recovery-sidecar"
        )
        guard finalInnerIdentity == expectedIdentity,
            sidecarIdentity == expectedIdentity
        else {
            throw OwnerLeaseReadyPublicationError.invariantViolation(
                "recovery sidecar does not name the retained descriptor inode"
            )
        }
        guard fsync(parentDescriptor) == 0 else {
            throw ownerReadySystemCall("fsync-recovery-parent", errno)
        }
        return (sidecarIdentity, .synchronized)
    }

    private func finishReadyPublication(
        _ result: Result<
            OwnerLeaseReadyCheckpoint,
            OwnerLeaseReadyPublicationError
        >
    ) {
        state.withLock { state in
            switch result {
            case let .success(ready):
                guard let checkpoints = state.checkpoints else {
                    state.readyPhase = .failed
                    return
                }
                state.readyPhase = .published
                state.checkpoints = OwnerLeaseCheckpoints(
                    prepared: checkpoints.prepared,
                    published: checkpoints.published,
                    ready: ready,
                    closed: checkpoints.closed
                )
            case .failure:
                state.readyPhase = .failed
            }
        }
    }

    deinit {
        let descriptorToClose = state.withLock { state -> Int32? in
            guard case .open = state.closePhase else { return nil }
            state.closePhase = .closed(.success(()))
            return descriptor
        }
        if let descriptorToClose {
            _ = descriptorClose(descriptorToClose)
        }
    }
}

private func ownerReadyRecordIsCanonical(_ bytes: [UInt8]) -> Bool {
    guard bytes.last == 0x0A,
        !bytes.dropLast().contains(0x0A),
        !bytes.dropLast().isEmpty
    else {
        return false
    }
    let body = Data(bytes.dropLast())
    do {
        let object = try JSONSerialization.jsonObject(with: body)
        guard object is [String: Any] else { return false }
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return canonical == body
    } catch {
        return false
    }
}

private func ownerReadySystemCall(
    _ operation: String,
    _ code: Int32
) -> OwnerLeaseReadyPublicationError {
    .systemCall(operation: operation, code: code)
}

private func ownerRecoverySystemCall(
    _ operation: String,
    _ code: Int32
) -> OwnerLeaseRecoveryClaimError {
    .systemCall(operation: operation, code: code)
}

private func ownerRecoveryIdentityFromDescriptor(
    _ descriptor: Int32,
    operation: String
) throws -> OwnerLeaseIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw ownerRecoverySystemCall(operation, errno)
    }
    return try ownerRecoveryIdentity(status)
}

private func ownerRecoveryIdentityFromDirectoryEntry(
    directoryDescriptor: Int32,
    name: String,
    operation: String
) throws -> OwnerLeaseIdentity {
    var status = stat()
    let result = name.withCString {
        fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        throw ownerRecoverySystemCall(operation, errno)
    }
    return try ownerRecoveryIdentity(status)
}

private func ownerRecoveryIdentity(
    _ status: stat
) throws -> OwnerLeaseIdentity {
    let mode = UInt32(status.st_mode)
    guard mode & 0o170000 == 0o100000 else {
        throw OwnerLeaseRecoveryClaimError.identityChanged
    }
    return OwnerLeaseIdentity(
        device: UInt64(status.st_dev),
        fileType: .regular,
        inode: UInt64(status.st_ino),
        permissions: UInt16(mode & 0o777),
        size: Int64(status.st_size)
    )
}

private func ownerRecoveryReadAll(
    _ descriptor: Int32,
    count: Int
) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var readCount = 0
    try bytes.withUnsafeMutableBytes { buffer in
        while readCount < buffer.count {
            let result = pread(
                descriptor,
                buffer.baseAddress!.advanced(by: readCount),
                buffer.count - readCount,
                off_t(readCount)
            )
            if result > 0 {
                readCount += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                throw ownerRecoverySystemCall("pread-owner", errno)
            }
        }
    }
    return bytes
}

private func ownerReadyIdentityFromDescriptor(
    _ descriptor: Int32,
    operation: String
) throws -> OwnerLeaseIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw ownerReadySystemCall(operation, errno)
    }
    return try ownerReadyIdentity(from: status)
}

private func ownerReadyIdentityFromPath(
    _ path: URL,
    operation: String
) throws -> OwnerLeaseIdentity {
    var status = stat()
    guard path.path.withCString({ lstat($0, &status) }) == 0 else {
        throw ownerReadySystemCall(operation, errno)
    }
    return try ownerReadyIdentity(from: status)
}

private func ownerReadyIdentityFromDirectoryEntry(
    directoryDescriptor: Int32,
    name: String,
    operation: String
) throws -> OwnerLeaseIdentity {
    var status = stat()
    let result = name.withCString {
        fstatat(directoryDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
        throw ownerReadySystemCall(operation, errno)
    }
    return try ownerReadyIdentity(from: status)
}

private func ownerReadyIdentity(
    from status: stat
) throws -> OwnerLeaseIdentity {
    let mode = UInt32(status.st_mode)
    guard mode & 0o170000 == 0o100000 else {
        throw OwnerLeaseReadyPublicationError.invariantViolation(
            "owner inode is not a regular file"
        )
    }
    return OwnerLeaseIdentity(
        device: UInt64(status.st_dev),
        fileType: .regular,
        inode: UInt64(status.st_ino),
        permissions: UInt16(mode & 0o777),
        size: Int64(status.st_size)
    )
}

private func ownerWriteReadyAll(
    _ descriptor: Int32,
    bytes: [UInt8],
    offset: Int64
) throws -> Int {
    var written = 0
    try bytes.withUnsafeBytes { buffer in
        while written < buffer.count {
            let result = pwrite(
                descriptor,
                buffer.baseAddress!.advanced(by: written),
                buffer.count - written,
                off_t(offset + Int64(written))
            )
            if result > 0 {
                written += result
            } else if result < 0, errno == EINTR {
                continue
            } else {
                let code = result == 0 ? EIO : errno
                throw ownerReadySystemCall("pwrite-ready", code)
            }
        }
    }
    return written
}

private func ownerAcquisitionSystemCall(
    _ operation: String,
    _ code: Int32
) -> OwnerLeaseAcquisitionError {
    .systemCall(operation: operation, code: code)
}

private func ownerIdentityFromDescriptor(
    _ descriptor: Int32
) throws -> OwnerLeaseIdentity {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
        throw ownerAcquisitionSystemCall("fstat", errno)
    }
    return try ownerIdentity(from: status)
}

private func ownerIdentityFromPath(_ path: URL) throws -> OwnerLeaseIdentity {
    var status = stat()
    let result = path.path.withCString { lstat($0, &status) }
    guard result == 0 else {
        throw ownerAcquisitionSystemCall("lstat", errno)
    }
    return try ownerIdentity(from: status)
}

private func ownerIdentity(from status: stat) throws -> OwnerLeaseIdentity {
    let mode = UInt32(status.st_mode)
    guard mode & 0o170000 == 0o100000 else {
        throw OwnerLeaseAcquisitionError.invariantViolation(
            "owner inode is not a regular file"
        )
    }
    return OwnerLeaseIdentity(
        device: UInt64(status.st_dev),
        fileType: .regular,
        inode: UInt64(status.st_ino),
        permissions: UInt16(mode & 0o777),
        size: Int64(status.st_size)
    )
}

private func ownerPathExistsWithoutFollowing(_ path: URL) throws -> Bool {
    var status = stat()
    if path.path.withCString({ lstat($0, &status) }) == 0 {
        return true
    }
    let code = errno
    if code == ENOENT { return false }
    throw ownerAcquisitionSystemCall("lstat-before-publish", code)
}

private func ownerWriteAll(_ descriptor: Int32, bytes: [UInt8]) throws -> Int {
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
                throw ownerAcquisitionSystemCall("write-record", errno)
            }
        }
    }
    return written
}

private func ownerDirectorySynchronizationIsUnsupported(_ code: Int32) -> Bool {
    if code == EINVAL || code == EROFS { return true }
    #if canImport(Darwin)
        return code == ENOTSUP
    #else
        return code == EOPNOTSUPP
    #endif
}

@inline(__always)
private func ownerClose(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}
