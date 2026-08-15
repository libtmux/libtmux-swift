import Dispatch
import Foundation
import SpikeSupport

#if canImport(Darwin)
    import Darwin
    import os
#elseif canImport(Glibc)
    import Glibc
    import Synchronization
#endif

struct SpawnedPOSIXProcess: Sendable {
    let processIdentifier: Int32
    let standardInput: Int32?
    let standardOutput: Int32
    let standardError: Int32
}

struct POSIXReadResult: Sendable {
    let bytes: [UInt8]
    let exceededLimit: Bool
}

struct POSIXPipeSet {
    let standardOutput: [Int32]
    let standardError: [Int32]
    let standardInput: [Int32]?
    let nullInput: Int32
}

package enum POSIXTerminalObservation: Sendable {
    case observed
    case failed(Int32)
}

package struct POSIXProcessOwnerHooks: Sendable {
    let signalProcessGroup: @Sendable (Int32, Int32) -> Int32
    let observeTerminal: @Sendable (Int32) -> POSIXTerminalObservation
    let afterReap: @Sendable () async -> Void

    package init(
        signalProcessGroup: @escaping @Sendable (Int32, Int32) -> Int32 = {
            processIdentifier, signal in
            kill(-processIdentifier, signal)
        },
        observeTerminal: (@Sendable (Int32) -> POSIXTerminalObservation)? = nil,
        afterReap: @escaping @Sendable () async -> Void = {}
    ) {
        self.signalProcessGroup = signalProcessGroup
        self.observeTerminal =
            observeTerminal ?? { processIdentifier in
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
                return result == 0 ? .observed : .failed(errno)
            }
        self.afterReap = afterReap
    }
}

private struct LockedPOSIXProcessOwnerState: Sendable {
    let processIdentifier: Int32
    var signalsOpen = true
    var reaped = false
}

private enum POSIXWaitIDRecovery: Sendable {
    case reaped
    case requiresBlockingReap
    case failed(Int32)
}

private struct POSIXProcessWaiterOutcome: Sendable {
    let result: Result<ProcessTermination, ProcessInvocationError>
    let didReap: Bool
}

private final class SerializedPOSIXProcessOwnerState: Sendable {
    #if canImport(Darwin)
        private let state: OSAllocatedUnfairLock<LockedPOSIXProcessOwnerState>
    #else
        private let state: Mutex<LockedPOSIXProcessOwnerState>
    #endif

    init(processIdentifier: Int32) {
        let initialState = LockedPOSIXProcessOwnerState(
            processIdentifier: processIdentifier
        )
        #if canImport(Darwin)
            state = OSAllocatedUnfairLock(initialState: initialState)
        #else
            state = Mutex(initialState)
        #endif
    }

    func signalProcessGroup(_ signal: Int32, hooks: POSIXProcessOwnerHooks) {
        state.withLock { state in
            guard state.signalsOpen, !state.reaped else { return }
            _ = hooks.signalProcessGroup(state.processIdentifier, signal)
        }
    }

    func closeSignalGateAfterTerminalObservation(hooks: POSIXProcessOwnerHooks) {
        state.withLock { state in
            guard state.signalsOpen, !state.reaped else { return }
            _ = hooks.signalProcessGroup(state.processIdentifier, SIGKILL)
            state.signalsOpen = false
        }
    }

    func recoverAfterTerminalObservationFailure(
        hooks: POSIXProcessOwnerHooks
    ) -> POSIXWaitIDRecovery {
        state.withLock { state in
            guard state.signalsOpen, !state.reaped else { return .failed(ECHILD) }
            var status: Int32 = 0
            var waited: Int32
            repeat {
                errno = 0
                waited = waitpid(state.processIdentifier, &status, WNOHANG)
            } while waited < 0 && errno == EINTR
            let waitError = waited < 0 ? errno : 0

            if waited == state.processIdentifier {
                state.reaped = true
                state.signalsOpen = false
                return .reaped
            }
            if waited == 0 {
                _ = hooks.signalProcessGroup(state.processIdentifier, SIGKILL)
                state.signalsOpen = false
                return .requiresBlockingReap
            }
            state.signalsOpen = false
            return .failed(waitError)
        }
    }

    func markReaped() {
        state.withLock { state in
            state.reaped = true
            state.signalsOpen = false
        }
    }
}

final class POSIXProcessOwner: Sendable {
    private let state: SerializedPOSIXProcessOwnerState
    private let waiter: Task<Result<ProcessTermination, ProcessInvocationError>, Never>

    init(
        process: SpawnedPOSIXProcess,
        hooks: POSIXProcessOwnerHooks = POSIXProcessOwnerHooks()
    ) {
        let state = SerializedPOSIXProcessOwnerState(
            processIdentifier: process.processIdentifier
        )
        self.state = state
        self.hooks = hooks
        waiter = makePOSIXProcessWaiter(
            processIdentifier: process.processIdentifier,
            state: state,
            hooks: hooks
        )
    }

    func signalProcessGroup(_ signal: Int32) {
        state.signalProcessGroup(signal, hooks: hooks)
    }

    func waitForTermination() async throws -> ProcessTermination {
        try await waiter.value.get()
    }

    private let hooks: POSIXProcessOwnerHooks
}

private func makePOSIXProcessWaiter(
    processIdentifier: Int32,
    state: SerializedPOSIXProcessOwnerState,
    hooks: POSIXProcessOwnerHooks
) -> Task<Result<ProcessTermination, ProcessInvocationError>, Never> {
    Task.detached {
        let outcome: POSIXProcessWaiterOutcome =
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    let observation = hooks.observeTerminal(processIdentifier)
                    switch observation {
                    case .observed:
                        state.closeSignalGateAfterTerminalObservation(hooks: hooks)
                        switch blockingWaitForPOSIXProcess(processIdentifier) {
                        case let .success(status):
                            state.markReaped()
                            continuation.resume(
                                returning: POSIXProcessWaiterOutcome(
                                    result: .success(terminationFromWaitStatus(status)),
                                    didReap: true
                                )
                            )
                        case let .failure(error):
                            continuation.resume(
                                returning: POSIXProcessWaiterOutcome(
                                    result: .failure(error),
                                    didReap: false
                                )
                            )
                        }
                    case let .failed(code):
                        switch state.recoverAfterTerminalObservationFailure(hooks: hooks) {
                        case .reaped:
                            continuation.resume(
                                returning: POSIXProcessWaiterOutcome(
                                    result: .failure(
                                        .ioFailure(operation: "waitid", code: code)
                                    ),
                                    didReap: true
                                )
                            )
                        case .requiresBlockingReap:
                            switch blockingWaitForPOSIXProcess(processIdentifier) {
                            case .success:
                                state.markReaped()
                                continuation.resume(
                                    returning: POSIXProcessWaiterOutcome(
                                        result: .failure(
                                            .ioFailure(operation: "waitid", code: code)
                                        ),
                                        didReap: true
                                    )
                                )
                            case let .failure(error):
                                continuation.resume(
                                    returning: POSIXProcessWaiterOutcome(
                                        result: .failure(error),
                                        didReap: false
                                    )
                                )
                            }
                        case let .failed(error):
                            continuation.resume(
                                returning: POSIXProcessWaiterOutcome(
                                    result: .failure(
                                        .ioFailure(operation: "waitpid", code: error)
                                    ),
                                    didReap: false
                                )
                            )
                        }
                    }
                }
            }
        if outcome.didReap { await hooks.afterReap() }
        return outcome.result
    }
}

private func blockingWaitForPOSIXProcess(
    _ processIdentifier: Int32
) -> Result<Int32, ProcessInvocationError> {
    var status: Int32 = 0
    var waited: Int32
    repeat {
        errno = 0
        waited = waitpid(processIdentifier, &status, 0)
    } while waited < 0 && errno == EINTR
    guard waited == processIdentifier else {
        return .failure(.ioFailure(operation: "waitpid", code: errno))
    }
    return .success(status)
}

package struct DirectSpawnTransport: ProcessTransport {
    private let processOwnerHooks: POSIXProcessOwnerHooks

    package init(processOwnerHooks: POSIXProcessOwnerHooks = POSIXProcessOwnerHooks()) {
        self.processOwnerHooks = processOwnerHooks
    }

    package func run(_ request: ProcessRequest) async throws -> ProcessReply {
        try Task.checkCancellation()
        let process = try spawnPOSIX(request: request, interactive: false)
        let owner = POSIXProcessOwner(process: process, hooks: processOwnerHooks)
        let arbiter = OutputLimitArbiter(limit: outputLimit(for: request.outputPolicy))
        return try await withTaskCancellationHandler {
            async let standardOutput = readPOSIXDescriptor(
                process.standardOutput,
                stream: .standardOutput,
                limit: outputLimit(for: request.outputPolicy),
                processGroup: process.processIdentifier,
                arbiter: arbiter,
                processOwner: owner
            )
            async let standardError = readPOSIXDescriptor(
                process.standardError,
                stream: .standardError,
                limit: outputLimit(for: request.outputPolicy),
                processGroup: process.processIdentifier,
                arbiter: arbiter,
                processOwner: owner
            )
            async let termination = owner.waitForTermination()
            let (output, error, status) = try await (
                standardOutput,
                standardError,
                termination
            )
            try Task.checkCancellation()
            if let limitError = arbiter.error { throw limitError }
            return ProcessReply(
                standardOutput: output.bytes,
                standardError: error.bytes,
                termination: status
            )
        } onCancel: {
            owner.signalProcessGroup(SIGKILL)
        }
    }
}

func resolvePOSIXExecutable(
    _ executable: ProcessExecutable,
    environment: [String: String]
) throws -> String {
    switch executable {
    case let .path(path):
        return path
    case let .name(name):
        guard !name.contains("/") else {
            throw ProcessInvocationError.executableNotFound(name)
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            guard directory.hasPrefix("/") else { continue }
            let candidate = "\(directory)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        throw ProcessInvocationError.executableNotFound(name)
    }
}

func spawnPOSIX(
    request: ProcessRequest,
    interactive: Bool
) throws -> SpawnedPOSIXProcess {
    let executable = try resolvePOSIXExecutable(
        request.executable, environment: request.environment)
    let pipes = try acquirePOSIXPipes(interactive: interactive)
    let standardOutput = pipes.standardOutput
    let standardError = pipes.standardError
    var standardInput = pipes.standardInput
    let nullInput = pipes.nullInput

    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
    #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
    #endif
    var actionsInitialized = false
    var attributesInitialized = false
    defer {
        if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
        if attributesInitialized { posix_spawnattr_destroy(&attributes) }
        if nullInput >= 0 { close(nullInput) }
    }

    func fail(_ code: Int32) throws {
        closePipe(standardOutput)
        closePipe(standardError)
        if let standardInput { closePipe(standardInput) }
        throw ProcessInvocationError.spawnFailed(code: code)
    }

    var code = posix_spawn_file_actions_init(&actions)
    guard code == 0 else {
        try fail(code)
        fatalError()
    }
    actionsInitialized = true
    code = posix_spawnattr_init(&attributes)
    guard code == 0 else {
        try fail(code)
        fatalError()
    }
    attributesInitialized = true

    let inputRead = standardInput?[0] ?? nullInput
    for (source, destination) in [
        (inputRead, STDIN_FILENO),
        (standardOutput[1], STDOUT_FILENO),
        (standardError[1], STDERR_FILENO),
    ] {
        code = posix_spawn_file_actions_adddup2(&actions, source, destination)
        guard code == 0 else {
            try fail(code)
            fatalError()
        }
    }
    let descriptors = standardOutput + standardError + (standardInput ?? [])
    for descriptor in descriptors where descriptor > STDERR_FILENO {
        code = posix_spawn_file_actions_addclose(&actions, descriptor)
        guard code == 0 else {
            try fail(code)
            fatalError()
        }
    }
    if let workingDirectory = request.workingDirectory {
        code = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        guard code == 0 else {
            closePipe(standardOutput)
            closePipe(standardError)
            if let standardInput { closePipe(standardInput) }
            throw ProcessInvocationError.invalidWorkingDirectory(workingDirectory)
        }
    }
    var emptyMask = sigset_t()
    guard sigemptyset(&emptyMask) == 0 else {
        try fail(errno)
        fatalError()
    }
    code = posix_spawnattr_setsigmask(&attributes, &emptyMask)
    guard code == 0 else {
        try fail(code)
        fatalError()
    }
    var defaultSignals = sigset_t()
    guard sigemptyset(&defaultSignals) == 0 else {
        try fail(errno)
        fatalError()
    }
    for signalNumber in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] {
        guard sigaddset(&defaultSignals, signalNumber) == 0 else {
            try fail(errno)
            fatalError()
        }
    }
    code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    guard code == 0 else {
        try fail(code)
        fatalError()
    }
    code = posix_spawnattr_setpgroup(&attributes, 0)
    guard code == 0 else {
        try fail(code)
        fatalError()
    }
    let flags =
        Int16(POSIX_SPAWN_SETSIGMASK)
        | Int16(POSIX_SPAWN_SETSIGDEF)
        | Int16(POSIX_SPAWN_SETPGROUP)
    code = posix_spawnattr_setflags(&attributes, flags)
    guard code == 0 else {
        try fail(code)
        fatalError()
    }

    var processIdentifier: pid_t = 0
    let argv = [executable] + request.arguments
    let environment = request.environment.keys.sorted().map { "\($0)=\(request.environment[$0]!)" }
    code = withCStringArray(argv) { argumentPointers in
        withCStringArray(environment) { environmentPointers in
            posix_spawn(
                &processIdentifier,
                executable,
                &actions,
                &attributes,
                argumentPointers,
                environmentPointers
            )
        }
    }
    guard code == 0 else {
        try fail(code)
        fatalError()
    }

    close(standardOutput[1])
    close(standardError[1])
    if let inputRead = standardInput?.removeFirst() { close(inputRead) }
    return SpawnedPOSIXProcess(
        processIdentifier: processIdentifier,
        standardInput: standardInput?.first,
        standardOutput: standardOutput[0],
        standardError: standardError[0]
    )
}

func acquirePOSIXPipes(
    interactive: Bool,
    makePipe: () throws -> [Int32] = makeCLOEXECPipe,
    openNullInput: () throws -> Int32 = { try openCLOEXECAboveStandardDescriptors("/dev/null") }
) throws -> POSIXPipeSet {
    let standardOutput = try makePipe()
    do {
        let standardError = try makePipe()
        do {
            let standardInput = interactive ? try makePipe() : nil
            let nullInput = try interactive ? -1 : openNullInput()
            return POSIXPipeSet(
                standardOutput: standardOutput,
                standardError: standardError,
                standardInput: standardInput,
                nullInput: nullInput
            )
        } catch {
            closePipe(standardOutput)
            closePipe(standardError)
            throw error
        }
    } catch {
        closePipe(standardOutput)
        throw error
    }
}

func openCLOEXECAboveStandardDescriptors(_ path: String) throws -> Int32 {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw ProcessInvocationError.ioFailure(operation: "open", code: errno)
    }
    guard descriptor <= STDERR_FILENO else { return descriptor }
    let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
    guard replacement >= 0 else {
        let code = errno
        close(descriptor)
        throw ProcessInvocationError.ioFailure(operation: "fcntl", code: code)
    }
    close(descriptor)
    return replacement
}

func makeCLOEXECPipe() throws -> [Int32] {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard pipe(&descriptors) == 0 else {
        throw ProcessInvocationError.ioFailure(operation: "pipe", code: errno)
    }
    for index in descriptors.indices {
        let descriptor = descriptors[index]
        if descriptor <= STDERR_FILENO {
            let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard replacement >= 0 else {
                let code = errno
                closePipe(descriptors)
                throw ProcessInvocationError.ioFailure(operation: "fcntl", code: code)
            }
            close(descriptor)
            descriptors[index] = replacement
            continue
        }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            closePipe(descriptors)
            throw ProcessInvocationError.ioFailure(operation: "fcntl", code: code)
        }
    }
    return descriptors
}

func closePipe(_ descriptors: [Int32]) {
    for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
}

func withCStringArray<Result>(
    _ strings: [String],
    body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    pointers.append(nil)
    return try body(pointers)
}

func readPOSIXDescriptor(
    _ descriptor: Int32,
    stream: ProcessOutputStream,
    limit: Int?,
    processGroup: Int32,
    arbiter: OutputLimitArbiter,
    grouped: Bool = true,
    closeWhenDone: Bool = true,
    processOwner: POSIXProcessOwner? = nil
) async throws -> POSIXReadResult {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            var collected: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            var exceededLimit = false
            defer { if closeWhenDone { close(descriptor) } }
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    if !exceededLimit {
                        collected.append(contentsOf: buffer[..<count])
                        if let limit, collected.count > limit {
                            exceededLimit = true
                            collected.removeAll(keepingCapacity: false)
                            if arbiter.exceeded(on: stream) {
                                if let processOwner {
                                    processOwner.signalProcessGroup(SIGKILL)
                                } else {
                                    terminatePOSIXProcess(
                                        processGroup,
                                        grouped: grouped,
                                        signal: SIGKILL
                                    )
                                }
                            }
                        }
                    } else if arbiter.error != nil {
                        collected.removeAll(keepingCapacity: false)
                    }
                } else if count == 0 {
                    continuation.resume(
                        returning: POSIXReadResult(
                            bytes: collected,
                            exceededLimit: exceededLimit
                        )
                    )
                    return
                } else if errno != EINTR {
                    continuation.resume(
                        throwing: ProcessInvocationError.ioFailure(
                            operation: "read",
                            code: errno
                        )
                    )
                    return
                }
            }
        }
    }
}

func waitForPOSIXProcess(_ processIdentifier: Int32) async throws -> ProcessTermination {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            var status: Int32 = 0
            var result: Int32
            repeat {
                result = waitpid(processIdentifier, &status, 0)
            } while result < 0 && errno == EINTR
            guard result == processIdentifier else {
                continuation.resume(
                    throwing: ProcessInvocationError.ioFailure(
                        operation: "waitpid",
                        code: errno
                    )
                )
                return
            }
            continuation.resume(returning: terminationFromWaitStatus(status))
        }
    }
}

func terminationFromWaitStatus(_ status: Int32) -> ProcessTermination {
    let signal = status & 0x7f
    if signal == 0 {
        return .exited((status >> 8) & 0xff)
    }
    return .unhandledSignal(signal)
}

func terminatePOSIXProcessGroup(_ processIdentifier: Int32, signal: Int32) {
    terminatePOSIXProcess(processIdentifier, grouped: true, signal: signal)
}

func terminatePOSIXProcess(_ processIdentifier: Int32, grouped: Bool, signal: Int32) {
    guard processIdentifier > 0 else { return }
    _ = kill(grouped ? -processIdentifier : processIdentifier, signal)
}
