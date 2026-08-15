import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

package enum FixtureRecoveryArtifactKind: String, Codable, Sendable, Equatable {
    case directory
    case regular
    case socket
}

package struct FixtureRecoveryArtifactRecord: Codable, Sendable, Equatable {
    package let device: UInt64
    package let inode: UInt64
    package let kind: FixtureRecoveryArtifactKind
    package let path: String
    package let permissions: UInt16

    package init(
        device: UInt64,
        inode: UInt64,
        kind: FixtureRecoveryArtifactKind,
        path: String,
        permissions: UInt16
    ) {
        self.device = device
        self.inode = inode
        self.kind = kind
        self.path = path
        self.permissions = permissions
    }
}

package struct FixtureRecoveryReadyRecord: Codable, Sendable, Equatable {
    package let configurationFile: FixtureRecoveryArtifactRecord
    package let ownershipMarker: FixtureRecoveryArtifactRecord
    package let runDirectory: FixtureRecoveryArtifactRecord
    package let socket: FixtureRecoveryArtifactRecord
    package let socketDirectory: FixtureRecoveryArtifactRecord
    package let state: String
    package let tmuxExecutablePath: String
    package let token: String
    package let version: Int

    package init(
        configurationFile: FixtureRecoveryArtifactRecord,
        ownershipMarker: FixtureRecoveryArtifactRecord,
        runDirectory: FixtureRecoveryArtifactRecord,
        socket: FixtureRecoveryArtifactRecord,
        socketDirectory: FixtureRecoveryArtifactRecord,
        tmuxExecutablePath: String,
        token: UUID
    ) {
        self.configurationFile = configurationFile
        self.ownershipMarker = ownershipMarker
        self.runDirectory = runDirectory
        self.socket = socket
        self.socketDirectory = socketDirectory
        state = "ready"
        self.tmuxExecutablePath = tmuxExecutablePath
        self.token = token.uuidString
        version = 1
    }
}

package struct FixtureRecoveryMarkerRecord: Sendable, Equatable {
    package let preparing: OwnerLeaseRecord
    package let ready: FixtureRecoveryReadyRecord
}

package enum FixtureRecoveryMarkerError: Error, Sendable, Equatable {
    case invalidRecord
}

package struct FixtureRecoveryConfiguration: Sendable {
    package let runDirectory: URL
    package let expectedTmuxExecutable: ProcessExecutable?
    package let childEnvironment: FixtureChildEnvironment
    package let cleanupDeadline: Duration
    package let checkpointInterval: Duration
    package let timing: FixtureLifecycleTiming
    package let checkpoints: FixtureLifecycleCheckpoints
    package let ownerDescriptorClose: OwnerLeaseDescriptorClose

    package init(
        runDirectory: URL,
        expectedTmuxExecutable: ProcessExecutable? = nil,
        childEnvironment: FixtureChildEnvironment,
        cleanupDeadline: Duration,
        checkpointInterval: Duration,
        timing: FixtureLifecycleTiming = FixtureLifecycleTiming(),
        checkpoints: FixtureLifecycleCheckpoints = FixtureLifecycleCheckpoints(),
        ownerDescriptorClose: @escaping OwnerLeaseDescriptorClose = ownerLeaseDescriptorClose
    ) {
        self.runDirectory = runDirectory
        self.expectedTmuxExecutable = expectedTmuxExecutable
        self.childEnvironment = childEnvironment
        self.cleanupDeadline = cleanupDeadline
        self.checkpointInterval = checkpointInterval
        self.timing = timing
        self.checkpoints = checkpoints
        self.ownerDescriptorClose = ownerDescriptorClose
    }
}

package enum FixtureRecoveryPrimaryFailure: Sendable, Equatable {
    case artifactIdentityChanged
    case cleanupStateUnverifiable
    case cleanupFailed(FixtureCleanupError)
    case filesystem(operation: String, code: Int32)
    case invalidMarker
    case invalidRunDirectory
    case invalidTmuxExecutable
    case markerBusy
    case tmuxExecutableMismatch
}

package enum FixtureRecoveryResult: Sendable, Equatable {
    case alreadyAbsent
    case cleaned
}

package enum FixtureRecoveryClosePrimary: Sendable, Equatable {
    case failure(FixtureRecoveryPrimaryFailure)
    case result(FixtureRecoveryResult)
}

package enum FixtureRecoveryError: Error, Sendable, Equatable {
    case artifactIdentityChanged
    case cleanupStateUnverifiable
    case cleanupFailed(FixtureCleanupError)
    case filesystem(operation: String, code: Int32)
    case invalidMarker
    case invalidRunDirectory
    case invalidTmuxExecutable
    case markerBusy
    case ownerCloseFailed(
        primary: FixtureRecoveryClosePrimary,
        close: OwnerLeaseCloseError
    )
    case tmuxExecutableMismatch
}

package enum FixtureRecovery {
    package static func decodeMarker(
        _ markerBytes: [UInt8]
    ) throws -> FixtureRecoveryMarkerRecord {
        guard markerBytes.count <= 64 * 1024,
            markerBytes.last == 0x0A
        else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        var body = markerBytes
        body.removeLast()
        let lines = body.split(
            separator: 0x0A,
            omittingEmptySubsequences: false
        )
        guard lines.count == 2,
            !lines[0].isEmpty,
            !lines[1].isEmpty
        else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }

        let preparingLine = Data([UInt8](lines[0]))
        let readyLine = Data([UInt8](lines[1]))
        let preparing: OwnerLeaseRecord
        let ready: FixtureRecoveryReadyRecord
        do {
            preparing = try JSONDecoder().decode(
                OwnerLeaseRecord.self,
                from: preparingLine
            )
            ready = try JSONDecoder().decode(
                FixtureRecoveryReadyRecord.self,
                from: readyLine
            )
        } catch {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        guard try fixtureCanonicalRecoveryJSON(preparing) == preparingLine,
            try fixtureCanonicalRecoveryJSON(ready) == readyLine,
            fixtureRecoveryMarkerIsValid(
                preparing: preparing,
                ready: ready
            )
        else {
            throw FixtureRecoveryMarkerError.invalidRecord
        }
        return FixtureRecoveryMarkerRecord(
            preparing: preparing,
            ready: ready
        )
    }

    package static func recover(
        configuration: FixtureRecoveryConfiguration,
        transport: any ProcessTransport
    ) async throws -> FixtureRecoveryResult {
        let runDirectory = configuration.runDirectory
        let name = runDirectory.lastPathComponent
        guard runDirectory.isFileURL,
            runDirectory.path.hasPrefix("/"),
            runDirectory.standardizedFileURL.path == runDirectory.path,
            name.hasPrefix("f-"),
            name.count > 2
        else {
            throw FixtureRecoveryError.invalidRunDirectory
        }
        let pins: FixtureRecoveryDirectoryPins
        do {
            pins = try FixtureRecoveryDirectoryPins.acquire(
                runDirectory: runDirectory
            )
        } catch FixtureRecoveryDirectoryPinError.alreadyAbsent {
            return .alreadyAbsent
        } catch FixtureRecoveryDirectoryPinError.identityChanged {
            throw FixtureRecoveryError.artifactIdentityChanged
        } catch let FixtureRecoveryDirectoryPinError.systemCall(operation, code) {
            throw FixtureRecoveryError.filesystem(
                operation: operation,
                code: code
            )
        }

        let marker = runDirectory.appendingPathComponent("owner.json")
        let sidecar = runDirectory.deletingLastPathComponent()
            .appendingPathComponent(".\(name).owner.json")
        let journalClaim: FixtureRecoveryJournalClaimResult
        do {
            journalClaim = try pins.claimRecoveryJournal(
                innerMarker: marker,
                sidecar: sidecar,
                descriptorClose: configuration.ownerDescriptorClose
            )
        } catch OwnerLeaseRecoveryClaimError.markerBusy {
            pins.release()
            throw FixtureRecoveryError.markerBusy
        } catch OwnerLeaseRecoveryClaimError.identityChanged {
            pins.release()
            throw FixtureRecoveryError.artifactIdentityChanged
        } catch OwnerLeaseRecoveryClaimError.invalidMarker {
            pins.release()
            throw FixtureRecoveryError.invalidMarker
        } catch let OwnerLeaseRecoveryClaimError.systemCall(operation, code) {
            pins.release()
            throw FixtureRecoveryError.filesystem(
                operation: operation,
                code: code
            )
        } catch FixtureRecoveryDirectoryPinError.cleanupStateUnverifiable {
            pins.release()
            throw FixtureRecoveryError.cleanupStateUnverifiable
        } catch FixtureRecoveryDirectoryPinError.identityChanged {
            pins.release()
            throw FixtureRecoveryError.artifactIdentityChanged
        } catch FixtureRecoveryDirectoryPinError.released {
            pins.release()
            throw FixtureRecoveryError.artifactIdentityChanged
        } catch let FixtureRecoveryDirectoryPinError.systemCall(operation, code) {
            pins.release()
            throw FixtureRecoveryError.filesystem(
                operation: operation,
                code: code
            )
        } catch {
            pins.release()
            throw error
        }

        switch journalClaim {
        case .absent:
            pins.release()
            return .alreadyAbsent
        case .missingMarkers:
            pins.release()
            throw FixtureRecoveryError.cleanupStateUnverifiable
        case .claimed:
            break
        }
        guard case let .claimed(initialJournalPhase, recoveredClaim) = journalClaim
        else {
            pins.release()
            throw FixtureRecoveryError.cleanupStateUnverifiable
        }
        let ownerLease = recoveredClaim.lease
        let markerRecord = recoveredClaim.markerRecord
        do {
            guard markerRecord.ready.runDirectory.path == runDirectory.path else {
                throw FixtureRecoveryError.artifactIdentityChanged
            }

            if initialJournalPhase == .runRemoved {
                guard
                    pins.validatesRemovedRun(
                        markerRecord,
                        ownerLease: ownerLease
                    )
                else {
                    throw FixtureRecoveryError.artifactIdentityChanged
                }
                do {
                    try pins.removeRecoverySidecar(
                        ownerLease: ownerLease,
                        requireRunAbsent: true
                    )
                } catch let error as FixtureCleanupError {
                    throw FixtureRecoveryError.cleanupFailed(error)
                }
                let closeResult = await ownerLease.closeResult()
                if case let .failure(error) = closeResult {
                    throw FixtureRecoveryError.ownerCloseFailed(
                        primary: .result(.cleaned),
                        close: error
                    )
                }
                pins.release()
                return .cleaned
            }

            var journalPhase = initialJournalPhase
            do {
                try pins.pinSocketDirectory(
                    allowsMissing: journalPhase == .claimed
                )
            } catch FixtureRecoveryDirectoryPinError.cleanupStateUnverifiable {
                throw FixtureRecoveryError.cleanupStateUnverifiable
            } catch FixtureRecoveryDirectoryPinError.identityChanged {
                throw FixtureRecoveryError.artifactIdentityChanged
            } catch FixtureRecoveryDirectoryPinError.released {
                throw FixtureRecoveryError.artifactIdentityChanged
            } catch let FixtureRecoveryDirectoryPinError.systemCall(
                operation,
                code
            ) {
                throw FixtureRecoveryError.filesystem(
                    operation: operation,
                    code: code
                )
            }
            guard
                pins.validates(
                    markerRecord,
                    ownerLease: ownerLease,
                    journalPhase: journalPhase
                )
            else {
                throw FixtureRecoveryError.artifactIdentityChanged
            }
            let tmuxExecutable = ProcessExecutable.path(
                markerRecord.ready.tmuxExecutablePath
            )
            if let expectedTmuxExecutable = configuration.expectedTmuxExecutable {
                guard
                    let expectedPath = fixtureRecoveryExactExecutablePath(
                        expectedTmuxExecutable
                    )
                else {
                    throw FixtureRecoveryError.invalidTmuxExecutable
                }
                guard expectedPath == markerRecord.ready.tmuxExecutablePath else {
                    throw FixtureRecoveryError.tmuxExecutableMismatch
                }
            }
            if journalPhase == .innerOnly {
                do {
                    try pins.repairRecoverySidecar(ownerLease: ownerLease)
                } catch FixtureRecoveryDirectoryPinError.identityChanged {
                    throw FixtureRecoveryError.artifactIdentityChanged
                } catch let FixtureRecoveryDirectoryPinError.systemCall(
                    operation,
                    code
                ) {
                    throw FixtureRecoveryError.filesystem(
                        operation: operation,
                        code: code
                    )
                }
                journalPhase = .unclaimed
                guard
                    pins.validates(
                        markerRecord,
                        ownerLease: ownerLease,
                        journalPhase: journalPhase
                    )
                else {
                    throw FixtureRecoveryError.artifactIdentityChanged
                }
            }

            do {
                return try await cleanupRecoveredFixture(
                    markerRecord: markerRecord,
                    configuration: configuration,
                    tmuxExecutable: tmuxExecutable,
                    transport: transport,
                    ownerLease: ownerLease,
                    pins: pins,
                    journalPhase: journalPhase
                )
            } catch let error as FixtureCleanupError {
                if case let .ownerCloseFailed(closeError) = error {
                    throw FixtureRecoveryError.ownerCloseFailed(
                        primary: .result(.cleaned),
                        close: closeError
                    )
                }
                throw FixtureRecoveryError.cleanupFailed(error)
            }
        } catch let error as FixtureRecoveryError {
            if case .ownerCloseFailed = error {
                pins.release()
                throw error
            }
            let closeResult = await ownerLease.closeResult()
            pins.release()
            if case let .failure(closeError) = closeResult {
                throw FixtureRecoveryError.ownerCloseFailed(
                    primary: .failure(
                        fixtureRecoveryPrimaryFailure(error)
                    ),
                    close: closeError
                )
            }
            throw error
        } catch let error as FixtureCleanupError {
            let primary = FixtureRecoveryError.cleanupFailed(error)
            let closeResult = await ownerLease.closeResult()
            pins.release()
            if case let .failure(closeError) = closeResult {
                throw FixtureRecoveryError.ownerCloseFailed(
                    primary: .failure(.cleanupFailed(error)),
                    close: closeError
                )
            }
            throw primary
        } catch {
            let closeResult = await ownerLease.closeResult()
            pins.release()
            if case let .failure(closeError) = closeResult {
                throw FixtureRecoveryError.ownerCloseFailed(
                    primary: .failure(.invalidMarker),
                    close: closeError
                )
            }
            throw error
        }
    }
}

private func fixtureRecoveryPrimaryFailure(
    _ error: FixtureRecoveryError
) -> FixtureRecoveryPrimaryFailure {
    switch error {
    case .artifactIdentityChanged:
        return .artifactIdentityChanged
    case .cleanupStateUnverifiable:
        return .cleanupStateUnverifiable
    case let .cleanupFailed(cleanupError):
        return .cleanupFailed(cleanupError)
    case let .filesystem(operation, code):
        return .filesystem(operation: operation, code: code)
    case .invalidMarker:
        return .invalidMarker
    case .invalidRunDirectory:
        return .invalidRunDirectory
    case .invalidTmuxExecutable:
        return .invalidTmuxExecutable
    case .markerBusy:
        return .markerBusy
    case .ownerCloseFailed:
        preconditionFailure("owner close failures are already composite")
    case .tmuxExecutableMismatch:
        return .tmuxExecutableMismatch
    }
}

private func fixtureRecoveryExactExecutablePath(
    _ executable: ProcessExecutable
) -> String? {
    guard case let .path(path) = executable,
        fixtureRecoveryPathIsExact(path)
    else {
        return nil
    }
    return path
}

private func fixtureCanonicalRecoveryJSON<Value: Encodable>(
    _ value: Value
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    do {
        return try encoder.encode(value)
    } catch {
        throw FixtureRecoveryMarkerError.invalidRecord
    }
}

private func fixtureRecoveryMarkerIsValid(
    preparing: OwnerLeaseRecord,
    ready: FixtureRecoveryReadyRecord
) -> Bool {
    guard preparing.ownerProcessIdentifier > 0,
        preparing.version == 1,
        ready.state == "ready",
        ready.version == 1,
        let readyToken = UUID(uuidString: ready.token),
        readyToken.uuidString == ready.token,
        readyToken == preparing.token,
        fixtureRecoveryPathIsExact(ready.tmuxExecutablePath)
    else {
        return false
    }

    let runDirectory = URL(
        fileURLWithPath: ready.runDirectory.path,
        isDirectory: true
    )
    guard fixtureRecoveryPathIsExact(ready.runDirectory.path),
        runDirectory.lastPathComponent.hasPrefix("f-"),
        runDirectory.lastPathComponent.count > 2,
        ready.runDirectory.kind == .directory,
        ready.runDirectory.permissions == 0o700,
        ready.runDirectory.inode != 0,
        fixtureRecoveryArtifact(
            ready.configurationFile,
            equals: runDirectory.appendingPathComponent("tmux.conf").path,
            kind: .regular,
            permissions: 0o600
        ),
        fixtureRecoveryArtifact(
            ready.ownershipMarker,
            equals: runDirectory.appendingPathComponent("owner.json").path,
            kind: .regular,
            permissions: 0o600
        ),
        fixtureRecoveryArtifact(
            ready.socketDirectory,
            equals: runDirectory.appendingPathComponent("s").path,
            kind: .directory,
            permissions: 0o700
        ),
        fixtureRecoveryArtifact(
            ready.socket,
            equals: runDirectory.appendingPathComponent("s/s").path,
            kind: .socket,
            permissions: nil
        )
    else {
        return false
    }
    return true
}

private func fixtureRecoveryArtifact(
    _ artifact: FixtureRecoveryArtifactRecord,
    equals expectedPath: String,
    kind: FixtureRecoveryArtifactKind,
    permissions: UInt16?
) -> Bool {
    artifact.path == expectedPath
        && fixtureRecoveryPathIsExact(artifact.path)
        && artifact.kind == kind
        && artifact.inode != 0
        && artifact.permissions & ~UInt16(0o777) == 0
        && (permissions == nil || artifact.permissions == permissions)
}

private func fixtureRecoveryPathIsExact(_ path: String) -> Bool {
    path.hasPrefix("/")
        && URL(fileURLWithPath: path).standardizedFileURL.path == path
}
