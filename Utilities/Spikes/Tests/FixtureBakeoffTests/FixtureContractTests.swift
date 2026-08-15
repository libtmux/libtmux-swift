import Foundation
import Testing

@testable import FixtureBakeoff
@testable import SpikeSupport

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private let incarnationOption = "@libtmux_swift_incarnation"
private let exactTmuxExecutable = ProcessExecutable.path("/opt/libtmux-tests/bin/tmux")
private let inputChildEnvironmentValues = [
    "DEVELOPER_DIR": "/opt/Xcode.app/Contents/Developer",
    "PATH": "/opt/libtmux-tests/bin:/usr/bin",
    "SDKROOT": "/opt/SDKs/Test.sdk",
]
private let inputChildEnvironment = FixtureChildEnvironment(
    path: "/opt/libtmux-tests/bin:/usr/bin",
    temporaryDirectory: "/opt/libtmux-tests/scratch",
    developerDirectory: "/opt/Xcode.app/Contents/Developer",
    sdkRoot: "/opt/SDKs/Test.sdk"
)
// A hang detector, not a latency budget: scripted checkpoints wait on tasks
// that queue behind the rest of the target, and the suite time limit bounds a
// genuine hang.
private let harnessDeadline = Duration.seconds(30)
private let portableUnixSocketPathByteLimit = 103

private enum FixtureContractError: Error, Sendable, Equatable {
    case deadlineNotArmed(Int)
    case missingArgument(String)
    case missingBootstrapSession
    case missingConfiguration
    case missingDeadlineRequest(Int)
    case missingFixture
    case missingSentinel
    case missingSocketPath
    case missingUUID
    case invalidRecoveryMarker
    case pathMetadataUnavailable(path: String, code: Int32)
    case socketBacklogDidNotSaturate
    case systemCall(operation: String, code: Int32)
    case unexpectedDeadline(expected: Duration, actual: Duration)
    case unexpectedRequestCount(expected: Int, actual: Int)
}

private enum FakeCleanupError: Error, Sendable, Equatable {
    case directoryRemovalFailed(path: String, code: Int32)
    case inventoryFailed(path: String)
    case unlinkFailed(path: String, code: Int32)
}

private enum ScriptedProcessError: Error, Sendable, Equatable {
    case checkpointTimedOut(expected: Int, actual: Int)
    case disconnected
    case immediateFailure
    case released
}

private enum ScriptedOutcome: Sendable {
    case failure(ScriptedProcessError)
    case reply(ProcessReply)
}

private actor ManualGate {
    private var isOpen = false
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiterID = 0

    func wait() async throws {
        try Task.checkCancellation()
        if isOpen { return }

        let waiterID = nextWaiterID
        nextWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func cancel(_ waiterID: Int) {
        waiters.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError()
        )
    }
}

private actor UncancellableGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor CompletionProbe {
    private var didComplete = false
    private let gate = AsyncGate()

    var isComplete: Bool { didComplete }

    func markComplete() async {
        didComplete = true
        await gate.open()
    }

    func waitUntilComplete(timeout: Duration = harnessDeadline) async throws {
        try await gate.wait(timeout: timeout)
    }
}

private actor ManualDeadlineHarness {
    private struct Waiter: Sendable {
        let duration: Duration
        let armed = ManualGate()
        let fired = ManualGate()
    }

    private var waiters: [Int: Waiter] = [:]
    private var requestedGates: [Int: AsyncGate] = [:]
    private var nextOrdinal = 1
    private var armedOrdinals: Set<Int> = []
    private var isReleased = false

    func wait(for duration: Duration) async throws {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        let waiter = Waiter(duration: duration)
        waiters[ordinal] = waiter
        let readyRequests = requestedGates.keys.filter { $0 <= ordinal }
        for request in readyRequests {
            if let gate = requestedGates.removeValue(forKey: request) {
                await gate.open()
            }
        }
        if isReleased {
            await waiter.armed.open()
            await waiter.fired.open()
        }
        try await waiter.armed.wait()
        try await waiter.fired.wait()
    }

    func waitUntilRequested(
        _ ordinal: Int,
        duration expected: Duration
    ) async throws {
        if waiters[ordinal] == nil, !isReleased {
            let gate: AsyncGate
            if let existing = requestedGates[ordinal] {
                gate = existing
            } else {
                let created = AsyncGate()
                requestedGates[ordinal] = created
                gate = created
            }
            try await gate.wait(timeout: harnessDeadline)
        }
        guard let waiter = waiters[ordinal] else {
            throw FixtureContractError.missingDeadlineRequest(ordinal)
        }
        guard waiter.duration == expected else {
            throw FixtureContractError.unexpectedDeadline(
                expected: expected,
                actual: waiter.duration
            )
        }
    }

    func arm(_ ordinal: Int) async throws {
        guard let waiter = waiters[ordinal] else {
            throw FixtureContractError.missingDeadlineRequest(ordinal)
        }
        armedOrdinals.insert(ordinal)
        await waiter.armed.open()
    }

    func fire(_ ordinal: Int) async throws {
        guard armedOrdinals.contains(ordinal) else {
            throw FixtureContractError.deadlineNotArmed(ordinal)
        }
        guard let waiter = waiters[ordinal] else {
            throw FixtureContractError.missingDeadlineRequest(ordinal)
        }
        await waiter.fired.open()
    }

    func releaseAll() async {
        guard !isReleased else { return }
        isReleased = true
        for gate in requestedGates.values {
            await gate.open()
        }
        requestedGates.removeAll()
        for waiter in waiters.values {
            await waiter.armed.open()
            await waiter.fired.open()
        }
    }
}

private enum TestLifecycleCheckpoint: Hashable, Sendable {
    case afterConfigurationRemoval
    case afterInitialTokenAcceptance
    case afterReadyRecordSynchronization
    case afterRecoveryClaimSynchronization
    case afterRecoverySidecarRemoval
    case afterRecoverySidecarSynchronization
    case afterRunDirectoryRemoval
    case afterSocketIdentityValidation
    case beforeClaimedSocketDirectoryValidation
    case beforeConfigurationRemoval
    case beforeRecoveryClaim
    case beforeRecoverySidecarRemoval
    case beforeRunDirectoryRemoval
    case beforeSocketDirectoryRemoval
    case cleanupJoinedInFlight
    case cleanupRequested
    case socketLockContended
}

private actor LifecycleCheckpointHarness {
    private let blocking: Set<TestLifecycleCheckpoint>
    private var reached: [TestLifecycleCheckpoint: Int] = [:]
    private var reachedGates: [TestLifecycleCheckpoint: [Int: AsyncGate]] = [:]
    private var releaseGates: [TestLifecycleCheckpoint: ManualGate] = [:]

    init(blocking: Set<TestLifecycleCheckpoint> = []) {
        self.blocking = blocking
    }

    func reach(_ checkpoint: TestLifecycleCheckpoint) async throws {
        reached[checkpoint, default: 0] += 1
        let count = reached[checkpoint, default: 0]
        let readyThresholds = reachedGates[checkpoint, default: [:]].keys
            .filter { $0 <= count }
        for threshold in readyThresholds {
            if let gate = reachedGates[checkpoint]?.removeValue(
                forKey: threshold
            ) {
                await gate.open()
            }
        }
        guard blocking.contains(checkpoint) else { return }
        try await releaseGate(for: checkpoint).wait()
    }

    func waitUntilReached(
        _ checkpoint: TestLifecycleCheckpoint,
        count: Int = 1
    ) async throws {
        if reached[checkpoint, default: 0] >= count { return }
        try await reachedGate(for: checkpoint, count: count).wait(
            timeout: harnessDeadline
        )
        guard reached[checkpoint, default: 0] >= count else {
            throw ScriptedProcessError.checkpointTimedOut(
                expected: count,
                actual: reached[checkpoint, default: 0]
            )
        }
    }

    func release(_ checkpoint: TestLifecycleCheckpoint) async {
        await releaseGate(for: checkpoint).open()
    }

    func releaseAll() async {
        for gate in releaseGates.values {
            await gate.open()
        }
    }

    func reachedCount(_ checkpoint: TestLifecycleCheckpoint) -> Int {
        reached[checkpoint, default: 0]
    }

    private func reachedGate(
        for checkpoint: TestLifecycleCheckpoint,
        count: Int
    ) -> AsyncGate {
        if let gate = reachedGates[checkpoint]?[count] { return gate }
        let gate = AsyncGate()
        reachedGates[checkpoint, default: [:]][count] = gate
        return gate
    }

    private func releaseGate(for checkpoint: TestLifecycleCheckpoint) -> ManualGate {
        if let gate = releaseGates[checkpoint] { return gate }
        let gate = ManualGate()
        releaseGates[checkpoint] = gate
        return gate
    }
}

private actor ScriptedProcessTransport: ProcessTransport {
    private let checkpointDeadline: Duration
    private let heldCancellations: Set<Int>
    private var outcomes: [ScriptedOutcome]
    private var observedRequests: [ProcessRequest] = []
    private var checkpointGates: [Int: AsyncGate] = [:]
    private var cancelledRequests: Set<Int> = []
    private var cancellationGates: [Int: AsyncGate] = [:]
    private var cancellationReleaseGates: [Int: UncancellableGate] = [:]
    private var outcomeGate = ManualGate()
    private var isReleased = false

    init(
        outcomes: [ScriptedOutcome] = [],
        checkpointDeadline: Duration = harnessDeadline,
        holdCancellationAt heldCancellations: Set<Int> = []
    ) {
        self.outcomes = outcomes
        self.checkpointDeadline = checkpointDeadline
        self.heldCancellations = heldCancellations
    }

    var snapshot: [ProcessRequest] { observedRequests }

    func run(_ request: ProcessRequest) async throws -> ProcessReply {
        observedRequests.append(request)
        let ordinal = observedRequests.count
        let readyCheckpoints = checkpointGates.keys.filter { $0 <= ordinal }
        for checkpoint in readyCheckpoints {
            if let gate = checkpointGates.removeValue(forKey: checkpoint) {
                await gate.open()
            }
        }
        if heldCancellations.contains(ordinal) {
            _ = cancellationReleaseGate(for: ordinal)
        }

        while outcomes.isEmpty {
            if isReleased {
                throw ScriptedProcessError.released
            }
            let gate = outcomeGate
            do {
                try await gate.wait()
            } catch is CancellationError {
                cancelledRequests.insert(ordinal)
                if let cancellationGate = cancellationGates.removeValue(
                    forKey: ordinal
                ) {
                    await cancellationGate.open()
                }
                if heldCancellations.contains(ordinal) {
                    await cancellationReleaseGate(for: ordinal).wait()
                }
                throw CancellationError()
            }
        }

        switch outcomes.removeFirst() {
        case let .failure(error):
            throw error
        case let .reply(reply):
            return reply
        }
    }

    func enqueue(_ outcome: ScriptedOutcome) async {
        outcomes.append(outcome)
        let gate = outcomeGate
        outcomeGate = ManualGate()
        await gate.open()
    }

    func enqueue(_ newOutcomes: [ScriptedOutcome]) async {
        for outcome in newOutcomes {
            await enqueue(outcome)
        }
    }

    func checkpoint(after count: Int) async throws -> [ProcessRequest] {
        if observedRequests.count < count, !isReleased {
            let gate: AsyncGate
            if let existing = checkpointGates[count] {
                gate = existing
            } else {
                let newGate = AsyncGate()
                checkpointGates[count] = newGate
                gate = newGate
            }
            do {
                try await gate.wait(timeout: checkpointDeadline)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ScriptedProcessError.checkpointTimedOut(
                    expected: count,
                    actual: observedRequests.count
                )
            }
        }

        guard observedRequests.count >= count else {
            throw FixtureContractError.unexpectedRequestCount(
                expected: count,
                actual: observedRequests.count
            )
        }
        return Array(observedRequests.prefix(count))
    }

    func waitUntilRequestCancelled(_ ordinal: Int) async throws {
        if cancelledRequests.contains(ordinal) { return }
        let gate: AsyncGate
        if let existing = cancellationGates[ordinal] {
            gate = existing
        } else {
            let newGate = AsyncGate()
            cancellationGates[ordinal] = newGate
            gate = newGate
        }
        try await gate.wait(timeout: checkpointDeadline)
        guard cancelledRequests.contains(ordinal) else {
            throw ScriptedProcessError.checkpointTimedOut(
                expected: ordinal,
                actual: cancelledRequests.count
            )
        }
    }

    func wasRequestCancelled(_ ordinal: Int) -> Bool {
        cancelledRequests.contains(ordinal)
    }

    func releaseRequestCancellation(_ ordinal: Int) async {
        await cancellationReleaseGate(for: ordinal).open()
    }

    func releaseAll() async {
        guard !isReleased else { return }
        isReleased = true
        let pendingCheckpoints = checkpointGates.values
        checkpointGates.removeAll()
        for gate in pendingCheckpoints {
            await gate.open()
        }
        for gate in cancellationGates.values {
            await gate.open()
        }
        cancellationGates.removeAll()
        for gate in cancellationReleaseGates.values {
            await gate.open()
        }
        await outcomeGate.open()
    }

    private func cancellationReleaseGate(for ordinal: Int) -> UncancellableGate {
        if let gate = cancellationReleaseGates[ordinal] { return gate }
        let gate = UncancellableGate()
        cancellationReleaseGates[ordinal] = gate
        return gate
    }
}

private final class FakeOnlyCleanupScope {
    let runRoot: URL

    init() throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        runRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("lf-\(suffix)")
        try FileManager.default.createDirectory(
            at: runRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func finish() {
        do {
            var files: [URL] = []
            var directories = [runRoot]
            try inventory(
                directory: runRoot,
                files: &files,
                directories: &directories
            )
            for file in files {
                if unlink(file.path) != 0, errno != ENOENT {
                    throw FakeCleanupError.unlinkFailed(
                        path: file.path,
                        code: Int32(errno)
                    )
                }
            }
            for directory in directories.sorted(by: {
                $0.pathComponents.count > $1.pathComponents.count
            }) {
                if rmdir(directory.path) != 0, errno != ENOENT {
                    throw FakeCleanupError.directoryRemovalFailed(
                        path: directory.path,
                        code: Int32(errno)
                    )
                }
            }
        } catch {
            Issue.record("fake-only filesystem cleanup failed: \(error)")
        }
    }

    private func inventory(
        directory: URL,
        files: inout [URL],
        directories: inout [URL]
    ) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw FakeCleanupError.inventoryFailed(path: directory.path)
        }
        for child in children {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            if values.isDirectory == true, values.isSymbolicLink != true {
                directories.append(child)
                try inventory(
                    directory: child,
                    files: &files,
                    directories: &directories
                )
            } else {
                files.append(child)
            }
        }
    }
}

private actor FixtureCapture {
    private var capturedFixture: TmuxFixture?
    private let capturedGate = AsyncGate()

    func record(_ fixture: TmuxFixture) async {
        capturedFixture = fixture
        await capturedGate.open()
    }

    func wait() async throws -> TmuxFixture {
        try await capturedGate.wait(timeout: .seconds(30))
        guard let capturedFixture else {
            throw FixtureContractError.missingFixture
        }
        return capturedFixture
    }
}

private actor CleanupFailureRecorder {
    private var recordedErrors: [FixtureCleanupError] = []

    var errors: [FixtureCleanupError] { recordedErrors }

    func record(_ error: FixtureCleanupError) {
        recordedErrors.append(error)
    }
}

private enum PrimaryFixtureError: Error, Sendable, Equatable {
    case body
}

enum InvalidStartupToken: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case mismatched
    case missing

    var testDescription: String { rawValue }
}

enum CleanupUncertainty: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case disconnect
    case mismatch
    case transportFailure

    var testDescription: String { rawValue }
}

enum EndpointPollUncertainty: String, CaseIterable, Equatable, Sendable,
    CustomTestStringConvertible
{
    case deadline
    case transportFailure

    var testDescription: String { rawValue }
}

enum InvalidCleanupResult: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case extraSentinel
    case failingResult
    case malformedSentinel
    case whitespaceOnlyOutput

    var testDescription: String { rawValue }
}

enum RecoveryJournalPublicationPhase: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case readyRecordSynchronized
    case sidecarSynchronized

    var testDescription: String { rawValue }

    fileprivate var checkpoint: TestLifecycleCheckpoint {
        switch self {
        case .readyRecordSynchronized:
            return .afterReadyRecordSynchronization
        case .sidecarSynchronized:
            return .afterRecoverySidecarSynchronization
        }
    }
}

enum RecoveryJournalCleanupPhase: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case claimed
    case configurationRemoved
    case runRemoved
    case sidecarRemoved

    var testDescription: String { rawValue }

    fileprivate var checkpoint: TestLifecycleCheckpoint {
        switch self {
        case .claimed:
            return .afterRecoveryClaimSynchronization
        case .configurationRemoved:
            return .afterConfigurationRemoval
        case .runRemoved:
            return .afterRunDirectoryRemoval
        case .sidecarRemoved:
            return .afterRecoverySidecarRemoval
        }
    }
}

enum RecoveryJournalReplacementPhase: String, CaseIterable, Sendable,
    CustomTestStringConvertible
{
    case configuration
    case innerMarker
    case runDirectory
    case sidecar

    var testDescription: String { rawValue }

    fileprivate var checkpoint: TestLifecycleCheckpoint {
        switch self {
        case .configuration:
            return .beforeConfigurationRemoval
        case .innerMarker:
            return .beforeRecoveryClaim
        case .runDirectory:
            return .beforeRunDirectoryRemoval
        case .sidecar:
            return .beforeRecoverySidecarRemoval
        }
    }
}

private struct CleanupSentinels: Sendable, Equatable {
    let mismatch: String
}

private struct CandidateArtifacts: Sendable {
    let configurationFile: URL
    let ownershipMarker: URL
    let runDirectory: URL
    let socketDirectory: URL
    let socketPath: String
}

private struct PathIdentity: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
}

private struct RecoveryReadyArtifact: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let kind: String
    let path: String
    let permissions: UInt16
}

private struct RecoveryReadyRecord: Codable, Sendable, Equatable {
    let configurationFile: RecoveryReadyArtifact
    let ownershipMarker: RecoveryReadyArtifact
    let runDirectory: RecoveryReadyArtifact
    let socket: RecoveryReadyArtifact
    let socketDirectory: RecoveryReadyArtifact
    let state: String
    let tmuxExecutablePath: String
    let token: String
    let version: Int
}

private struct PreservedFixtureArtifacts: Sendable {
    let configurationBytes: Data
    let configurationIdentity: PathIdentity
    let endpointIdentity: PathIdentity
    let markerIdentity: PathIdentity
    let ownershipToken: UUID
    let runDirectoryIdentity: PathIdentity
    let socketDirectoryIdentity: PathIdentity
}

private func makeConfiguration(
    runRoot: URL,
    childEnvironment: FixtureChildEnvironment = inputChildEnvironment,
    startupDeadline: Duration = .seconds(2),
    cleanupDeadline: Duration = .seconds(2),
    checkpointHarness: LifecycleCheckpointHarness? = nil,
    deadlineHarness: ManualDeadlineHarness = ManualDeadlineHarness(),
    timing: FixtureLifecycleTiming? = nil
) -> FixtureConfiguration {
    FixtureConfiguration(
        runRoot: runRoot,
        tmuxExecutable: exactTmuxExecutable,
        childEnvironment: childEnvironment,
        startupDeadline: startupDeadline,
        cleanupDeadline: cleanupDeadline,
        checkpointInterval: .milliseconds(1),
        timing: timing
            ?? FixtureLifecycleTiming(
                waitForDeadline: { duration in
                    try await deadlineHarness.wait(for: duration)
                }
            ),
        checkpoints: FixtureLifecycleCheckpoints(
            afterConfigurationRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.afterConfigurationRemoval)
                }
            },
            afterInitialTokenAcceptance: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.afterInitialTokenAcceptance)
                }
            },
            afterReadyRecordSynchronization: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(
                        .afterReadyRecordSynchronization
                    )
                }
            },
            afterRecoveryClaimSynchronization: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(
                        .afterRecoveryClaimSynchronization
                    )
                }
            },
            afterRecoverySidecarRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(
                        .afterRecoverySidecarRemoval
                    )
                }
            },
            afterRecoverySidecarSynchronization: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(
                        .afterRecoverySidecarSynchronization
                    )
                }
            },
            afterRunDirectoryRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.afterRunDirectoryRemoval)
                }
            },
            afterSocketIdentityValidation: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.afterSocketIdentityValidation)
                }
            },
            beforeClaimedSocketDirectoryValidation: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(
                        .beforeClaimedSocketDirectoryValidation
                    )
                }
            },
            beforeConfigurationRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.beforeConfigurationRemoval)
                }
            },
            beforeRecoveryClaim: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.beforeRecoveryClaim)
                }
            },
            beforeRecoverySidecarRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.beforeRecoverySidecarRemoval)
                }
            },
            beforeRunDirectoryRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.beforeRunDirectoryRemoval)
                }
            },
            beforeSocketDirectoryRemoval: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.beforeSocketDirectoryRemoval)
                }
            },
            cleanupRequested: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.cleanupRequested)
                }
            },
            cleanupJoinedInFlight: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.cleanupJoinedInFlight)
                }
            },
            socketLockContended: {
                if let checkpointHarness {
                    try await checkpointHarness.reach(.socketLockContended)
                }
            }
        )
    )
}

private func pathIdentity(of url: URL) throws -> PathIdentity {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else {
        throw FixtureContractError.pathMetadataUnavailable(
            path: url.path,
            code: Int32(errno)
        )
    }
    return PathIdentity(
        device: UInt64(truncatingIfNeeded: metadata.st_dev),
        inode: UInt64(truncatingIfNeeded: metadata.st_ino)
    )
}

private func replaceRegularFile(
    at path: URL,
    displacedTo displaced: URL
) throws -> PathIdentity {
    let bytes = try Data(contentsOf: path)
    guard rename(path.path, displaced.path) == 0 else {
        throw FixtureContractError.systemCall(
            operation: "rename-journal-artifact-for-replacement",
            code: Int32(errno)
        )
    }
    try bytes.write(to: path, options: .withoutOverwriting)
    guard chmod(path.path, 0o600) == 0 else {
        throw FixtureContractError.systemCall(
            operation: "chmod-journal-artifact-replacement",
            code: Int32(errno)
        )
    }
    return try pathIdentity(of: path)
}

private func recoveryMarkerLines(at marker: URL) throws -> [Data] {
    let bytes = try Data(contentsOf: marker)
    guard bytes.last == 0x0A else {
        throw FixtureContractError.invalidRecoveryMarker
    }
    var bytesWithoutTerminator = [UInt8](bytes)
    bytesWithoutTerminator.removeLast()
    return bytesWithoutTerminator.split(
        separator: 0x0A,
        omittingEmptySubsequences: false
    ).map { Data([UInt8]($0)) }
}

private func expectRecoveryArtifact(
    _ artifact: RecoveryReadyArtifact,
    at path: URL,
    kind: String
) throws {
    var metadata = stat()
    guard lstat(path.path, &metadata) == 0 else {
        throw FixtureContractError.pathMetadataUnavailable(
            path: path.path,
            code: Int32(errno)
        )
    }
    #expect(artifact.path == path.path)
    #expect(artifact.device == UInt64(metadata.st_dev))
    #expect(artifact.inode == UInt64(metadata.st_ino))
    #expect(artifact.kind == kind)
    #expect(artifact.permissions == UInt16(UInt32(metadata.st_mode) & 0o777))
}

private func directory(
    in parent: URL,
    matching identity: PathIdentity
) throws -> URL {
    let entries = try FileManager.default.contentsOfDirectory(
        at: parent,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    let matches = try entries.filter { entry in
        let values = try entry.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        return try values.isDirectory == true
            && values.isSymbolicLink != true
            && pathIdentity(of: entry) == identity
    }
    guard matches.count == 1, let match = matches.first else {
        throw FixtureContractError.missingConfiguration
    }
    return match
}

private func preservedArtifacts(
    for fixture: TmuxFixture
) throws -> PreservedFixtureArtifacts {
    PreservedFixtureArtifacts(
        configurationBytes: try Data(contentsOf: fixture.configurationFile),
        configurationIdentity: try pathIdentity(of: fixture.configurationFile),
        endpointIdentity: try pathIdentity(
            of: URL(fileURLWithPath: socketPath(of: fixture))
        ),
        markerIdentity: try pathIdentity(of: fixture.ownershipMarker),
        ownershipToken: fixture.ownershipRecord.token,
        runDirectoryIdentity: try pathIdentity(of: fixture.runDirectory),
        socketDirectoryIdentity: try pathIdentity(of: fixture.socketDirectory)
    )
}

private func expectPreservedArtifacts(
    _ expected: PreservedFixtureArtifacts,
    fixture: TmuxFixture
) throws {
    #expect(
        try Data(contentsOf: fixture.configurationFile)
            == expected.configurationBytes
    )
    #expect(
        try pathIdentity(of: fixture.configurationFile)
            == expected.configurationIdentity
    )
    #expect(
        try pathIdentity(of: URL(fileURLWithPath: socketPath(of: fixture)))
            == expected.endpointIdentity
    )
    #expect(
        try pathIdentity(of: fixture.ownershipMarker)
            == expected.markerIdentity
    )
    #expect(fixture.ownershipRecord.token == expected.ownershipToken)
    #expect(fixture.incarnation.token == expected.ownershipToken)
    #expect(fixture.ownershipRecord.marker == fixture.ownershipMarker)
    #expect(
        try pathIdentity(of: fixture.runDirectory)
            == expected.runDirectoryIdentity
    )
    #expect(
        try pathIdentity(of: fixture.socketDirectory)
            == expected.socketDirectoryIdentity
    )
}

private func expectPostClaimPreservedArtifacts(
    _ expected: PreservedFixtureArtifacts,
    fixture: TmuxFixture,
    endpointIdentity: PathIdentity
) throws {
    #expect(
        try Data(contentsOf: fixture.configurationFile)
            == expected.configurationBytes
    )
    #expect(
        try pathIdentity(of: fixture.configurationFile)
            == expected.configurationIdentity
    )
    #expect(
        try pathIdentity(of: URL(fileURLWithPath: socketPath(of: fixture)))
            == endpointIdentity
    )
    try expectLockedRecoverySidecar(
        for: fixture,
        expectedIdentity: expected.markerIdentity
    )
    #expect(fixture.ownershipRecord.token == expected.ownershipToken)
    #expect(fixture.incarnation.token == expected.ownershipToken)
    #expect(fixture.ownershipRecord.marker == fixture.ownershipMarker)
    #expect(
        try pathIdentity(of: fixture.runDirectory)
            == expected.runDirectoryIdentity
    )
    #expect(
        try pathIdentity(of: fixture.socketDirectory)
            == expected.socketDirectoryIdentity
    )
}

private func emittedChildEnvironment(
    temporaryDirectory: String = inputChildEnvironment.temporaryDirectory,
    input: [String: String] = inputChildEnvironmentValues
) -> [String: String] {
    input.merging([
        "LC_ALL": "C",
        "TMPDIR": temporaryDirectory,
    ]) { _, emitted in emitted }
}

private func processReply(
    standardOutput: String = "",
    standardError: String = "",
    exitCode: Int32 = 0
) -> ProcessReply {
    ProcessReply(
        standardOutput: Array(standardOutput.utf8),
        standardError: Array(standardError.utf8),
        termination: .exited(exitCode)
    )
}

private func argument(after flag: String, in request: ProcessRequest) throws -> String {
    guard let index = request.arguments.firstIndex(of: flag),
        request.arguments.indices.contains(index + 1)
    else {
        throw FixtureContractError.missingArgument(flag)
    }
    return request.arguments[index + 1]
}

private func UUIDs(in text: String) -> Set<UUID> {
    Set(
        text.split { character in
            !(character.isHexDigit || character == "-")
        }
        .compactMap { UUID(uuidString: String($0)) }
    )
}

private func configurationURL(from request: ProcessRequest) throws -> URL {
    URL(fileURLWithPath: try argument(after: "-f", in: request))
}

private func configurationText(from request: ProcessRequest) throws -> String {
    try String(contentsOf: configurationURL(from: request), encoding: .utf8)
}

private func candidateToken(from request: ProcessRequest) throws -> UUID {
    let candidates = UUIDs(in: try configurationText(from: request))
    guard candidates.count == 1, let candidate = candidates.first else {
        throw FixtureContractError.missingUUID
    }
    return candidate
}

private func bootstrapSession(from configuration: String) throws -> String {
    for line in configuration.split(separator: "\n") {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.first == "new-session",
            let nameFlag = fields.firstIndex(of: "-s"),
            fields.indices.contains(nameFlag + 1)
        else {
            continue
        }
        return fields[nameFlag + 1]
    }
    throw FixtureContractError.missingBootstrapSession
}

private func socketPath(of fixture: TmuxFixture) throws -> String {
    switch fixture.endpoint {
    case let .socketPath(path):
        return path
    case .socketName:
        throw FixtureContractError.missingSocketPath
    }
}

private func recoverySidecar(for fixture: TmuxFixture) -> URL {
    fixture.runDirectory.deletingLastPathComponent()
        .appendingPathComponent(
            ".\(fixture.runDirectory.lastPathComponent).owner.json"
        )
}

private func candidateArtifacts(from request: ProcessRequest) throws -> CandidateArtifacts {
    let configurationFile = try configurationURL(from: request)
    let runDirectory = configurationFile.deletingLastPathComponent()
    let socketPath = try argument(after: "-S", in: request)
    let socketDirectory = URL(fileURLWithPath: socketPath)
        .deletingLastPathComponent()
    let entries = try FileManager.default.contentsOfDirectory(
        at: runDirectory,
        includingPropertiesForKeys: [.isDirectoryKey]
    )
    let markerCandidates = try entries.filter { entry in
        if entry == configurationFile { return false }
        return try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true
    }
    guard markerCandidates.count == 1, let ownershipMarker = markerCandidates.first else {
        throw FixtureContractError.missingConfiguration
    }
    return CandidateArtifacts(
        configurationFile: configurationFile,
        ownershipMarker: ownershipMarker,
        runDirectory: runDirectory,
        socketDirectory: socketDirectory,
        socketPath: socketPath
    )
}

private func materializeCandidateSocket(
    from request: ProcessRequest
) throws -> CandidateArtifacts {
    let candidate = try candidateArtifacts(from: request)
    try createUnixSocketArtifact(at: candidate.socketPath)
    return candidate
}

private func createUnixSocketArtifact(at path: String) throws {
    let descriptor = try bindUnixSocketArtifact(at: path)
    _ = close(descriptor)
}

private func createListeningUnixSocketArtifact(at path: String) throws -> Int32 {
    let descriptor = try bindUnixSocketArtifact(at: path)
    guard listen(descriptor, 1) == 0 else {
        let code = Int32(errno)
        _ = close(descriptor)
        throw FixtureContractError.systemCall(
            operation: "listen",
            code: code
        )
    }
    return descriptor
}

private struct SaturatedUnixListener {
    let clients: [Int32]
    let descriptor: Int32

    func closeAll() {
        for client in clients {
            _ = close(client)
        }
        _ = close(descriptor)
    }

    func releaseOneConnection() throws {
        let accepted = accept(descriptor, nil, nil)
        guard accepted >= 0 else {
            throw FixtureContractError.systemCall(
                operation: "accept-saturated-listener",
                code: Int32(errno)
            )
        }
        _ = close(accepted)
    }
}

private func createSaturatedUnixListener(
    at path: String
) throws -> SaturatedUnixListener {
    let listener = try bindUnixSocketArtifact(at: path)
    guard listen(listener, 0) == 0 else {
        let code = Int32(errno)
        _ = close(listener)
        throw FixtureContractError.systemCall(
            operation: "listen-saturated",
            code: code
        )
    }

    var clients: [Int32] = []
    do {
        for _ in 0..<64 {
            #if canImport(Darwin)
                let socketType = SOCK_STREAM
            #else
                let socketType = Int32(SOCK_STREAM.rawValue)
            #endif
            let client = socket(AF_UNIX, socketType, 0)
            guard client >= 0 else {
                throw FixtureContractError.systemCall(
                    operation: "socket-saturation-client",
                    code: Int32(errno)
                )
            }
            let flags = fcntl(client, F_GETFL)
            guard
                flags >= 0,
                fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0,
                fcntl(client, F_SETFD, FD_CLOEXEC) == 0
            else {
                let code = Int32(errno)
                _ = close(client)
                throw FixtureContractError.systemCall(
                    operation: "fcntl-saturation-client",
                    code: code
                )
            }

            let result = try connectUnixSocket(client, path: path)
            if result == 0 {
                clients.append(client)
                continue
            }
            let code = Int32(errno)
            _ = close(client)
            if code == EAGAIN || code == EWOULDBLOCK
                || code == EINPROGRESS || code == EALREADY
            {
                return SaturatedUnixListener(
                    clients: clients,
                    descriptor: listener
                )
            }
            throw FixtureContractError.systemCall(
                operation: "connect-saturation-client",
                code: code
            )
        }
        throw FixtureContractError.socketBacklogDidNotSaturate
    } catch {
        for client in clients {
            _ = close(client)
        }
        _ = close(listener)
        throw error
    }
}

private func connectUnixSocket(_ descriptor: Int32, path: String) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let pathBytes = Array(path.utf8) + [UInt8(0)]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw FixtureContractError.systemCall(
            operation: "socket-path",
            code: Int32(ENAMETOOLONG)
        )
    }
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: pathBytes)
    }
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
}

private func bindUnixSocketArtifact(at path: String) throws -> Int32 {
    #if canImport(Darwin)
        let socketType = SOCK_STREAM
    #else
        let socketType = Int32(SOCK_STREAM.rawValue)
    #endif
    let descriptor = socket(AF_UNIX, socketType, 0)
    guard descriptor >= 0 else {
        throw FixtureContractError.systemCall(
            operation: "socket",
            code: Int32(errno)
        )
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    let pathBytes = Array(path.utf8) + [UInt8(0)]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        _ = close(descriptor)
        throw FixtureContractError.systemCall(
            operation: "socket-path",
            code: Int32(ENAMETOOLONG)
        )
    }
    withUnsafeMutableBytes(of: &address.sun_path) { storage in
        storage.copyBytes(from: pathBytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else {
        let code = Int32(errno)
        _ = close(descriptor)
        throw FixtureContractError.systemCall(
            operation: "bind",
            code: code
        )
    }
    return descriptor
}

private func acquireTestSocketLock(at path: String) throws -> Int32 {
    let descriptor = path.withCString {
        open(
            $0,
            Int32(O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK),
            mode_t(0o600)
        )
    }
    guard descriptor >= 0 else {
        throw FixtureContractError.systemCall(
            operation: "open-test-socket-lock",
            code: Int32(errno)
        )
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
        let code = Int32(errno)
        _ = close(descriptor)
        throw FixtureContractError.systemCall(
            operation: "fchmod-test-socket-lock",
            code: code
        )
    }
    guard testFlock(descriptor, Int32(LOCK_EX | LOCK_NB)) == 0 else {
        let code = Int32(errno)
        _ = close(descriptor)
        throw FixtureContractError.systemCall(
            operation: "flock-test-socket-lock",
            code: code
        )
    }
    return descriptor
}

private func releaseTestSocketLock(_ descriptor: Int32) {
    _ = testFlock(descriptor, Int32(LOCK_UN))
    _ = close(descriptor)
}

private func markerLockIsBusy(at marker: URL) throws -> Bool {
    let descriptor = open(
        marker.path,
        O_RDWR | O_CLOEXEC | O_NOFOLLOW
    )
    guard descriptor >= 0 else {
        throw FixtureContractError.systemCall(
            operation: "open-owner-journal",
            code: Int32(errno)
        )
    }
    defer { _ = close(descriptor) }
    if testFlock(descriptor, Int32(LOCK_EX | LOCK_NB)) == 0 {
        _ = testFlock(descriptor, Int32(LOCK_UN))
        return false
    }
    guard errno == EAGAIN || errno == EWOULDBLOCK else {
        throw FixtureContractError.systemCall(
            operation: "flock-owner-journal",
            code: Int32(errno)
        )
    }
    return true
}

private func expectLockedRecoverySidecar(
    for fixture: TmuxFixture,
    expectedIdentity: PathIdentity
) throws {
    let sidecar = recoverySidecar(for: fixture)
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.ownershipMarker.path
        )
    )
    #expect(try pathIdentity(of: sidecar) == expectedIdentity)
    #expect(try markerLockIsBusy(at: sidecar))
}

private func testFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
    #if canImport(Darwin)
        Darwin.flock(descriptor, operation)
    #else
        linuxTestFlock(descriptor, operation)
    #endif
}

#if !canImport(Darwin)
    @_silgen_name("flock")
    private func linuxTestFlock(_ descriptor: Int32, _ operation: Int32) -> Int32
#endif

private func posixMode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw FixtureContractError.missingConfiguration
    }
    return permissions.intValue & 0o777
}

private func printedSentinel(in branch: String) throws -> String {
    let fields = branch.split { character in
        character.isWhitespace
            || character == "'"
            || character == "\""
            || character == ";"
            || character == "\\"
    }
    guard let command = fields.firstIndex(of: "display-message"),
        fields.indices.contains(command + 2),
        fields[command + 1] == "-p"
    else {
        throw FixtureContractError.missingSentinel
    }
    return String(fields[command + 2])
}

private func cleanupSentinels(
    in request: ProcessRequest,
    fixture: TmuxFixture,
    inputEnvironment: [String: String] = inputChildEnvironmentValues,
    temporaryDirectory: String = inputChildEnvironment.temporaryDirectory
) throws -> CleanupSentinels {
    let socket = try socketPath(of: fixture)
    #expect(request.executable == exactTmuxExecutable)
    #expect(
        request.environment
            == emittedChildEnvironment(
                temporaryDirectory: temporaryDirectory,
                input: inputEnvironment
            )
    )
    #expect(request.workingDirectory == nil)
    #expect(request.outputPolicy == .complete)
    #expect(request.arguments.count == 8)
    guard request.arguments.count == 8 else {
        throw FixtureContractError.unexpectedRequestCount(
            expected: 8,
            actual: request.arguments.count
        )
    }
    #expect(Array(request.arguments.prefix(5)) == ["-N", "-S", socket, "if-shell", "-F"])
    #expect(
        request.arguments[5]
            == "#{==:#{\(incarnationOption)},\(fixture.incarnation.token.uuidString)}"
    )

    let matchingBranch = request.arguments[6]
    let mismatchingBranch = request.arguments[7]
    let mismatch = try printedSentinel(in: mismatchingBranch)
    #expect(matchingBranch == "kill-server")
    #expect(mismatchingBranch == "display-message -p \(mismatch)")
    #expect(!UUIDs(in: mismatch).isEmpty)
    #expect(!UUIDs(in: mismatch).contains(fixture.incarnation.token))
    return CleanupSentinels(mismatch: mismatch)
}

private func cleanupSentinels(
    in request: ProcessRequest,
    candidate: CandidateArtifacts,
    token: UUID
) throws -> CleanupSentinels {
    #expect(request.executable == exactTmuxExecutable)
    #expect(
        request.environment
            == emittedChildEnvironment()
    )
    #expect(request.workingDirectory == nil)
    #expect(request.outputPolicy == .complete)
    #expect(request.arguments.count == 8)
    guard request.arguments.count == 8 else {
        throw FixtureContractError.unexpectedRequestCount(
            expected: 8,
            actual: request.arguments.count
        )
    }
    #expect(
        Array(request.arguments.prefix(5))
            == ["-N", "-S", candidate.socketPath, "if-shell", "-F"]
    )
    #expect(
        request.arguments[5]
            == "#{==:#{\(incarnationOption)},\(token.uuidString)}"
    )

    let matchingBranch = request.arguments[6]
    let mismatchingBranch = request.arguments[7]
    let mismatch = try printedSentinel(in: mismatchingBranch)
    #expect(matchingBranch == "kill-server")
    #expect(mismatchingBranch == "display-message -p \(mismatch)")
    #expect(!UUIDs(in: mismatch).isEmpty)
    #expect(!UUIDs(in: mismatch).contains(token))
    return CleanupSentinels(mismatch: mismatch)
}

private func endpointAbsenceRequest(
    _ request: ProcessRequest,
    fixture: TmuxFixture,
    inputEnvironment: [String: String] = inputChildEnvironmentValues,
    temporaryDirectory: String = inputChildEnvironment.temporaryDirectory
) throws {
    let socket = try socketPath(of: fixture)
    #expect(request.executable == exactTmuxExecutable)
    #expect(
        request.environment
            == emittedChildEnvironment(
                temporaryDirectory: temporaryDirectory,
                input: inputEnvironment
            )
    )
    #expect(request.workingDirectory == nil)
    #expect(request.outputPolicy == .complete)
    #expect(
        request.arguments
            == ["-N", "-S", socket, "display-message", "-p", "#{socket_path}"]
    )
}

private func endpointAbsenceRequest(
    _ request: ProcessRequest,
    candidate: CandidateArtifacts
) throws {
    #expect(request.executable == exactTmuxExecutable)
    #expect(
        request.environment
            == emittedChildEnvironment()
    )
    #expect(request.workingDirectory == nil)
    #expect(request.outputPolicy == .complete)
    #expect(
        request.arguments
            == [
                "-N",
                "-S",
                candidate.socketPath,
                "display-message",
                "-p",
                "#{socket_path}",
            ]
    )
}

private func primeSuccessfulStart(
    transport: ScriptedProcessTransport
) async throws -> UUID {
    let request = try await transport.checkpoint(after: 1)[0]
    let token = try candidateToken(from: request)
    _ = try materializeCandidateSocket(from: request)
    await transport.enqueue([
        .reply(processReply(standardOutput: "\(token.uuidString)\n")),
        .reply(processReply(standardOutput: "\(token.uuidString)\n")),
        .reply(processReply()),
    ])
    return token
}

private func startOwnedFixture(
    configuration: FixtureConfiguration,
    transport: ScriptedProcessTransport
) async throws -> FixtureLease {
    let operation = Task {
        try await FixtureLease.start(
            configuration: configuration,
            transport: transport
        )
    }
    do {
        _ = try await primeSuccessfulStart(transport: transport)
        return try await operation.value
    } catch {
        await transport.releaseAll()
        operation.cancel()
        _ = try? await operation.value
        throw error
    }
}

private func cleanupSuccessfully(
    lease: FixtureLease,
    transport: ScriptedProcessTransport,
    inputEnvironment: [String: String] = inputChildEnvironmentValues,
    temporaryDirectory: String = inputChildEnvironment.temporaryDirectory
) async throws -> ProcessRequest {
    let startingCount = await transport.snapshot.count
    let operation = Task { await lease.cleanupResult() }
    do {
        let guarded = try await transport.checkpoint(after: startingCount + 1).last
        guard let guarded else {
            throw FixtureContractError.unexpectedRequestCount(
                expected: startingCount + 1,
                actual: 0
            )
        }
        _ = try cleanupSentinels(
            in: guarded,
            fixture: lease.fixture,
            inputEnvironment: inputEnvironment,
            temporaryDirectory: temporaryDirectory
        )
        await transport.enqueue(
            .reply(processReply())
        )
        let absence = try await transport.checkpoint(after: startingCount + 2).last
        guard let absence else {
            throw FixtureContractError.unexpectedRequestCount(
                expected: startingCount + 2,
                actual: 0
            )
        }
        try endpointAbsenceRequest(
            absence,
            fixture: lease.fixture,
            inputEnvironment: inputEnvironment,
            temporaryDirectory: temporaryDirectory
        )
        await transport.enqueue(.reply(processReply(exitCode: 1)))
        let result = await operation.value
        try result.get()
        return guarded
    } catch {
        await transport.releaseAll()
        operation.cancel()
        _ = await operation.value
        throw error
    }
}

private func rethrowAfterLeaseFailure(
    _ primaryError: any Error,
    lease: FixtureLease,
    transport: ScriptedProcessTransport
) async throws -> Never {
    await transport.releaseAll()
    let cleanup: Result<Void, FixtureCleanupError> = await lease.cleanupResult()
    if case let .failure(cleanupError) = cleanup {
        Issue.record(
            "fixture cleanup after test failure also failed: \(cleanupError)"
        )
    }
    throw primaryError
}

private func acceptsSendable<T: Sendable>(_ value: T) {
    _ = value
}

private func expectFailure<Failure: Error>(_ result: Result<Void, Failure>) {
    do {
        try result.get()
        Issue.record("expected lifecycle failure")
    } catch {
    }
}

@Suite(
    "explicit fixture lifecycle contract",
    .timeLimit(.minutes(1))
)
struct FixtureContractTests {
    @Test("start creates private immutable fixture identity")
    func startCreatesPrivateImmutableFixtureIdentity() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        defer { fakeScope.finish() }
        let rootPaddingCount = 62 - fakeScope.runRoot.path.utf8.count - 1
        #expect(rootPaddingCount > 0)
        let root = fakeScope.runRoot.appendingPathComponent(
            String(repeating: "r", count: rootPaddingCount)
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        #expect(root.path.utf8.count == 62)
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        do {
            let fixture = lease.fixture

            acceptsSendable(lease)
            acceptsSendable(fixture)
            acceptsSendable(fixture.ownershipRecord)
            #expect(
                fixture.runDirectory.deletingLastPathComponent()
                    .standardizedFileURL.path == root.standardizedFileURL.path
            )
            #expect(
                fixture.socketDirectory.deletingLastPathComponent()
                    .standardizedFileURL.path
                    == fixture.runDirectory.standardizedFileURL.path
            )
            #expect(try posixMode(of: fixture.runDirectory) == 0o700)
            #expect(try posixMode(of: fixture.socketDirectory) == 0o700)
            #expect(fixture.endpoint == fixture.incarnation.endpoint)
            #expect(
                try socketPath(of: fixture).utf8.count
                    <= portableUnixSocketPathByteLimit
            )
            #expect(
                fixture.ownershipRecord.token == fixture.incarnation.token
            )
            #expect(
                fixture.ownershipRecord.marker == fixture.ownershipMarker
            )
            #expect(
                URL(fileURLWithPath: try socketPath(of: fixture))
                    .deletingLastPathComponent().standardizedFileURL.path
                    == fixture.socketDirectory.standardizedFileURL.path
            )

            let configuration = try String(
                contentsOf: fixture.configurationFile,
                encoding: .utf8
            )
            #expect(UUIDs(in: configuration) == [fixture.incarnation.token])
            #expect(
                try bootstrapSession(from: configuration)
                    == "bootstrap-\(fixture.incarnation.token.uuidString)"
            )
            #expect(
                configuration.contains(
                    "set-option -s \(incarnationOption) "
                        + fixture.incarnation.token.uuidString
                )
            )
            let option = configuration.range(
                of: "set-option -s \(incarnationOption)"
            )
            let bootstrap = configuration.range(of: "new-session")
            #expect(option != nil)
            #expect(bootstrap != nil)
            if let option, let bootstrap {
                #expect(option.lowerBound < bootstrap.lowerBound)
            }

            _ = try await cleanupSuccessfully(lease: lease, transport: transport)
        } catch {
            try await rethrowAfterLeaseFailure(
                error,
                lease: lease,
                transport: transport
            )
        }
    }

    @Test("start publishes one canonical recovery-ready record")
    func startPublishesCanonicalRecoveryReadyRecord() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: fakeScope.runRoot),
            transport: transport
        )
        do {
            let fixture = lease.fixture
            let recoverySidecar = fixture.runDirectory
                .deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(fixture.runDirectory.lastPathComponent).owner.json"
                )
            let lines = try recoveryMarkerLines(at: fixture.ownershipMarker)
            #expect(lines.count == 2)
            guard lines.count == 2 else {
                throw FixtureContractError.invalidRecoveryMarker
            }
            let expectedPreparing = Data(
                ("{\"ownerProcessIdentifier\":\(getpid()),"
                    + "\"token\":\"\(fixture.incarnation.token.uuidString)\","
                    + "\"version\":1}").utf8
            )
            #expect(lines[0] == expectedPreparing)

            let ready = try JSONDecoder().decode(
                RecoveryReadyRecord.self,
                from: lines[1]
            )
            #expect(ready.state == "ready")
            #expect(ready.version == 1)
            #expect(ready.token == fixture.incarnation.token.uuidString)
            #expect(
                ready.tmuxExecutablePath
                    == "/opt/libtmux-tests/bin/tmux"
            )
            try expectRecoveryArtifact(
                ready.configurationFile,
                at: fixture.configurationFile,
                kind: "regular"
            )
            try expectRecoveryArtifact(
                ready.ownershipMarker,
                at: fixture.ownershipMarker,
                kind: "regular"
            )
            try expectRecoveryArtifact(
                ready.runDirectory,
                at: fixture.runDirectory,
                kind: "directory"
            )
            try expectRecoveryArtifact(
                ready.socket,
                at: URL(fileURLWithPath: try socketPath(of: fixture)),
                kind: "socket"
            )
            try expectRecoveryArtifact(
                ready.socketDirectory,
                at: fixture.socketDirectory,
                kind: "directory"
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            #expect(try encoder.encode(ready) == lines[1])
            #expect(
                try pathIdentity(of: recoverySidecar)
                    == pathIdentity(of: fixture.ownershipMarker)
            )
            #expect(try markerLockIsBusy(at: recoverySidecar))

            _ = try await cleanupSuccessfully(lease: lease, transport: transport)
            #expect(!FileManager.default.fileExists(atPath: recoverySidecar.path))
        } catch {
            try await rethrowAfterLeaseFailure(
                error,
                lease: lease,
                transport: transport
            )
        }
    }

    @Test(
        "recovery journal publication exposes each durable phase",
        arguments: RecoveryJournalPublicationPhase.allCases
    )
    func recoveryJournalPublicationExposesDurablePhase(
        _ phase: RecoveryJournalPublicationPhase
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [phase.checkpoint]
        )
        let operation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(
                    runRoot: root,
                    checkpointHarness: checkpoints
                ),
                transport: transport
            )
        }
        var lease: FixtureLease?
        do {
            _ = try await primeSuccessfulStart(transport: transport)
            try await checkpoints.waitUntilReached(phase.checkpoint)
            let firstRequest = try await transport.checkpoint(after: 1)[0]
            let candidate = try candidateArtifacts(from: firstRequest)
            let sidecar = candidate.runDirectory.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(candidate.runDirectory.lastPathComponent).owner.json"
                )
            #expect(try recoveryMarkerLines(at: candidate.ownershipMarker).count == 2)
            switch phase {
            case .readyRecordSynchronized:
                #expect(!FileManager.default.fileExists(atPath: sidecar.path))
            case .sidecarSynchronized:
                #expect(
                    try pathIdentity(of: sidecar)
                        == pathIdentity(of: candidate.ownershipMarker)
                )
                #expect(try markerLockIsBusy(at: sidecar))
            }

            await checkpoints.release(phase.checkpoint)
            lease = try await operation.value
            _ = try await cleanupSuccessfully(
                lease: try #require(lease),
                transport: transport
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            if let lease {
                _ = await lease.cleanupResult()
            }
            throw error
        }
    }

    @Test(
        "cleanup exposes each durable recovery journal phase",
        arguments: RecoveryJournalCleanupPhase.allCases
    )
    func cleanupExposesDurableRecoveryJournalPhase(
        _ phase: RecoveryJournalCleanupPhase
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [phase.checkpoint]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: fakeScope.runRoot,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let sidecar = lease.fixture.runDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(lease.fixture.runDirectory.lastPathComponent).owner.json"
            )
        let retainedSidecarDescriptor: Int32
        if phase == .sidecarRemoved {
            retainedSidecarDescriptor = open(
                sidecar.path,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
            guard retainedSidecarDescriptor >= 0 else {
                throw FixtureContractError.systemCall(
                    operation: "open-retained-recovery-sidecar",
                    code: Int32(errno)
                )
            }
        } else {
            retainedSidecarDescriptor = -1
        }
        defer {
            if retainedSidecarDescriptor >= 0 {
                _ = testFlock(retainedSidecarDescriptor, Int32(LOCK_UN))
                _ = close(retainedSidecarDescriptor)
            }
        }
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(phase.checkpoint)

            switch phase {
            case .claimed:
                #expect(
                    !FileManager.default.fileExists(
                        atPath: lease.fixture.ownershipMarker.path
                    )
                )
                #expect(
                    FileManager.default.fileExists(
                        atPath: lease.fixture.configurationFile.path
                    )
                )
                #expect(FileManager.default.fileExists(atPath: sidecar.path))
                #expect(try markerLockIsBusy(at: sidecar))
            case .configurationRemoved:
                #expect(
                    !FileManager.default.fileExists(
                        atPath: lease.fixture.configurationFile.path
                    )
                )
                #expect(FileManager.default.fileExists(atPath: sidecar.path))
                #expect(try markerLockIsBusy(at: sidecar))
            case .runRemoved:
                #expect(
                    !FileManager.default.fileExists(
                        atPath: lease.fixture.runDirectory.path
                    )
                )
                #expect(FileManager.default.fileExists(atPath: sidecar.path))
                #expect(try markerLockIsBusy(at: sidecar))
            case .sidecarRemoved:
                #expect(
                    !FileManager.default.fileExists(
                        atPath: lease.fixture.runDirectory.path
                    )
                )
                #expect(!FileManager.default.fileExists(atPath: sidecar.path))
                let lockResult = testFlock(
                    retainedSidecarDescriptor,
                    Int32(LOCK_EX | LOCK_NB)
                )
                #expect(lockResult != 0)
                if lockResult == 0 {
                    _ = testFlock(
                        retainedSidecarDescriptor,
                        Int32(LOCK_UN)
                    )
                } else {
                    #expect(errno == EAGAIN || errno == EWOULDBLOCK)
                }
            }

            await checkpoints.release(phase.checkpoint)
            try await operation.value.get()
            if phase == .sidecarRemoved {
                #expect(
                    testFlock(
                        retainedSidecarDescriptor,
                        Int32(LOCK_EX | LOCK_NB)
                    ) == 0
                )
            }
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test(
        "cleanup preserves every rebound journal mutation target",
        arguments: RecoveryJournalReplacementPhase.allCases
    )
    func cleanupPreservesReboundJournalMutationTarget(
        _ phase: RecoveryJournalReplacementPhase
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [phase.checkpoint]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: fakeScope.runRoot,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let sidecar = lease.fixture.runDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(lease.fixture.runDirectory.lastPathComponent).owner.json"
            )
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(phase.checkpoint)

            let target: URL
            let displaced: URL
            let expectedError: FixtureCleanupError
            switch phase {
            case .configuration:
                target = lease.fixture.configurationFile
                displaced = lease.fixture.runDirectory.appendingPathComponent(
                    ".owned-configuration-\(UUID().uuidString)"
                )
                expectedError = .filesystem(
                    operation: "validate-recovery-configuration",
                    code: ESTALE
                )
            case .innerMarker:
                target = lease.fixture.ownershipMarker
                displaced = lease.fixture.runDirectory.appendingPathComponent(
                    ".owned-marker-\(UUID().uuidString)"
                )
                expectedError = .filesystem(
                    operation: "validate-recovery-owner-before-claim",
                    code: ESTALE
                )
            case .runDirectory:
                target = lease.fixture.runDirectory
                displaced = target.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".owned-run-\(UUID().uuidString)"
                    )
                expectedError = .filesystem(
                    operation: "validate-recovery-run-directory",
                    code: ESTALE
                )
            case .sidecar:
                target = sidecar
                displaced = target.deletingLastPathComponent()
                    .appendingPathComponent(
                        ".owned-sidecar-\(UUID().uuidString)"
                    )
                expectedError = .filesystem(
                    operation: "validate-recovery-sidecar-before-removal",
                    code: ESTALE
                )
            }

            let replacementIdentity: PathIdentity
            if phase == .runDirectory {
                guard rename(target.path, displaced.path) == 0,
                    mkdir(target.path, 0o700) == 0,
                    chmod(target.path, 0o700) == 0
                else {
                    throw FixtureContractError.systemCall(
                        operation: "replace-run-directory-before-removal",
                        code: Int32(errno)
                    )
                }
                replacementIdentity = try pathIdentity(of: target)
            } else {
                replacementIdentity = try replaceRegularFile(
                    at: target,
                    displacedTo: displaced
                )
            }
            #expect(replacementIdentity != (try pathIdentity(of: displaced)))
            await checkpoints.release(phase.checkpoint)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("rebound journal target was unexpectedly removed")
                return
            }
            #expect(error == expectedError)
            #expect(try pathIdentity(of: target) == replacementIdentity)
            #expect(FileManager.default.fileExists(atPath: displaced.path))
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test(
        "overlong socket path fails before process launch",
        arguments: [
            String(repeating: "x", count: 80),
            String(repeating: "é", count: 40),
        ]
    )
    func overlongSocketPathFailsBeforeProcessLaunch(
        _ overlongComponent: String
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        defer { fakeScope.finish() }
        let overlongRoot = fakeScope.runRoot.appendingPathComponent(
            overlongComponent
        )
        try FileManager.default.createDirectory(
            at: overlongRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let transport = ScriptedProcessTransport(
            outcomes: [.failure(.immediateFailure)]
        )

        do {
            _ = try await FixtureLease.start(
                configuration: makeConfiguration(runRoot: overlongRoot),
                transport: transport
            )
            Issue.record("expected an overlong socket-path error")
        } catch let error as FixtureStartError {
            guard case let .socketPathTooLong(actualBytes, maximumBytes) = error else {
                Issue.record("unexpected fixture start error: \(error)")
                return
            }
            #expect(actualBytes > maximumBytes)
            #expect(maximumBytes == portableUnixSocketPathByteLimit)
        }

        #expect(await transport.snapshot.isEmpty)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: overlongRoot.path)
                .isEmpty
        )
    }

    @Test("start uses exact argv environment and readiness probes")
    func startUsesExactArgvEnvironmentAndReadinessProbes() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        do {
            let requests = await transport.snapshot
            #expect(requests.count == 3)
            guard requests.count == 3 else {
                throw FixtureContractError.unexpectedRequestCount(
                    expected: 3,
                    actual: requests.count
                )
            }

            let socket = try socketPath(of: lease.fixture)
            #expect(
                requests[0].arguments
                    == [
                        "-S",
                        socket,
                        "-f",
                        lease.fixture.configurationFile.path,
                        "start-server",
                        ";",
                        "show-options",
                        "-sv",
                        incarnationOption,
                    ]
            )
            let configuration = try configurationText(from: requests[0])
            let bootstrap = try bootstrapSession(from: configuration)
            #expect(
                requests[1].arguments
                    == [
                        "-N", "-S", socket, "show-options", "-sv",
                        incarnationOption,
                    ]
            )
            #expect(
                requests[2].arguments
                    == [
                        "-N", "-S", socket, "has-session", "-t",
                        "=\(bootstrap)",
                    ]
            )
            for request in requests {
                #expect(request.executable == exactTmuxExecutable)
                #expect(request.environment == emittedChildEnvironment())
                #expect(request.environment["LC_ALL"] == "C")
                #expect(
                    request.environment["TMPDIR"]
                        == inputChildEnvironment.temporaryDirectory
                )
                #expect(request.environment["LANG"] == nil)
                #expect(request.environment["HOME"] == nil)
                #expect(request.environment["TMUX"] == nil)
                #expect(request.environment["TMUX_PANE"] == nil)
                #expect(request.workingDirectory == nil)
                #expect(request.outputPolicy == .complete)
            }
            #expect(
                requests.dropFirst().allSatisfy {
                    $0.arguments.first == "-N"
                }
            )

            _ = try await cleanupSuccessfully(lease: lease, transport: transport)
        } catch {
            try await rethrowAfterLeaseFailure(
                error,
                lease: lease,
                transport: transport
            )
        }
    }

    @Test("child environment keeps only optional toolchain inputs")
    func childEnvironmentKeepsOnlyOptionalToolchainInputs() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let pathOnlyEnvironment = [
            "PATH": "/authenticated/bin:/usr/bin"
        ]
        let pathOnlyInput = FixtureChildEnvironment(
            path: "/authenticated/bin:/usr/bin",
            temporaryDirectory: "/authenticated/scratch",
            developerDirectory: nil,
            sdkRoot: nil
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                childEnvironment: pathOnlyInput
            ),
            transport: transport
        )
        do {
            let expected = emittedChildEnvironment(
                temporaryDirectory: pathOnlyInput.temporaryDirectory,
                input: pathOnlyEnvironment
            )
            for request in await transport.snapshot {
                #expect(request.environment == expected)
                #expect(request.environment["PATH"] == pathOnlyEnvironment["PATH"])
                #expect(request.environment["LC_ALL"] == "C")
                #expect(
                    request.environment["TMPDIR"]
                        == pathOnlyInput.temporaryDirectory
                )
                #expect(request.environment["DEVELOPER_DIR"] == nil)
                #expect(request.environment["SDKROOT"] == nil)
                #expect(request.environment["LANG"] == nil)
                #expect(request.environment["HOME"] == nil)
                #expect(request.environment["TMUX"] == nil)
                #expect(request.environment["TMUX_PANE"] == nil)
            }
            _ = try await cleanupSuccessfully(
                lease: lease,
                transport: transport,
                inputEnvironment: pathOnlyEnvironment,
                temporaryDirectory: pathOnlyInput.temporaryDirectory
            )
        } catch {
            try await rethrowAfterLeaseFailure(
                error,
                lease: lease,
                transport: transport
            )
        }
    }

    @Test(
        "missing or mismatched startup token rejects without mutation",
        arguments: InvalidStartupToken.allCases
    )
    func invalidStartupTokenRejectsWithoutMutation(
        _ invalidToken: InvalidStartupToken
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let configuration = makeConfiguration(runRoot: root)
        let operation = Task {
            try await FixtureLease.start(
                configuration: configuration,
                transport: transport
            )
        }
        do {
            let first = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: first)
            let candidate = try materializeCandidateSocket(from: first)
            let originalConfiguration = try Data(
                contentsOf: candidate.configurationFile
            )
            switch invalidToken {
            case .missing:
                await transport.enqueue(.reply(processReply()))
            case .mismatched:
                var replacement = UUID()
                while replacement == token {
                    replacement = UUID()
                }
                await transport.enqueue(
                    .reply(processReply(standardOutput: "\(replacement.uuidString)\n"))
                )
            }

            var rejected = false
            do {
                _ = try await operation.value
            } catch {
                rejected = true
            }
            #expect(rejected)
            let requests = await transport.snapshot
            #expect(requests.count == 1)
            #expect(!requests.flatMap(\.arguments).contains("kill-server"))
            #expect(!requests.flatMap(\.arguments).contains("set-option"))
            #expect(
                candidate.runDirectory.deletingLastPathComponent()
                    .standardizedFileURL.path == root.standardizedFileURL.path
            )
            #expect(
                try Data(contentsOf: candidate.configurationFile)
                    == originalConfiguration
            )
            let marker = try String(
                contentsOf: candidate.ownershipMarker,
                encoding: .utf8
            )
            #expect(UUIDs(in: marker) == [token])
            #expect(
                FileManager.default.fileExists(
                    atPath: candidate.runDirectory.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: candidate.configurationFile.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: candidate.ownershipMarker.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: candidate.socketDirectory.path
                )
            )
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("readiness polls from not ready to token and bootstrap ready")
    func readinessPollsUntilTokenAndBootstrapAreReady() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let configuration = makeConfiguration(runRoot: root)
        let operation = Task {
            try await FixtureLease.start(
                configuration: configuration,
                transport: transport
            )
        }
        var acquiredLease: FixtureLease?
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try materializeCandidateSocket(from: initial)
            let configuration = try configurationText(from: initial)
            let bootstrap = try bootstrapSession(from: configuration)
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )

            let firstTokenProbe = try await transport.checkpoint(after: 2)[1]
            #expect(
                firstTokenProbe.arguments
                    == [
                        "-N",
                        "-S",
                        candidate.socketPath,
                        "show-options",
                        "-sv",
                        incarnationOption,
                    ]
            )
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            let firstBootstrapProbe = try await transport.checkpoint(after: 3)[2]
            #expect(
                firstBootstrapProbe.arguments
                    == [
                        "-N",
                        "-S",
                        candidate.socketPath,
                        "has-session",
                        "-t",
                        "=\(bootstrap)",
                    ]
            )
            await transport.enqueue(.reply(processReply(exitCode: 1)))

            let secondTokenProbe = try await transport.checkpoint(after: 4)[3]
            #expect(secondTokenProbe.arguments == firstTokenProbe.arguments)
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            let secondBootstrapProbe = try await transport.checkpoint(after: 5)[4]
            #expect(secondBootstrapProbe.arguments == firstBootstrapProbe.arguments)
            #expect(try recoveryMarkerLines(at: candidate.ownershipMarker).count == 1)
            await transport.enqueue(.reply(processReply()))

            let lease = try await operation.value
            acquiredLease = lease
            #expect(lease.fixture.incarnation.token == token)
            #expect(try recoveryMarkerLines(at: candidate.ownershipMarker).count == 2)
            #expect(
                await transport.snapshot.dropFirst().allSatisfy {
                    $0.arguments.first == "-N"
                }
            )
            _ = try await cleanupSuccessfully(lease: lease, transport: transport)
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            if let acquiredLease {
                try await rethrowAfterLeaseFailure(
                    error,
                    lease: acquiredLease,
                    transport: transport
                )
            }
            throw error
        }
    }

    @Test("readiness rejects same-type endpoint identity drift")
    func readinessRejectsSameTypeEndpointIdentityDrift() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.afterInitialTokenAcceptance]
        )
        let operation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(
                    runRoot: root,
                    checkpointHarness: checkpoints
                ),
                transport: transport
            )
        }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try materializeCandidateSocket(from: initial)
            let originalConfiguration = try Data(
                contentsOf: candidate.configurationFile
            )
            let originalMarker = try Data(contentsOf: candidate.ownershipMarker)
            let originalRunDirectory = try pathIdentity(of: candidate.runDirectory)
            let originalSocketDirectory = try pathIdentity(
                of: candidate.socketDirectory
            )
            let endpoint = URL(fileURLWithPath: candidate.socketPath)
            let originalEndpoint = try pathIdentity(of: endpoint)
            let displacedEndpoint = candidate.socketDirectory
                .appendingPathComponent("initial-endpoint")

            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            try await checkpoints.waitUntilReached(.afterInitialTokenAcceptance)
            guard rename(endpoint.path, displacedEndpoint.path) == 0 else {
                throw FixtureContractError.systemCall(
                    operation: "rename-initial-endpoint-before-readiness",
                    code: Int32(errno)
                )
            }
            try createUnixSocketArtifact(at: endpoint.path)
            let replacementEndpoint = try pathIdentity(of: endpoint)
            #expect(replacementEndpoint != originalEndpoint)
            #expect(try pathIdentity(of: displacedEndpoint) == originalEndpoint)
            await checkpoints.release(.afterInitialTokenAcceptance)

            _ = try await transport.checkpoint(after: 2)
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            _ = try await transport.checkpoint(after: 3)
            await transport.enqueue(.reply(processReply()))

            do {
                let lease = try await operation.value
                Issue.record("endpoint identity drift unexpectedly started a lease")
                guard unlink(displacedEndpoint.path) == 0 else {
                    throw FixtureContractError.systemCall(
                        operation: "unlink-displaced-endpoint-after-failed-red",
                        code: Int32(errno)
                    )
                }
                _ = try await cleanupSuccessfully(
                    lease: lease,
                    transport: transport
                )
                return
            } catch let error as FixtureStartError {
                #expect(error == .endpointIdentityChanged)
            } catch {
                Issue.record("unexpected endpoint identity error: \(error)")
                return
            }

            #expect(await transport.snapshot.count == 3)
            #expect(
                await transport.snapshot.allSatisfy {
                    !$0.arguments.contains("if-shell")
                }
            )
            #expect(
                try Data(contentsOf: candidate.configurationFile)
                    == originalConfiguration
            )
            #expect(try Data(contentsOf: candidate.ownershipMarker) == originalMarker)
            #expect(try pathIdentity(of: candidate.runDirectory) == originalRunDirectory)
            #expect(
                try pathIdentity(of: candidate.socketDirectory)
                    == originalSocketDirectory
            )
            #expect(try pathIdentity(of: endpoint) == replacementEndpoint)
            #expect(try pathIdentity(of: displacedEndpoint) == originalEndpoint)
            #expect(
                !FileManager.default.fileExists(
                    atPath: "\(candidate.socketPath).lock"
                )
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("startup deadline cancels the fake and awaits owned rollback")
    func startupDeadlineIsOwnedByLifecycle() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport(
            checkpointDeadline: harnessDeadline,
            holdCancellationAt: [2]
        )
        let deadlines = ManualDeadlineHarness()
        let completed = CompletionProbe()
        let operation = Task {
            do {
                let lease = try await FixtureLease.start(
                    configuration: makeConfiguration(
                        runRoot: root,
                        startupDeadline: .milliseconds(25),
                        deadlineHarness: deadlines
                    ),
                    transport: transport
                )
                await completed.markComplete()
                return lease
            } catch {
                await completed.markComplete()
                throw error
            }
        }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try materializeCandidateSocket(from: initial)
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            let blockedReadiness = try await transport.checkpoint(after: 2)[1]
            #expect(blockedReadiness.arguments.first == "-N")
            try await deadlines.waitUntilRequested(
                1,
                duration: .milliseconds(25)
            )
            try await deadlines.arm(1)
            try await deadlines.fire(1)
            try await transport.waitUntilRequestCancelled(2)
            #expect(!(await completed.isComplete))
            #expect(await transport.snapshot.count == 2)
            await transport.releaseRequestCancellation(2)

            let guardedRollback = try await transport.checkpoint(after: 3)[2]
            #expect(!(await completed.isComplete))
            _ = try cleanupSentinels(
                in: guardedRollback,
                candidate: candidate,
                token: token
            )
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 4)[3]
            #expect(!(await completed.isComplete))
            try endpointAbsenceRequest(absence, candidate: candidate)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await completed.waitUntilComplete()

            var deadlineRejected = false
            do {
                _ = try await operation.value
            } catch {
                deadlineRejected = true
            }
            #expect(deadlineRejected)
            #expect(!FileManager.default.fileExists(atPath: candidate.runDirectory.path))
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
        } catch {
            await deadlines.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("cancellation after token acceptance awaits guarded rollback")
    func cancellationAfterPossibleDaemonLaunchAwaitsRollback() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.afterInitialTokenAcceptance]
        )
        let operation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(
                    runRoot: root,
                    checkpointHarness: checkpoints
                ),
                transport: transport
            )
        }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try materializeCandidateSocket(from: initial)
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            try await checkpoints.waitUntilReached(.afterInitialTokenAcceptance)
            operation.cancel()
            await checkpoints.release(.afterInitialTokenAcceptance)

            let guardedRollback = try await transport.checkpoint(after: 2)[1]
            _ = try cleanupSentinels(
                in: guardedRollback,
                candidate: candidate,
                token: token
            )
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 3)[2]
            try endpointAbsenceRequest(absence, candidate: candidate)
            await transport.enqueue(.reply(processReply(exitCode: 1)))

            var cancellationObserved = false
            do {
                _ = try await operation.value
            } catch is CancellationError {
                cancellationObserved = true
            } catch {
                Issue.record("expected cancellation after rollback, got \(error)")
            }
            #expect(cancellationObserved)
            #expect(!FileManager.default.fileExists(atPath: candidate.runDirectory.path))
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("readiness token mismatch preserves exact candidate artifacts")
    func readinessMismatchPreservesCandidateArtifacts() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let operation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(runRoot: root),
                transport: transport
            )
        }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try materializeCandidateSocket(from: initial)
            let originalConfiguration = try Data(
                contentsOf: candidate.configurationFile
            )
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )

            _ = try await transport.checkpoint(after: 2)
            var replacement = UUID()
            while replacement == token {
                replacement = UUID()
            }
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(replacement.uuidString)\n"))
            )

            var rejected = false
            do {
                _ = try await operation.value
            } catch {
                rejected = true
            }
            #expect(rejected)
            #expect(await transport.snapshot.count == 2)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.isEmpty
            )
            #expect(try Data(contentsOf: candidate.configurationFile) == originalConfiguration)
            let marker = try String(
                contentsOf: candidate.ownershipMarker,
                encoding: .utf8
            )
            #expect(UUIDs(in: marker) == [token])
            #expect(FileManager.default.fileExists(atPath: candidate.runDirectory.path))
            #expect(FileManager.default.fileExists(atPath: candidate.socketDirectory.path))
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("setup rolls back after an owned daemon may have started")
    func setupRollsBackAfterPossibleDaemonStart() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let configuration = makeConfiguration(runRoot: root)
        let operation = Task {
            try await FixtureLease.start(
                configuration: configuration,
                transport: transport
            )
        }
        do {
            let first = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: first)
            let candidate = try materializeCandidateSocket(from: first)
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            _ = try await transport.checkpoint(after: 2)
            await transport.enqueue(.failure(.disconnected))

            let guarded = try await transport.checkpoint(after: 3)[2]
            _ = try cleanupSentinels(
                in: guarded,
                candidate: candidate,
                token: token
            )
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 4)[3]
            try endpointAbsenceRequest(absence, candidate: candidate)
            await transport.enqueue(.reply(processReply(exitCode: 1)))

            var rejected = false
            do {
                _ = try await operation.value
            } catch {
                rejected = true
            }
            #expect(rejected)
            let requests = await transport.snapshot
            #expect(
                requests.filter { $0.arguments.contains("if-shell") }.count == 1
            )
            #expect(!FileManager.default.fileExists(atPath: candidate.runDirectory.path))
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("startup rollback failure preserves primary and cleanup errors")
    func startupRollbackFailurePreservesPrimaryAndCleanupErrors() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let operation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(runRoot: root),
                transport: transport
            )
        }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try materializeCandidateSocket(from: initial)
            let configurationBytes = try Data(
                contentsOf: candidate.configurationFile
            )
            let configurationIdentity = try pathIdentity(
                of: candidate.configurationFile
            )
            let endpoint = URL(fileURLWithPath: candidate.socketPath)
            let endpointIdentity = try pathIdentity(of: endpoint)
            let markerIdentity = try pathIdentity(of: candidate.ownershipMarker)
            let runDirectoryIdentity = try pathIdentity(of: candidate.runDirectory)
            let socketDirectoryIdentity = try pathIdentity(
                of: candidate.socketDirectory
            )
            await transport.enqueue(
                .reply(processReply(standardOutput: "\(token.uuidString)\n"))
            )
            _ = try await transport.checkpoint(after: 2)
            await transport.enqueue(.failure(.disconnected))

            let guarded = try await transport.checkpoint(after: 3)[2]
            _ = try cleanupSentinels(
                in: guarded,
                candidate: candidate,
                token: token
            )
            await transport.enqueue(.failure(.immediateFailure))

            do {
                _ = try await operation.value
                Issue.record("startup unexpectedly discarded both failures")
                return
            } catch let error as FixtureStartError {
                #expect(
                    error
                        == .rollbackFailed(
                            primary: .transportFailure,
                            cleanup: .guardTransportFailure,
                            ownerCloseFailure: nil
                        )
                )
            } catch {
                Issue.record("unexpected composite startup error: \(error)")
                return
            }

            #expect(await transport.snapshot.count == 3)
            #expect(
                try Data(contentsOf: candidate.configurationFile)
                    == configurationBytes
            )
            #expect(
                try pathIdentity(of: candidate.configurationFile)
                    == configurationIdentity
            )
            #expect(try pathIdentity(of: endpoint) == endpointIdentity)
            #expect(
                try pathIdentity(of: candidate.ownershipMarker)
                    == markerIdentity
            )
            #expect(
                try pathIdentity(of: candidate.runDirectory)
                    == runDirectoryIdentity
            )
            #expect(
                try pathIdentity(of: candidate.socketDirectory)
                    == socketDirectoryIdentity
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: "\(candidate.socketPath).lock"
                )
            )
            let markerLock = try acquireTestSocketLock(
                at: candidate.ownershipMarker.path
            )
            releaseTestSocketLock(markerLock)
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("cleanup waits for endpoint absence and is idempotent")
    func cleanupWaitsForEndpointAbsenceAndIsIdempotent() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.ownershipMarker.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            let firstResult = await operation.value
            try firstResult.get()

            #expect(
                !FileManager.default.fileExists(
                    atPath: lease.fixture.runDirectory.path
                )
            )
            let countAfterFirstCleanup = await transport.snapshot.count
            let secondResult = await lease.cleanupResult()
            try secondResult.get()
            #expect(await transport.snapshot.count == countAfterFirstCleanup)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("cleanup deadline cancels and awaits the guarded request")
    func cleanupDeadlineIsOwnedByLifecycle() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let deadlines = ManualDeadlineHarness()
        let transport = ScriptedProcessTransport(
            checkpointDeadline: harnessDeadline,
            holdCancellationAt: [4]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                cleanupDeadline: .milliseconds(25),
                deadlineHarness: deadlines
            ),
            transport: transport
        )
        try await deadlines.waitUntilRequested(1, duration: .seconds(2))
        let completed = CompletionProbe()
        let operation = Task<Result<Void, FixtureCleanupError>, Never> {
            let result = await lease.cleanupResult()
            await completed.markComplete()
            return result
        }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            try await deadlines.waitUntilRequested(
                2,
                duration: .milliseconds(25)
            )
            try await deadlines.arm(2)
            try await deadlines.fire(2)
            try await transport.waitUntilRequestCancelled(4)
            #expect(!(await completed.isComplete))
            await transport.releaseRequestCancellation(4)
            try await completed.waitUntilComplete()
            #expect(await transport.wasRequestCancelled(4))
            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("cleanup deadline unexpectedly succeeded")
                return
            }
            #expect(error == .deadlineExceeded)
            #expect(await transport.snapshot.count == 4)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.runDirectory.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.ownershipMarker.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.socketDirectory.path
                )
            )
        } catch {
            await deadlines.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("concurrent cleanup calls coalesce into one guarded teardown")
    func concurrentCleanupCallsCoalesce() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.cleanupRequested]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let first = Task<Result<Void, FixtureCleanupError>, Never> {
            await lease.cleanupResult()
        }
        let second = Task<Result<Void, FixtureCleanupError>, Never> {
            await lease.cleanupResult()
        }
        do {
            try await checkpoints.waitUntilReached(.cleanupRequested, count: 2)
            #expect(await transport.snapshot.count == 3)
            await checkpoints.release(.cleanupRequested)
            let guarded = try await transport.checkpoint(after: 4)[3]
            try await checkpoints.waitUntilReached(.cleanupJoinedInFlight)
            #expect(
                await checkpoints.reachedCount(.cleanupJoinedInFlight) == 1
            )
            #expect(await transport.snapshot.count == 4)
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            #expect(await transport.snapshot.count == 4)
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))

            let firstResult = await first.value
            let secondResult = await second.value
            try firstResult.get()
            try secondResult.get()
            #expect(await transport.snapshot.count == 5)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            first.cancel()
            second.cancel()
            _ = await first.value
            _ = await second.value
            throw error
        }
    }

    @Test(
        "cleanup reply failures retain exact typed identity",
        arguments: InvalidCleanupResult.allCases
    )
    func cleanupReplyFailuresRetainTypedIdentity(
        _ invalidResult: InvalidCleanupResult
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let artifacts = try preservedArtifacts(for: lease.fixture)
        let operation = Task<Result<Void, FixtureCleanupError>, Never> {
            await lease.cleanupResult()
        }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            let sentinels = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            let reply: ProcessReply
            let expected: FixtureCleanupError
            switch invalidResult {
            case .whitespaceOnlyOutput:
                reply = processReply(standardOutput: "\n")
                expected = .malformedSentinel(reply)
            case .malformedSentinel:
                reply = processReply(standardOutput: "not-a-sentinel\n")
                expected = .malformedSentinel(reply)
            case .extraSentinel:
                reply = processReply(
                    standardOutput: "\(sentinels.mismatch)\n\(UUID().uuidString)\n"
                )
                expected = .extraSentinel(reply)
            case .failingResult:
                reply = processReply(
                    standardError: "guard failed\n",
                    exitCode: 23
                )
                expected = .guardRequestFailed(reply)
            }
            await transport.enqueue(.reply(reply))

            let result = await operation.value
            guard case let .failure(actual) = result else {
                Issue.record("invalid cleanup reply unexpectedly succeeded")
                return
            }
            #expect(actual == expected)
            try expectPreservedArtifacts(artifacts, fixture: lease.fixture)
            let firstRequestCount = await transport.snapshot.count
            let cached: Result<Void, FixtureCleanupError> =
                await lease.cleanupResult()
            guard case let .failure(cachedError) = cached else {
                Issue.record("invalid cleanup result was not cached")
                return
            }
            #expect(cachedError == expected)
            try expectPreservedArtifacts(artifacts, fixture: lease.fixture)
            #expect(await transport.snapshot.count == firstRequestCount)
            #expect(await transport.snapshot.count == 4)
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test(
        "uncertain cleanup preserves artifacts without another kill",
        arguments: CleanupUncertainty.allCases
    )
    func uncertainCleanupPreservesArtifacts(
        _ uncertainty: CleanupUncertainty
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let operation = Task<Result<Void, FixtureCleanupError>, Never> {
            await lease.cleanupResult()
        }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            let sentinels = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            let expected: FixtureCleanupError
            switch uncertainty {
            case .disconnect:
                await transport.enqueue(.failure(.disconnected))
                expected = .guardTransportFailure
            case .mismatch:
                let reply = processReply(
                    standardOutput: "\(sentinels.mismatch)\n"
                )
                await transport.enqueue(
                    .reply(reply)
                )
                expected = .ownershipMismatch(reply)
            case .transportFailure:
                await transport.enqueue(.failure(.immediateFailure))
                expected = .guardTransportFailure
            }
            let firstResult = await operation.value
            guard case let .failure(error) = firstResult else {
                Issue.record("uncertain cleanup unexpectedly succeeded")
                return
            }
            #expect(error == expected)
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.runDirectory.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.ownershipMarker.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.socketDirectory.path
                )
            )
            let firstRequestCount = await transport.snapshot.count
            let secondResult = await lease.cleanupResult()
            guard case let .failure(cachedError) = secondResult else {
                Issue.record("uncertain cleanup result was not cached")
                return
            }
            #expect(cachedError == expected)
            #expect(await transport.snapshot.count == firstRequestCount)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("endpoint absence polling repeats exact nonstarting probe")
    func endpointAbsencePollingRepeatsExactProbe() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let operation = Task<Result<Void, FixtureCleanupError>, Never> {
            await lease.cleanupResult()
        }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(
                .reply(processReply())
            )
            let firstProbe = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(firstProbe, fixture: lease.fixture)
            await transport.enqueue(
                .reply(
                    processReply(
                        standardOutput: "\(try socketPath(of: lease.fixture))\n"
                    )
                )
            )
            let secondProbe = try await transport.checkpoint(after: 6)[5]
            try endpointAbsenceRequest(secondProbe, fixture: lease.fixture)
            #expect(secondProbe == firstProbe)
            #expect(secondProbe.arguments.first == "-N")
            await transport.enqueue(.reply(processReply(exitCode: 1)))

            let result = await operation.value
            try result.get()
            #expect(await transport.snapshot.count == 6)
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("noncanonical endpoint probe exit preserves artifacts")
    func noncanonicalEndpointProbeExitPreservesArtifacts() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let artifacts = try preservedArtifacts(for: lease.fixture)
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            let reply = processReply(
                standardError: "probe failed\n",
                exitCode: 23
            )
            await transport.enqueue(.reply(reply))

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("noncanonical endpoint exit unexpectedly removed artifacts")
                return
            }
            #expect(error == .endpointProbeFailed(reply))
            try expectPreservedArtifacts(artifacts, fixture: lease.fixture)
            #expect(
                !FileManager.default.fileExists(
                    atPath: "\(try socketPath(of: lease.fixture)).lock"
                )
            )
            let requestCount = await transport.snapshot.count
            #expect(requestCount == 5)
            guard case let .failure(cachedError) = await lease.cleanupResult() else {
                Issue.record("noncanonical endpoint result was not cached")
                return
            }
            #expect(cachedError == error)
            #expect(await transport.snapshot.count == requestCount)
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("canonical endpoint exit requires connection refusal")
    func canonicalEndpointExitRequiresConnectionRefusal() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let startOperation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(runRoot: root),
                transport: transport
            )
        }
        var listener: Int32 = -1
        var lease: FixtureLease?
        defer {
            if listener >= 0 {
                _ = close(listener)
            }
        }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try candidateArtifacts(from: initial)
            listener = try createListeningUnixSocketArtifact(
                at: candidate.socketPath
            )
            await transport.enqueue([
                .reply(processReply(standardOutput: "\(token.uuidString)\n")),
                .reply(processReply(standardOutput: "\(token.uuidString)\n")),
                .reply(processReply()),
            ])
            let startedLease = try await startOperation.value
            lease = startedLease
            let artifacts = try preservedArtifacts(for: startedLease.fixture)
            let cleanupOperation = Task { await startedLease.cleanupResult() }

            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: startedLease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: startedLease.fixture)
            let reply = processReply(exitCode: 1)
            await transport.enqueue(.reply(reply))

            let result = await cleanupOperation.value
            guard case let .failure(error) = result else {
                Issue.record("live endpoint unexpectedly authorized cleanup")
                return
            }
            #expect(error == .endpointProbeFailed(reply))
            try expectPreservedArtifacts(
                artifacts,
                fixture: startedLease.fixture
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: "\(candidate.socketPath).lock"
                )
            )
        } catch {
            await transport.releaseAll()
            startOperation.cancel()
            _ = try? await startOperation.value
            if let lease {
                _ = await lease.cleanupResult()
            }
            throw error
        }
    }

    @Test("saturated listener cannot pin cleanup past its deadline")
    func saturatedListenerCannotPinCleanupPastDeadline() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let startOperation = Task {
            try await FixtureLease.start(
                configuration: makeConfiguration(
                    runRoot: root,
                    // Only that cleanup ends is under test here. A saturated
                    // listener never unblocks, so the deadline value just has
                    // to outlast this test's own scripted round trips.
                    startupDeadline: .seconds(30),
                    cleanupDeadline: .seconds(5),
                    timing: FixtureLifecycleTiming()
                ),
                transport: transport
            )
        }
        var saturatedListener: SaturatedUnixListener?
        var lease: FixtureLease?
        defer { saturatedListener?.closeAll() }
        do {
            let initial = try await transport.checkpoint(after: 1)[0]
            let token = try candidateToken(from: initial)
            let candidate = try candidateArtifacts(from: initial)
            saturatedListener = try createSaturatedUnixListener(
                at: candidate.socketPath
            )
            await transport.enqueue([
                .reply(processReply(standardOutput: "\(token.uuidString)\n")),
                .reply(processReply(standardOutput: "\(token.uuidString)\n")),
                .reply(processReply()),
            ])
            let startedLease = try await startOperation.value
            lease = startedLease
            let artifacts = try preservedArtifacts(for: startedLease.fixture)
            let completed = CompletionProbe()
            let cleanupOperation = Task {
                let result = await startedLease.cleanupResult()
                await completed.markComplete()
                return result
            }
            do {
                let guarded = try await transport.checkpoint(after: 4)[3]
                _ = try cleanupSentinels(
                    in: guarded,
                    fixture: startedLease.fixture
                )
                await transport.enqueue(.reply(processReply()))
                let absence = try await transport.checkpoint(after: 5)[4]
                try endpointAbsenceRequest(
                    absence,
                    fixture: startedLease.fixture
                )
                let reply = processReply(exitCode: 1)
                await transport.enqueue(.reply(reply))

                try await completed.waitUntilComplete(timeout: .seconds(30))
                let result = await cleanupOperation.value
                guard case let .failure(error) = result else {
                    Issue.record("saturated listener unexpectedly authorized cleanup")
                    return
                }
                #expect(
                    error == .endpointProbeFailed(reply)
                        || error == .deadlineExceeded
                )
                try expectPreservedArtifacts(
                    artifacts,
                    fixture: startedLease.fixture
                )
                #expect(
                    !FileManager.default.fileExists(
                        atPath: "\(candidate.socketPath).lock"
                    )
                )
            } catch {
                try saturatedListener?.releaseOneConnection()
                cleanupOperation.cancel()
                _ = await cleanupOperation.value
                throw error
            }
        } catch {
            await transport.releaseAll()
            startOperation.cancel()
            _ = try? await startOperation.value
            if let lease {
                _ = await lease.cleanupResult()
            }
            throw error
        }
    }

    @Test("missing endpoint corroborates canonical exit")
    func missingEndpointCorroboratesCanonicalExit() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let endpoint = try socketPath(of: lease.fixture)
        guard unlink(endpoint) == 0 else {
            throw FixtureContractError.systemCall(
                operation: "unlink-endpoint-before-absence-probe",
                code: Int32(errno)
            )
        }

        _ = try await cleanupSuccessfully(lease: lease, transport: transport)
        #expect(
            !FileManager.default.fileExists(
                atPath: lease.fixture.runDirectory.path
            )
        )
    }

    @Test("post-validation socket replacement is preserved")
    func postValidationSocketReplacementIsPreserved() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.afterSocketIdentityValidation]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let socketDirectoryIdentity = try pathIdentity(
            of: lease.fixture.socketDirectory
        )
        let ownerIdentity = try pathIdentity(of: lease.fixture.ownershipMarker)
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(.afterSocketIdentityValidation)

            let claimedDirectory = try directory(
                in: lease.fixture.runDirectory,
                matching: socketDirectoryIdentity
            )
            let endpoint = claimedDirectory.appendingPathComponent("s")
            let displacedEndpoint = claimedDirectory.appendingPathComponent(
                "validated-endpoint"
            )
            let ownedIdentity = try pathIdentity(of: endpoint)
            guard rename(endpoint.path, displacedEndpoint.path) == 0 else {
                throw FixtureContractError.systemCall(
                    operation: "rename-validated-endpoint",
                    code: Int32(errno)
                )
            }
            try createUnixSocketArtifact(at: endpoint.path)
            let replacementIdentity = try pathIdentity(of: endpoint)
            #expect(replacementIdentity != ownedIdentity)
            await checkpoints.release(.afterSocketIdentityValidation)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("post-validation replacement cleanup unexpectedly succeeded")
                return
            }
            #expect(
                error
                    == .filesystem(
                        operation: "validate-socket-identity",
                        code: ESTALE
                    )
            )
            #expect(try pathIdentity(of: endpoint) == replacementIdentity)
            #expect(try pathIdentity(of: displacedEndpoint) == ownedIdentity)
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            try expectLockedRecoverySidecar(
                for: lease.fixture,
                expectedIdentity: ownerIdentity
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("claimed socket directory isolates public-path replacement")
    func claimedSocketDirectoryIsolatesPublicPathReplacement() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.afterSocketIdentityValidation]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let socketDirectoryIdentity = try pathIdentity(
            of: lease.fixture.socketDirectory
        )
        let ownedEndpointIdentity = try pathIdentity(
            of: URL(fileURLWithPath: try socketPath(of: lease.fixture))
        )
        let ownerIdentity = try pathIdentity(of: lease.fixture.ownershipMarker)
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(.afterSocketIdentityValidation)

            let claimedDirectory = try directory(
                in: lease.fixture.runDirectory,
                matching: socketDirectoryIdentity
            )
            guard
                claimedDirectory.standardizedFileURL.path
                    != lease.fixture.socketDirectory.standardizedFileURL.path
            else {
                Issue.record("socket directory was not claimed before unlink")
                await checkpoints.release(.afterSocketIdentityValidation)
                _ = await operation.value
                return
            }
            #expect(
                try pathIdentity(
                    of: claimedDirectory.appendingPathComponent("s")
                ) == ownedEndpointIdentity
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: lease.fixture.socketDirectory.path
                )
            )

            try FileManager.default.createDirectory(
                at: lease.fixture.socketDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let replacementEndpoint = URL(
                fileURLWithPath: try socketPath(of: lease.fixture)
            )
            try createUnixSocketArtifact(at: replacementEndpoint.path)
            let replacementIdentity = try pathIdentity(of: replacementEndpoint)
            await checkpoints.release(.afterSocketIdentityValidation)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("public-path replacement cleanup unexpectedly succeeded")
                return
            }
            #expect(
                error
                    == .filesystem(
                        operation: "validate-socket-directory-vacancy",
                        code: ESTALE
                    )
            )
            #expect(
                try pathIdentity(of: replacementEndpoint)
                    == replacementIdentity
            )
            #expect(
                try pathIdentity(
                    of: claimedDirectory.appendingPathComponent("s")
                ) == ownedEndpointIdentity
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            try expectLockedRecoverySidecar(
                for: lease.fixture,
                expectedIdentity: ownerIdentity
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("claimed directory replacement before final validation is preserved")
    func claimedDirectoryReplacementBeforeFinalValidationIsPreserved() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.beforeClaimedSocketDirectoryValidation]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let socketDirectoryIdentity = try pathIdentity(
            of: lease.fixture.socketDirectory
        )
        let ownerIdentity = try pathIdentity(of: lease.fixture.ownershipMarker)
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(
                .beforeClaimedSocketDirectoryValidation
            )

            let claimedDirectory = try directory(
                in: lease.fixture.runDirectory,
                matching: socketDirectoryIdentity
            )
            let displacedDirectory = lease.fixture.runDirectory
                .appendingPathComponent("owned-claimed-directory")
            guard
                rename(
                    claimedDirectory.path,
                    displacedDirectory.path
                ) == 0
            else {
                throw FixtureContractError.systemCall(
                    operation: "rename-claimed-directory-before-removal",
                    code: Int32(errno)
                )
            }
            try FileManager.default.createDirectory(
                at: claimedDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let replacementIdentity = try pathIdentity(of: claimedDirectory)
            #expect(replacementIdentity != socketDirectoryIdentity)
            await checkpoints.release(.beforeClaimedSocketDirectoryValidation)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("claimed-directory replacement cleanup unexpectedly succeeded")
                return
            }
            #expect(
                error
                    == .filesystem(
                        operation: "validate-claimed-socket-directory",
                        code: ESTALE
                    )
            )
            #expect(
                try pathIdentity(of: claimedDirectory)
                    == replacementIdentity
            )
            #expect(
                try pathIdentity(of: displacedDirectory)
                    == socketDirectoryIdentity
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            try expectLockedRecoverySidecar(
                for: lease.fixture,
                expectedIdentity: ownerIdentity
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("cleanup reopens a contended tmux lock after pathname replacement")
    func cleanupReopensContendedTmuxLockAfterReplacement() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let lockPath = "\(try socketPath(of: lease.fixture)).lock"
        var firstLock = try acquireTestSocketLock(at: lockPath)
        var secondLock: Int32 = -1
        defer {
            if firstLock >= 0 { releaseTestSocketLock(firstLock) }
            if secondLock >= 0 { releaseTestSocketLock(secondLock) }
        }
        let operation = Task { await lease.cleanupResult() }

        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            try await checkpoints.waitUntilReached(.socketLockContended)
            #expect(await transport.snapshot.count == 4)

            guard unlink(lockPath) == 0 else {
                throw FixtureContractError.systemCall(
                    operation: "unlink-first-test-socket-lock",
                    code: Int32(errno)
                )
            }
            secondLock = try acquireTestSocketLock(at: lockPath)
            releaseTestSocketLock(firstLock)
            firstLock = -1

            try await checkpoints.waitUntilReached(
                .socketLockContended,
                count: 2
            )
            #expect(await transport.snapshot.count == 4)
            releaseTestSocketLock(secondLock)
            secondLock = -1

            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await operation.value.get()
            #expect(!FileManager.default.fileExists(atPath: lockPath))
            #expect(
                !FileManager.default.fileExists(
                    atPath: lease.fixture.runDirectory.path
                )
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test(
        "post-guard endpoint uncertainty preserves full artifacts",
        arguments: EndpointPollUncertainty.allCases
    )
    func postGuardEndpointUncertaintyPreservesArtifacts(
        _ uncertainty: EndpointPollUncertainty
    ) async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let deadlines = ManualDeadlineHarness()
        let heldCancellations: Set<Int> =
            uncertainty == .deadline ? [5] : []
        let transport = ScriptedProcessTransport(
            checkpointDeadline: harnessDeadline,
            holdCancellationAt: heldCancellations
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                cleanupDeadline: .milliseconds(25),
                deadlineHarness: deadlines
            ),
            transport: transport
        )
        try await deadlines.waitUntilRequested(1, duration: .seconds(2))
        let artifacts = try preservedArtifacts(for: lease.fixture)
        let completed = CompletionProbe()
        let operation = Task<Result<Void, FixtureCleanupError>, Never> {
            let result = await lease.cleanupResult()
            await completed.markComplete()
            return result
        }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(
                in: guarded,
                fixture: lease.fixture
            )
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)

            let expected: FixtureCleanupError
            switch uncertainty {
            case .transportFailure:
                await transport.enqueue(.failure(.immediateFailure))
                expected = .endpointProbeTransportFailure
            case .deadline:
                try await deadlines.waitUntilRequested(
                    2,
                    duration: .milliseconds(25)
                )
                try await deadlines.arm(2)
                try await deadlines.fire(2)
                try await transport.waitUntilRequestCancelled(5)
                #expect(!(await completed.isComplete))
                await transport.releaseRequestCancellation(5)
                expected = .deadlineExceeded
            }

            try await completed.waitUntilComplete()
            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("uncertain endpoint poll unexpectedly succeeded")
                return
            }
            #expect(error == expected)
            if uncertainty == .deadline {
                #expect(await transport.wasRequestCancelled(5))
            }
            try expectPreservedArtifacts(artifacts, fixture: lease.fixture)
            #expect(
                !FileManager.default.fileExists(
                    atPath: "\(try socketPath(of: lease.fixture)).lock"
                )
            )

            let firstRequestCount = await transport.snapshot.count
            let cached = await lease.cleanupResult()
            guard case let .failure(cachedError) = cached else {
                Issue.record("endpoint uncertainty result was not cached")
                return
            }
            #expect(cachedError == expected)
            #expect(await transport.snapshot.count == firstRequestCount)
            #expect(firstRequestCount == 5)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
            try expectPreservedArtifacts(artifacts, fixture: lease.fixture)
        } catch {
            await deadlines.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("replacement after owned exit preserves its endpoint")
    func replacementAfterOwnedExitPreservesEndpoint() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.beforeSocketDirectoryRemoval]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let ownerIdentity = try pathIdentity(of: lease.fixture.ownershipMarker)
        let operation = Task { await lease.cleanupResult() }
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(.beforeSocketDirectoryRemoval)
            let endpoint = URL(fileURLWithPath: try socketPath(of: lease.fixture))
            #expect(
                endpoint.deletingLastPathComponent().standardizedFileURL.path
                    == lease.fixture.socketDirectory.standardizedFileURL.path
            )
            guard unlink(endpoint.path) == 0 else {
                throw FixtureContractError.systemCall(
                    operation: "unlink-owned-socket-for-replacement",
                    code: Int32(errno)
                )
            }
            try Data("replacement".utf8).write(to: endpoint)
            await checkpoints.release(.beforeSocketDirectoryRemoval)

            let result = await operation.value
            expectFailure(result)
            #expect(FileManager.default.fileExists(atPath: endpoint.path))
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.runDirectory.path
                )
            )
            try expectLockedRecoverySidecar(
                for: lease.fixture,
                expectedIdentity: ownerIdentity
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            let firstRequestCount = await transport.snapshot.count
            expectFailure(await lease.cleanupResult())
            #expect(await transport.snapshot.count == firstRequestCount)
            #expect(
                await transport.snapshot.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("same-type socket replacement after owned exit is preserved")
    func sameTypeSocketReplacementAfterOwnedExitIsPreserved() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.beforeSocketDirectoryRemoval]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let preserved = try preservedArtifacts(for: lease.fixture)
        let operation = Task { await lease.cleanupResult() }
        let endpoint = URL(fileURLWithPath: try socketPath(of: lease.fixture))
        let displacedEndpoint = lease.fixture.socketDirectory
            .appendingPathComponent("owned-endpoint")
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(.beforeSocketDirectoryRemoval)

            let ownedEndpointIdentity = try pathIdentity(of: endpoint)
            guard rename(endpoint.path, displacedEndpoint.path) == 0 else {
                throw FixtureContractError.systemCall(
                    operation: "rename-owned-socket-for-socket-replacement",
                    code: Int32(errno)
                )
            }
            try createUnixSocketArtifact(at: endpoint.path)
            let replacementIdentity = try pathIdentity(of: endpoint)
            #expect(replacementIdentity != ownedEndpointIdentity)
            #expect(try pathIdentity(of: displacedEndpoint) == ownedEndpointIdentity)
            #expect(
                try FileManager.default.attributesOfItem(atPath: endpoint.path)[.type]
                    as? FileAttributeType == .typeSocket
            )
            await checkpoints.release(.beforeSocketDirectoryRemoval)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("same-type endpoint replacement cleanup unexpectedly succeeded")
                return
            }
            #expect(
                error
                    == .filesystem(
                        operation: "validate-socket-identity",
                        code: ESTALE
                    )
            )
            try expectPostClaimPreservedArtifacts(
                preserved,
                fixture: lease.fixture,
                endpointIdentity: replacementIdentity
            )
            #expect(try pathIdentity(of: endpoint) == replacementIdentity)
            #expect(try pathIdentity(of: displacedEndpoint) == ownedEndpointIdentity)
            #expect(
                !FileManager.default.fileExists(
                    atPath: "\(try socketPath(of: lease.fixture)).lock"
                )
            )

            let firstRequests = await transport.snapshot
            #expect(firstRequests.count == 5)
            #expect(
                firstRequests.allSatisfy { $0.executable == exactTmuxExecutable }
            )
            guard case let .failure(cachedError) = await lease.cleanupResult() else {
                Issue.record("same-type endpoint replacement result was not cached")
                return
            }
            #expect(cachedError == error)
            #expect(await transport.snapshot.count == firstRequests.count)
            #expect(
                firstRequests.filter {
                    $0.arguments.contains("if-shell")
                }.count == 1
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("socket lock replacement after owned exit is preserved")
    func socketLockReplacementAfterOwnedExitIsPreserved() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.beforeSocketDirectoryRemoval]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let ownerIdentity = try pathIdentity(of: lease.fixture.ownershipMarker)
        let operation = Task { await lease.cleanupResult() }
        let lockPath = "\(try socketPath(of: lease.fixture)).lock"
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(.beforeSocketDirectoryRemoval)

            guard unlink(lockPath) == 0 else {
                throw FixtureContractError.systemCall(
                    operation: "unlink-owned-lock-for-replacement",
                    code: Int32(errno)
                )
            }
            guard
                FileManager.default.createFile(
                    atPath: lockPath,
                    contents: Data("replacement-lock".utf8),
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw FixtureContractError.systemCall(
                    operation: "create-replacement-lock",
                    code: Int32(errno)
                )
            }
            await checkpoints.release(.beforeSocketDirectoryRemoval)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("lock replacement cleanup unexpectedly succeeded")
                return
            }
            #expect(
                error
                    == .filesystem(
                        operation: "validate-socket-lock-identity",
                        code: ESTALE
                    )
            )
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: lockPath))
                    == Data("replacement-lock".utf8))
            try expectLockedRecoverySidecar(
                for: lease.fixture,
                expectedIdentity: ownerIdentity
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("socket directory replacement after owned exit is preserved")
    func socketDirectoryReplacementAfterOwnedExitIsPreserved() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let checkpoints = LifecycleCheckpointHarness(
            blocking: [.beforeSocketDirectoryRemoval]
        )
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(
                runRoot: root,
                checkpointHarness: checkpoints
            ),
            transport: transport
        )
        let ownerIdentity = try pathIdentity(of: lease.fixture.ownershipMarker)
        let operation = Task { await lease.cleanupResult() }
        let movedDirectory = lease.fixture.runDirectory.appendingPathComponent(
            "owned-socket-directory"
        )
        let replacementEntry = lease.fixture.socketDirectory
            .appendingPathComponent("replacement")
        do {
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply()))
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            try await checkpoints.waitUntilReached(.beforeSocketDirectoryRemoval)

            guard
                rename(
                    lease.fixture.socketDirectory.path,
                    movedDirectory.path
                ) == 0
            else {
                throw FixtureContractError.systemCall(
                    operation: "rename-owned-socket-directory",
                    code: Int32(errno)
                )
            }
            try FileManager.default.createDirectory(
                at: lease.fixture.socketDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try Data("replacement-directory".utf8).write(to: replacementEntry)
            await checkpoints.release(.beforeSocketDirectoryRemoval)

            let result = await operation.value
            guard case let .failure(error) = result else {
                Issue.record("directory replacement cleanup unexpectedly succeeded")
                return
            }
            #expect(
                error
                    == .filesystem(
                        operation: "lstat-socket-directory-before-unlink",
                        code: ESTALE
                    )
            )
            #expect(try Data(contentsOf: replacementEntry) == Data("replacement-directory".utf8))
            #expect(FileManager.default.fileExists(atPath: movedDirectory.path))
            try expectLockedRecoverySidecar(
                for: lease.fixture,
                expectedIdentity: ownerIdentity
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
        } catch {
            await checkpoints.releaseAll()
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("cleanup removes known files with nonrecursive directory removal")
    func cleanupRemovesKnownFilesNonrecursively() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let lease = try await startOwnedFixture(
            configuration: makeConfiguration(runRoot: root),
            transport: transport
        )
        let operation = Task { await lease.cleanupResult() }
        let unknown = lease.fixture.runDirectory.appendingPathComponent("unknown")
        do {
            try Data("preserve".utf8).write(to: unknown)
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: lease.fixture)
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: lease.fixture)
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.ownershipMarker.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            let result = await operation.value
            expectFailure(result)

            #expect(FileManager.default.fileExists(atPath: unknown.path))
            #expect(
                !FileManager.default.fileExists(
                    atPath: lease.fixture.ownershipMarker.path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: lease.fixture.configurationFile.path
                )
            )
            #expect(
                !FileManager.default.fileExists(
                    atPath: lease.fixture.socketDirectory.path
                )
            )
            #expect(
                FileManager.default.fileExists(
                    atPath: lease.fixture.runDirectory.path
                )
            )
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = await operation.value
            throw error
        }
    }

    @Test("withTmuxServer returns body value after cleanup")
    func withTmuxServerReturnsBodyValueAfterCleanup() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let failures = CleanupFailureRecorder()
        let capture = FixtureCapture()
        let bodyGate = AsyncGate()
        let operation = Task {
            try await withTmuxServer(
                configuration: makeConfiguration(runRoot: root),
                transport: transport,
                secondaryCleanupFailureSink: { error in
                    await failures.record(error)
                }
            ) { fixture in
                await capture.record(fixture)
                try await bodyGate.wait(timeout: .seconds(30))
                return 42
            }
        }
        do {
            _ = try await primeSuccessfulStart(transport: transport)
            let fixture = try await capture.wait()
            await bodyGate.open()
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: fixture)
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))
            #expect(try await operation.value == 42)
            #expect(await failures.errors.isEmpty)
        } catch {
            await bodyGate.open()
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("body error remains primary when cleanup also fails")
    func bodyErrorRemainsPrimaryWhenCleanupFails() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let failures = CleanupFailureRecorder()
        let capture = FixtureCapture()
        let operation = Task<Void, any Error> {
            try await withTmuxServer(
                configuration: makeConfiguration(runRoot: root),
                transport: transport,
                secondaryCleanupFailureSink: { error in
                    await failures.record(error)
                }
            ) { fixture in
                await capture.record(fixture)
                throw PrimaryFixtureError.body
            }
        }
        do {
            _ = try await primeSuccessfulStart(transport: transport)
            _ = try await capture.wait()
            _ = try await transport.checkpoint(after: 4)
            let invalidReply = processReply(
                standardOutput: "not-a-cleanup-sentinel\n"
            )
            let expectedCleanupError = FixtureCleanupError.malformedSentinel(
                invalidReply
            )
            await transport.enqueue(.reply(invalidReply))

            var preservedPrimary = false
            do {
                try await operation.value
            } catch PrimaryFixtureError.body {
                preservedPrimary = true
            } catch {
                Issue.record("cleanup replaced primary body error: \(error)")
            }
            #expect(preservedPrimary)
            #expect(await failures.errors == [expectedCleanupError])
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("cleanup error fails a successful body")
    func cleanupErrorFailsSuccessfulBody() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let failures = CleanupFailureRecorder()
        let capture = FixtureCapture()
        let operation = Task<Int, any Error> {
            try await withTmuxServer(
                configuration: makeConfiguration(runRoot: root),
                transport: transport,
                secondaryCleanupFailureSink: { error in
                    await failures.record(error)
                }
            ) { fixture in
                await capture.record(fixture)
                return 7
            }
        }
        do {
            _ = try await primeSuccessfulStart(transport: transport)
            _ = try await capture.wait()
            _ = try await transport.checkpoint(after: 4)
            let invalidReply = processReply(
                standardOutput: "not-a-cleanup-sentinel\n"
            )
            let expectedCleanupError = FixtureCleanupError.malformedSentinel(
                invalidReply
            )
            await transport.enqueue(.reply(invalidReply))

            var surfacedCleanupError: FixtureCleanupError?
            do {
                _ = try await operation.value
            } catch let error as FixtureCleanupError {
                surfacedCleanupError = error
            } catch {
                Issue.record("expected typed cleanup error, got \(error)")
            }
            #expect(surfacedCleanupError == expectedCleanupError)
            #expect(await failures.errors.isEmpty)
        } catch {
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("cooperative cancellation awaits noncancelled cleanup")
    func cooperativeCancellationAwaitsCleanup() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let transport = ScriptedProcessTransport()
        let failures = CleanupFailureRecorder()
        let capture = FixtureCapture()
        let bodyGate = AsyncGate()
        let operation = Task<Void, any Error> {
            try await withTmuxServer(
                configuration: makeConfiguration(runRoot: root),
                transport: transport,
                secondaryCleanupFailureSink: { error in
                    await failures.record(error)
                }
            ) { fixture in
                await capture.record(fixture)
                try await bodyGate.wait(timeout: .seconds(30))
                try Task.checkCancellation()
            }
        }
        do {
            _ = try await primeSuccessfulStart(transport: transport)
            let fixture = try await capture.wait()
            operation.cancel()
            await bodyGate.open()
            let guarded = try await transport.checkpoint(after: 4)[3]
            _ = try cleanupSentinels(in: guarded, fixture: fixture)
            await transport.enqueue(
                .reply(processReply())
            )
            let absence = try await transport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(absence, fixture: fixture)
            await transport.enqueue(.reply(processReply(exitCode: 1)))

            var cancellationObserved = false
            do {
                try await operation.value
            } catch is CancellationError {
                cancellationObserved = true
            } catch {
                Issue.record("expected cancellation, got \(error)")
            }
            #expect(cancellationObserved)
            #expect(await failures.errors.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.runDirectory.path))
        } catch {
            await bodyGate.open()
            await transport.releaseAll()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test("concurrent fixtures mint unique directories endpoints and identities")
    func concurrentFixturesAreUnique() async throws {
        let fakeScope = try FakeOnlyCleanupScope()
        let root = fakeScope.runRoot
        defer { fakeScope.finish() }
        let leftTransport = ScriptedProcessTransport()
        let rightTransport = ScriptedProcessTransport()
        let leftCapture = FixtureCapture()
        let rightCapture = FixtureCapture()
        let leftGate = AsyncGate()
        let rightGate = AsyncGate()
        let leftFailures = CleanupFailureRecorder()
        let rightFailures = CleanupFailureRecorder()

        let left = Task<TmuxFixture, any Error> {
            try await withTmuxServer(
                configuration: makeConfiguration(runRoot: root),
                transport: leftTransport,
                secondaryCleanupFailureSink: { error in
                    await leftFailures.record(error)
                }
            ) { fixture in
                await leftCapture.record(fixture)
                try await leftGate.wait(timeout: .seconds(30))
                return fixture
            }
        }
        let right = Task<TmuxFixture, any Error> {
            try await withTmuxServer(
                configuration: makeConfiguration(runRoot: root),
                transport: rightTransport,
                secondaryCleanupFailureSink: { error in
                    await rightFailures.record(error)
                }
            ) { fixture in
                await rightCapture.record(fixture)
                try await rightGate.wait(timeout: .seconds(30))
                return fixture
            }
        }

        do {
            _ = try await primeSuccessfulStart(transport: leftTransport)
            _ = try await primeSuccessfulStart(transport: rightTransport)
            let leftFixture = try await leftCapture.wait()
            let rightFixture = try await rightCapture.wait()
            #expect(leftFixture.runDirectory != rightFixture.runDirectory)
            #expect(leftFixture.socketDirectory != rightFixture.socketDirectory)
            #expect(leftFixture.endpoint != rightFixture.endpoint)
            #expect(leftFixture.incarnation != rightFixture.incarnation)
            let leftRequests = await leftTransport.snapshot
            let rightRequests = await rightTransport.snapshot
            guard let leftEnvironment = leftRequests.first?.environment,
                let rightEnvironment = rightRequests.first?.environment
            else {
                throw FixtureContractError.missingConfiguration
            }
            let scratch = inputChildEnvironment.temporaryDirectory
            #expect(leftEnvironment["TMPDIR"] == scratch)
            #expect(rightEnvironment["TMPDIR"] == scratch)
            #expect(!scratch.hasPrefix(root.path))

            await leftGate.open()
            await rightGate.open()
            let leftGuard = try await leftTransport.checkpoint(after: 4)[3]
            let rightGuard = try await rightTransport.checkpoint(after: 4)[3]
            let leftSentinels = try cleanupSentinels(
                in: leftGuard,
                fixture: leftFixture
            )
            let rightSentinels = try cleanupSentinels(
                in: rightGuard,
                fixture: rightFixture
            )
            #expect(
                Set([
                    leftSentinels.mismatch,
                    rightSentinels.mismatch,
                ]).count == 2
            )
            await leftTransport.enqueue(
                .reply(processReply())
            )
            await rightTransport.enqueue(
                .reply(processReply())
            )
            let leftAbsence = try await leftTransport.checkpoint(after: 5)[4]
            let rightAbsence = try await rightTransport.checkpoint(after: 5)[4]
            try endpointAbsenceRequest(leftAbsence, fixture: leftFixture)
            try endpointAbsenceRequest(rightAbsence, fixture: rightFixture)
            await leftTransport.enqueue(.reply(processReply(exitCode: 1)))
            await rightTransport.enqueue(.reply(processReply(exitCode: 1)))
            _ = try await left.value
            _ = try await right.value
            #expect(await leftFailures.errors.isEmpty)
            #expect(await rightFailures.errors.isEmpty)
        } catch {
            await leftGate.open()
            await rightGate.open()
            await leftTransport.releaseAll()
            await rightTransport.releaseAll()
            left.cancel()
            right.cancel()
            _ = try? await left.value
            _ = try? await right.value
            throw error
        }
    }
}
