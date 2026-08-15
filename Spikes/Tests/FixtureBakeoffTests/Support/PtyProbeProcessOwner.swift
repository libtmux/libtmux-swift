import Dispatch
import Foundation

@testable import PtyClientProbe
@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import Darwin
    import os
#else
    import Glibc
    import Synchronization
#endif

private func closePtyDescriptor(_ descriptor: Int32) -> Int32 {
    #if canImport(Darwin)
        Darwin.close(descriptor)
    #else
        Glibc.close(descriptor)
    #endif
}

enum PtyClientContractError: Error, Sendable, Equatable {
    case deadlineExceeded
    case invalidClientRecord
    case invalidLengthPrefixedOutput
    case invalidProcessMarker
    case invalidProcessRelationship
    case invalidReadiness
    case ioFailure(operation: String, code: Int32)
    case missingEnvironment(String)
    case ownedProcessRemains(Int32)
    case processSignalFailed(signal: Int32, code: Int32)
    case sessionFailed
    case spawnFailed
    case tmuxTransportFailed
    case unexpectedEndpoint
    case unexpectedTmuxReply(ProcessReply)
    case waitFailed(Int32)
}

actor TerminalTranscript {
    private var bytes: [UInt8] = []

    func append(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
    }

    func contains(_ text: String) -> Bool {
        Data(bytes).range(of: Data(text.utf8)) != nil
    }

    func snapshot() -> [UInt8] {
        bytes
    }
}

private enum PtyReadinessObservation: Sendable {
    case failed
    case pending
    case ready(PtyClientReadiness)
}

private actor PtyReadinessState {
    private var observation = PtyReadinessObservation.pending

    func publish(_ readiness: PtyClientReadiness) throws {
        guard case .pending = observation else {
            throw PtyClientContractError.invalidReadiness
        }
        observation = .ready(readiness)
    }

    func fail() {
        observation = .failed
    }

    func current() -> PtyReadinessObservation {
        observation
    }
}

private enum PtyWaitObservation: Sendable {
    case failed(Int32)
    case pending
    case reaped(ProcessTermination)
}

private enum PtyWaitOutcome: Sendable {
    case failure(Int32)
    case success(ProcessTermination)
}

enum PtyProbeTerminalObservation: Sendable {
    case failed(Int32)
    case pinned
}

struct PtyProbeWaitHooks: Sendable {
    let observeTerminal: @Sendable (pid_t) -> PtyProbeTerminalObservation
    let signalProcess: @Sendable (pid_t, Int32) -> Int32

    init(
        observeTerminal: @escaping @Sendable (pid_t) -> PtyProbeTerminalObservation =
            observePtyProbeTerminal,
        signalProcess: @escaping @Sendable (pid_t, Int32) -> Int32 =
            signalPtyProbeProcess
    ) {
        self.observeTerminal = observeTerminal
        self.signalProcess = signalProcess
    }
}

private enum PtyWaitIDRecovery: Sendable {
    case lost
    case needsBoundedReap
    case reaped
}

private actor PtyWaitState {
    private var observation = PtyWaitObservation.pending

    func fail(_ code: Int32) {
        observation = .failed(code)
    }

    func finish(_ termination: ProcessTermination) {
        observation = .reaped(termination)
    }

    func current() -> PtyWaitObservation {
        observation
    }
}

private enum PtyReaderObservation: Sendable {
    case failed(PtyClientContractError)
    case pending
    case succeeded
}

private actor PtyReaderState {
    private var observation = PtyReaderObservation.pending

    func fail(_ error: PtyClientContractError) {
        observation = .failed(error)
    }

    func finish() {
        observation = .succeeded
    }

    func current() -> PtyReaderObservation {
        observation
    }
}

private enum PtyDescriptorRead: Sendable {
    case bytes([UInt8])
    case end
    case pending
}

private final class PtyReaderDescriptor: Sendable {
    #if canImport(Darwin)
        private let descriptor: OSAllocatedUnfairLock<Int32?>
    #else
        private let descriptor: Mutex<Int32?>
    #endif

    init(_ descriptor: Int32) {
        #if canImport(Darwin)
            self.descriptor = OSAllocatedUnfairLock(initialState: descriptor)
        #else
            self.descriptor = Mutex(descriptor)
        #endif
    }

    var isClosed: Bool {
        descriptor.withLock { $0 == nil }
    }

    func close() {
        descriptor.withLock { descriptor in
            guard let openDescriptor = descriptor else { return }
            descriptor = nil
            _ = closePtyDescriptor(openDescriptor)
        }
    }

    fileprivate func readOnce() throws -> PtyDescriptorRead {
        try descriptor.withLock { descriptor in
            guard let descriptor else { return .end }
            var descriptorState = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = poll(&descriptorState, 1, 10)
            if pollResult < 0 {
                if errno == EINTR { return .pending }
                throw PtyClientContractError.ioFailure(operation: "poll", code: errno)
            }
            if pollResult == 0 { return .pending }
            if descriptorState.revents & Int16(POLLNVAL) != 0 {
                throw PtyClientContractError.ioFailure(operation: "poll", code: EBADF)
            }

            var bytes = [UInt8](repeating: 0, count: 32 * 1024)
            var count: Int
            repeat {
                count = read(descriptor, &bytes, bytes.count)
            } while count < 0 && errno == EINTR
            if count > 0 { return .bytes(Array(bytes[..<count])) }
            if count == 0 { return .end }
            throw PtyClientContractError.ioFailure(operation: "read", code: errno)
        }
    }
}

private struct PtyReaderTaskOwner: Sendable {
    let descriptor: PtyReaderDescriptor
    let task: Task<Void, Never>

    init(
        descriptor: Int32,
        operation: @escaping @Sendable (PtyReaderDescriptor) async -> Void
    ) {
        let descriptor = PtyReaderDescriptor(descriptor)
        self.descriptor = descriptor
        task = Task {
            defer { descriptor.close() }
            await operation(descriptor)
        }
    }

    func join() async {
        await task.value
    }

    func cancelCloseAndJoin() async {
        task.cancel()
        descriptor.close()
        await task.value
    }
}

private actor UncancelledPtyReaderGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func opened() -> Bool {
        isOpen
    }
}

private actor BlockedPtyReaderCleanupState {
    private var didReturn = false

    func markReturned() {
        didReturn = true
    }

    func returned() -> Bool {
        didReturn
    }
}

final class BlockedPtyReaderCleanupProbe: Sendable {
    private let writer: PtyReaderDescriptor
    private let reader: PtyReaderTaskOwner
    private let reading = UncancelledPtyReaderGate()
    private let readerExited = UncancelledPtyReaderGate()
    private let readerMayFinish = UncancelledPtyReaderGate()
    private let state = BlockedPtyReaderCleanupState()

    private init(writer: Int32, readerDescriptor: Int32) {
        self.writer = PtyReaderDescriptor(writer)
        let reading = reading
        let readerExited = readerExited
        let readerMayFinish = readerMayFinish
        reader = PtyReaderTaskOwner(descriptor: readerDescriptor) { descriptor in
            await reading.open()
            do {
                while try await readPtyDescriptor(descriptor) != nil {}
            } catch {}
            await readerExited.open()
            await readerMayFinish.wait()
        }
    }

    static func start() throws -> BlockedPtyReaderCleanupProbe {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw PtyClientContractError.ioFailure(operation: "pipe", code: errno)
        }
        return BlockedPtyReaderCleanupProbe(
            writer: descriptors[1],
            readerDescriptor: descriptors[0]
        )
    }

    var descriptorIsClosed: Bool {
        reader.descriptor.isClosed && writer.isClosed
    }

    func waitUntilReading() async throws {
        try await waitForPtyReaderGate(reading)
    }

    func waitUntilReaderExited() async throws {
        try await waitForPtyReaderGate(readerExited)
    }

    func allowReaderToFinish() async {
        await readerMayFinish.open()
    }

    func cancelCloseAndJoin() async {
        await reader.cancelCloseAndJoin()
        writer.close()
        await state.markReturned()
    }

    func cleanupReturned() async -> Bool {
        await state.returned()
    }
}

private func waitForPtyReaderGate(
    _ gate: UncancelledPtyReaderGate,
    within duration: Duration = .seconds(30)
) async throws {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        if await gate.opened() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PtyClientContractError.deadlineExceeded
}

private struct LockedPtyProbeState: Sendable {
    let processIdentifier: pid_t
    var childProcessGroup: pid_t?
    var inputDescriptor: Int32?
    var reaped = false
    var signalsOpen = true
    var terminalObserved = false
}

private struct PtyProbeControlFailure: Sendable {
    let signal: Int32
    let code: Int32
}

private final class SerializedPtyProbeState: Sendable {
    #if canImport(Darwin)
        private let state: OSAllocatedUnfairLock<LockedPtyProbeState>
    #else
        private let state: Mutex<LockedPtyProbeState>
    #endif

    init(processIdentifier: pid_t, inputDescriptor: Int32?) {
        let initialState = LockedPtyProbeState(
            processIdentifier: processIdentifier,
            inputDescriptor: inputDescriptor
        )
        #if canImport(Darwin)
            state = OSAllocatedUnfairLock(initialState: initialState)
        #else
            state = Mutex(initialState)
        #endif
    }

    var processIdentifier: pid_t {
        state.withLock { $0.processIdentifier }
    }

    func writeStandardInput(_ bytes: [UInt8]) throws {
        try state.withLock { state in
            guard !state.terminalObserved, let descriptor = state.inputDescriptor else {
                throw PtyClientContractError.ioFailure(operation: "stdin", code: EBADF)
            }
            switch writePOSIXDescriptorSynchronously(descriptor, bytes: bytes) {
            case .success:
                return
            case let .failure(error):
                if let invocationError = error as? ProcessInvocationError,
                    case let .ioFailure(_, code) = invocationError
                {
                    throw PtyClientContractError.ioFailure(operation: "stdin", code: code)
                }
                throw PtyClientContractError.ioFailure(operation: "stdin", code: EIO)
            }
        }
    }

    func finishStandardInput() throws {
        try state.withLock { state in
            guard let descriptor = state.inputDescriptor else { return }
            state.inputDescriptor = nil
            guard close(descriptor) == 0 else {
                throw PtyClientContractError.ioFailure(operation: "close-stdin", code: errno)
            }
        }
    }

    func signalProbe(_ signal: Int32) throws {
        try state.withLock { state in
            guard state.signalsOpen, !state.reaped,
                getpgid(state.processIdentifier) == state.processIdentifier
            else {
                throw PtyClientContractError.invalidProcessRelationship
            }
            guard kill(state.processIdentifier, signal) == 0 else {
                throw PtyClientContractError.processSignalFailed(signal: signal, code: errno)
            }
        }
    }

    func retainDecodedReadiness(_ readiness: PtyClientReadiness) throws {
        try state.withLock { state in
            let child = pid_t(readiness.childPID)
            let childGroup = pid_t(readiness.childProcessGroupID)
            guard readiness.probePID == state.processIdentifier,
                readiness.childParentPID == state.processIdentifier,
                readiness.childWasStoppedBeforeReadiness,
                child > 0,
                childGroup == child,
                state.childProcessGroup == nil || state.childProcessGroup == childGroup
            else {
                throw PtyClientContractError.invalidProcessRelationship
            }

            errno = 0
            let observedGroup = getpgid(child)
            guard observedGroup == childGroup || (observedGroup < 0 && errno == ESRCH) else {
                throw PtyClientContractError.invalidProcessRelationship
            }
            state.childProcessGroup = childGroup
        }
    }

    func beginGracefulTermination() -> PtyProbeControlFailure? {
        state.withLock { state -> PtyProbeControlFailure? in
            guard state.signalsOpen, !state.reaped else { return nil }
            var firstFailure: PtyProbeControlFailure?

            for signal in [SIGTERM, SIGCONT] {
                recordSignalFailure(
                    kill(state.processIdentifier, signal),
                    signal: signal,
                    firstFailure: &firstFailure
                )
            }
            return firstFailure
        }
    }

    func forceKill() -> PtyProbeControlFailure? {
        state.withLock { state -> PtyProbeControlFailure? in
            guard state.signalsOpen, !state.reaped else { return nil }
            var firstFailure: PtyProbeControlFailure?
            recordSignalFailure(
                kill(state.processIdentifier, SIGKILL),
                signal: SIGKILL,
                firstFailure: &firstFailure
            )
            return firstFailure
        }
    }

    func observeTerminal() {
        state.withLock { state in
            state.terminalObserved = true
            state.signalsOpen = false
            closeInput(state: &state)
        }
    }

    func recoverFromWaitIDFailure(
        hooks: PtyProbeWaitHooks
    ) -> PtyWaitIDRecovery {
        state.withLock { state in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                errno = 0
                result = waitpid(state.processIdentifier, &status, WNOHANG)
            } while result < 0 && errno == EINTR

            if result == state.processIdentifier {
                state.reaped = true
                state.terminalObserved = true
                state.signalsOpen = false
                closeInput(state: &state)
                return .reaped
            }
            guard result == 0 else {
                state.terminalObserved = true
                state.signalsOpen = false
                closeInput(state: &state)
                return .lost
            }

            _ = hooks.signalProcess(state.processIdentifier, SIGTERM)
            state.terminalObserved = true
            state.signalsOpen = false
            closeInput(state: &state)
            return .needsBoundedReap
        }
    }

    func markReaped() {
        state.withLock { state in
            state.reaped = true
            state.signalsOpen = false
            closeInput(state: &state)
        }
    }

    private func closeInput(state: inout LockedPtyProbeState) {
        guard let descriptor = state.inputDescriptor else { return }
        state.inputDescriptor = nil
        _ = close(descriptor)
    }

    private func recordSignalFailure(
        _ result: Int32,
        signal: Int32,
        firstFailure: inout PtyProbeControlFailure?
    ) {
        let code = errno
        if result != 0, code != ESRCH, firstFailure == nil {
            firstFailure = PtyProbeControlFailure(signal: signal, code: code)
        }
    }

}

private actor PtyProbeCleanupCoordinator {
    private var cleanup: Task<Result<ProcessTermination, PtyClientContractError>, Never>?

    func stopAndReap(
        owner: PtyProbeProcessOwner,
        readiness: PtyClientReadiness?
    ) async -> Result<ProcessTermination, PtyClientContractError> {
        if let cleanup { return await cleanup.value }
        let cleanup = Task.detached {
            () -> Result<
                ProcessTermination, PtyClientContractError
            > in
            do {
                try? owner.finishStandardInput()
                var readinessFailure: PtyClientContractError?
                if let readiness {
                    do {
                        try owner.state.retainDecodedReadiness(readiness)
                    } catch let error as PtyClientContractError {
                        readinessFailure = error
                    } catch {
                        readinessFailure = .sessionFailed
                    }
                }
                if let termination = try await owner.waitIfComplete(
                    within: .milliseconds(250)
                ) {
                    if let readinessFailure { return .failure(readinessFailure) }
                    return .success(termination)
                }
                var controlFailure = owner.state.beginGracefulTermination()
                if let termination = try await owner.waitIfComplete(
                    within: .milliseconds(750)
                ) {
                    if let controlFailure {
                        return .failure(
                            .processSignalFailed(
                                signal: controlFailure.signal,
                                code: controlFailure.code
                            )
                        )
                    }
                    if let readinessFailure { return .failure(readinessFailure) }
                    return .success(termination)
                }
                if let killFailure = owner.state.forceKill(), controlFailure == nil {
                    controlFailure = killFailure
                }
                guard
                    let termination = try await owner.waitIfComplete(
                        within: .seconds(30)
                    )
                else {
                    return .failure(.deadlineExceeded)
                }
                if let controlFailure {
                    return .failure(
                        .processSignalFailed(
                            signal: controlFailure.signal,
                            code: controlFailure.code
                        )
                    )
                }
                if let readinessFailure { return .failure(readinessFailure) }
                return .success(termination)
            } catch let error as PtyClientContractError {
                return .failure(error)
            } catch {
                return .failure(.sessionFailed)
            }
        }
        self.cleanup = cleanup
        return await cleanup.value
    }
}

final class PtyProbeProcessOwner: Sendable {
    fileprivate let state: SerializedPtyProbeState
    private let readinessState: PtyReadinessState
    private let waitState: PtyWaitState
    private let waitOwner: Task<Void, Never>
    private let readinessOwner: PtyReaderTaskOwner
    private let terminalOwner: PtyReaderTaskOwner
    private let readinessReaderState: PtyReaderState
    private let terminalReaderState: PtyReaderState
    private let cleanupCoordinator = PtyProbeCleanupCoordinator()

    let transcript: TerminalTranscript

    private init(
        state: SerializedPtyProbeState,
        readinessState: PtyReadinessState,
        waitState: PtyWaitState,
        waitOwner: Task<Void, Never>,
        readinessOwner: PtyReaderTaskOwner,
        terminalOwner: PtyReaderTaskOwner,
        readinessReaderState: PtyReaderState,
        terminalReaderState: PtyReaderState,
        transcript: TerminalTranscript
    ) {
        self.state = state
        self.readinessState = readinessState
        self.waitState = waitState
        self.waitOwner = waitOwner
        self.readinessOwner = readinessOwner
        self.terminalOwner = terminalOwner
        self.readinessReaderState = readinessReaderState
        self.terminalReaderState = terminalReaderState
        self.transcript = transcript
    }

    static func launch(
        executable: String,
        arguments: [String],
        environment: [String: String],
        waitHooks: PtyProbeWaitHooks = PtyProbeWaitHooks()
    ) throws -> PtyProbeProcessOwner {
        let process: SpawnedPOSIXProcess
        do {
            process = try spawnPOSIX(
                request: ProcessRequest(
                    executable: .path(executable),
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: nil,
                    outputPolicy: .complete
                ),
                interactive: true
            )
        } catch {
            throw PtyClientContractError.spawnFailed
        }
        let state = SerializedPtyProbeState(
            processIdentifier: process.processIdentifier,
            inputDescriptor: process.standardInput
        )
        let readinessState = PtyReadinessState()
        let readinessReaderState = PtyReaderState()
        let transcript = TerminalTranscript()
        let readinessOwner = PtyReaderTaskOwner(
            descriptor: process.standardOutput
        ) { descriptor in
            do {
                try await readPtyReadiness(
                    descriptor: descriptor,
                    state: readinessState,
                    processState: state
                )
                await readinessReaderState.finish()
            } catch {
                await readinessState.fail()
                await readinessReaderState.fail(ptyContractError(error))
            }
        }
        let terminalReaderState = PtyReaderState()
        let terminalOwner = PtyReaderTaskOwner(
            descriptor: process.standardError
        ) { descriptor in
            do {
                while let bytes = try await readPtyDescriptor(descriptor) {
                    await transcript.append(bytes)
                }
                await terminalReaderState.finish()
            } catch {
                await terminalReaderState.fail(ptyContractError(error))
            }
        }
        let waitState = PtyWaitState()
        let waitOwner = makePtyWaitOwner(
            processIdentifier: process.processIdentifier,
            state: state,
            waitState: waitState,
            hooks: waitHooks
        )
        return PtyProbeProcessOwner(
            state: state,
            readinessState: readinessState,
            waitState: waitState,
            waitOwner: waitOwner,
            readinessOwner: readinessOwner,
            terminalOwner: terminalOwner,
            readinessReaderState: readinessReaderState,
            terminalReaderState: terminalReaderState,
            transcript: transcript
        )
    }

    var processIdentifier: pid_t {
        state.processIdentifier
    }

    func writeStandardInput(_ bytes: [UInt8]) throws {
        try state.writeStandardInput(bytes)
    }

    func finishStandardInput() throws {
        try state.finishStandardInput()
    }

    func sendSignal(_ signal: Int32) throws {
        try state.signalProbe(signal)
    }

    func waitForReadiness(
        within duration: Duration = .seconds(30)
    ) async throws -> PtyClientReadiness {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            switch await readinessState.current() {
            case .failed:
                throw PtyClientContractError.invalidReadiness
            case .pending:
                try await Task.sleep(for: .milliseconds(10))
            case let .ready(readiness):
                return readiness
            }
        }
        throw PtyClientContractError.deadlineExceeded
    }

    func waitIfComplete(
        within duration: Duration
    ) async throws -> ProcessTermination? {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            switch await waitState.current() {
            case let .failed(code):
                throw PtyClientContractError.waitFailed(code)
            case .pending:
                try await Task.sleep(for: .milliseconds(10))
            case let .reaped(termination):
                return try await joinReaders(returning: termination)
            }
        }
        switch await waitState.current() {
        case let .failed(code):
            throw PtyClientContractError.waitFailed(code)
        case .pending:
            return nil
        case let .reaped(termination):
            return try await joinReaders(returning: termination)
        }
    }

    func stopAndReap(
        readiness: PtyClientReadiness?
    ) async throws -> ProcessTermination {
        switch await cleanupCoordinator.stopAndReap(owner: self, readiness: readiness) {
        case let .success(termination):
            return termination
        case let .failure(error):
            throw error
        }
    }

    private func joinReaders(
        returning termination: ProcessTermination
    ) async throws -> ProcessTermination {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            let readiness = await readinessReaderState.current()
            let terminal = await terminalReaderState.current()
            switch (readiness, terminal) {
            case let (.failed(error), _), let (_, .failed(error)):
                await cancelCloseAndJoinReaders()
                throw error
            case (.succeeded, .succeeded):
                await waitOwner.value
                await readinessOwner.join()
                await terminalOwner.join()
                return termination
            default:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await cancelCloseAndJoinReaders()
        let readiness = await readinessReaderState.current()
        let terminal = await terminalReaderState.current()
        if case let .failed(error) = readiness { throw error }
        if case let .failed(error) = terminal { throw error }
        throw PtyClientContractError.deadlineExceeded
    }

    private func cancelCloseAndJoinReaders() async {
        readinessOwner.task.cancel()
        terminalOwner.task.cancel()
        readinessOwner.descriptor.close()
        terminalOwner.descriptor.close()
        await readinessOwner.join()
        await terminalOwner.join()
    }
}

private func makePtyWaitOwner(
    processIdentifier: pid_t,
    state: SerializedPtyProbeState,
    waitState: PtyWaitState,
    hooks: PtyProbeWaitHooks
) -> Task<Void, Never> {
    Task.detached {
        let outcome: PtyWaitOutcome = await withCheckedContinuation {
            continuation in
            DispatchQueue.global().async {
                let observation = hooks.observeTerminal(processIdentifier)
                let waitIDError: Int32
                let shouldBlockForReap: Bool
                var waited: pid_t
                var status: Int32 = 0
                var waitError: Int32 = 0
                switch observation {
                case .pinned:
                    waitIDError = 0
                    shouldBlockForReap = true
                    waited = 0
                    state.observeTerminal()
                case let .failed(code):
                    waitIDError = code
                    switch state.recoverFromWaitIDFailure(hooks: hooks) {
                    case .reaped:
                        shouldBlockForReap = false
                        waited = processIdentifier
                    case .needsBoundedReap:
                        shouldBlockForReap = false
                        let recovery = reapPtyProbeAfterWaitIDFailure(
                            processIdentifier,
                            hooks: hooks
                        )
                        waited = recovery.waited
                        status = recovery.status
                        waitError = recovery.error
                    case .lost:
                        shouldBlockForReap = false
                        waited = -1
                    }
                }

                if shouldBlockForReap {
                    repeat {
                        errno = 0
                        waited = waitpid(processIdentifier, &status, 0)
                    } while waited < 0 && errno == EINTR
                    waitError = errno
                }
                if waited == processIdentifier { state.markReaped() }

                if waited == processIdentifier, waitIDError == 0 {
                    continuation.resume(
                        returning: .success(ptyTerminationFromWaitStatus(status))
                    )
                } else {
                    continuation.resume(
                        returning: .failure(waitIDError != 0 ? waitIDError : waitError)
                    )
                }
            }
        }
        switch outcome {
        case let .success(termination):
            await waitState.finish(termination)
        case let .failure(code):
            await waitState.fail(code)
        }
    }
}

private func reapPtyProbeAfterWaitIDFailure(
    _ processIdentifier: pid_t,
    hooks: PtyProbeWaitHooks
) -> (waited: pid_t, status: Int32, error: Int32) {
    var status: Int32 = 0
    for _ in 0..<75 {
        var waited: pid_t
        repeat {
            errno = 0
            waited = waitpid(processIdentifier, &status, WNOHANG)
        } while waited < 0 && errno == EINTR
        if waited != 0 { return (waited, status, errno) }
        _ = usleep(10_000)
    }

    _ = hooks.signalProcess(processIdentifier, SIGKILL)
    var waited: pid_t
    repeat {
        errno = 0
        waited = waitpid(processIdentifier, &status, 0)
    } while waited < 0 && errno == EINTR
    return (waited, status, errno)
}

func observePtyProbeTerminal(_ processIdentifier: pid_t) -> PtyProbeTerminalObservation {
    var information = siginfo_t()
    var result: Int32
    repeat {
        errno = 0
        result = waitid(
            P_PID,
            id_t(processIdentifier),
            &information,
            WEXITED | WNOWAIT
        )
    } while result != 0 && errno == EINTR
    return result == 0 ? .pinned : .failed(errno)
}

func signalPtyProbeProcess(_ processIdentifier: pid_t, _ signal: Int32) -> Int32 {
    kill(processIdentifier, signal) == 0 ? 0 : errno
}

private func readPtyReadiness(
    descriptor: PtyReaderDescriptor,
    state: PtyReadinessState,
    processState: SerializedPtyProbeState
) async throws {
    var bytes: [UInt8] = []
    var published = false
    while let chunk = try await readPtyDescriptor(descriptor) {
        guard !chunk.isEmpty, !published else {
            throw PtyClientContractError.invalidReadiness
        }
        bytes.append(contentsOf: chunk)
        guard bytes.count <= 64 * 1024 else {
            throw PtyClientContractError.invalidReadiness
        }
        guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else {
            continue
        }
        guard newline == bytes.index(before: bytes.endIndex) else {
            throw PtyClientContractError.invalidReadiness
        }
        let readiness = try JSONDecoder().decode(
            PtyClientReadiness.self,
            from: Data(bytes[..<newline])
        )
        try processState.retainDecodedReadiness(readiness)
        try await state.publish(readiness)
        published = true
    }
    guard published else {
        throw PtyClientContractError.invalidReadiness
    }
}

private func readPtyDescriptor(
    _ descriptor: PtyReaderDescriptor
) async throws -> [UInt8]? {
    while true {
        try Task.checkCancellation()
        switch try descriptor.readOnce() {
        case let .bytes(bytes):
            return bytes
        case .end:
            return nil
        case .pending:
            await Task.yield()
        }
    }
}

private func ptyContractError(_ error: any Error) -> PtyClientContractError {
    if let error = error as? PtyClientContractError { return error }
    if error is CancellationError { return .deadlineExceeded }
    return .sessionFailed
}

private func ptyTerminationFromWaitStatus(_ status: Int32) -> ProcessTermination {
    let signal = status & 0x7f
    if signal == 0 {
        return .exited((status >> 8) & 0xff)
    }
    return .unhandledSignal(signal)
}
