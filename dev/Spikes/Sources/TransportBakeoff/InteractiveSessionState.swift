import Foundation
import SpikeSupport

package actor InteractiveSessionState {
    package nonisolated let standardOutput: AsyncThrowingStream<[UInt8], any Error>
    package nonisolated let standardError: AsyncThrowingStream<[UInt8], any Error>
    nonisolated let inputMessages: AsyncStream<InteractiveInputMessage>
    nonisolated let lifecycleMessages: AsyncStream<InteractiveLifecycleMessage>

    private let standardOutputContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let standardErrorContinuation: AsyncThrowingStream<[UInt8], any Error>.Continuation
    private let inputContinuation: AsyncStream<InteractiveInputMessage>.Continuation
    private let lifecycleContinuation: AsyncStream<InteractiveLifecycleMessage>.Continuation
    private var launchResult: Result<Void, any Error>?
    private var launchWaiters: [CheckedContinuation<Void, any Error>] = []
    private var terminationResult: Result<ProcessTermination, any Error>?
    private var terminationWaiters: [UUID: CheckedContinuation<ProcessTermination, any Error>] = [:]
    private var cancelledTerminationWaiters: Set<UUID> = []
    private var inputFinished = false
    private var terminationRequested = false
    private var pendingInputControls: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingLifecycleControls: [UUID: CheckedContinuation<Void, any Error>] = [:]

    package init() {
        (standardOutput, standardOutputContinuation) = AsyncThrowingStream.makeStream()
        (standardError, standardErrorContinuation) = AsyncThrowingStream.makeStream()
        (inputMessages, inputContinuation) = AsyncStream.makeStream()
        (lifecycleMessages, lifecycleContinuation) = AsyncStream.makeStream()
    }

    package func waitUntilLaunched() async throws {
        if let launchResult { return try launchResult.get() }
        try await withCheckedThrowingContinuation { continuation in
            launchWaiters.append(continuation)
        }
    }

    package func launched() {
        completeLaunch(.success(()))
    }

    package func launchFailed(_ error: any Error) {
        completeLaunch(.failure(error))
        complete(.failure(error))
    }

    package func yieldStandardOutput(_ bytes: [UInt8]) {
        standardOutputContinuation.yield(bytes)
    }

    package func yieldStandardError(_ bytes: [UInt8]) {
        standardErrorContinuation.yield(bytes)
    }

    package func write(_ bytes: [UInt8]) async throws {
        guard !inputFinished else { throw InteractiveProcessError.inputFinished }
        guard terminationResult == nil, !terminationRequested else {
            throw InteractiveProcessError.sessionTerminated
        }
        try await withCheckedThrowingContinuation { continuation in
            let identifier = UUID()
            pendingInputControls[identifier] = continuation
            inputContinuation.yield(.write(identifier, bytes))
        }
    }

    package func finishInput() async throws {
        guard !inputFinished else { return }
        inputFinished = true
        try await withCheckedThrowingContinuation { continuation in
            let identifier = UUID()
            pendingInputControls[identifier] = continuation
            inputContinuation.yield(.finish(identifier))
        }
    }

    package func terminate() async throws {
        guard terminationResult == nil, !terminationRequested else { return }
        terminationRequested = true
        try await withCheckedThrowingContinuation { continuation in
            let identifier = UUID()
            pendingLifecycleControls[identifier] = continuation
            lifecycleContinuation.yield(.terminate(identifier))
        }
    }

    package func controlCompleted(
        _ identifier: UUID,
        result: Result<Void, any Error> = .success(())
    ) {
        if let continuation = pendingInputControls.removeValue(forKey: identifier)
            ?? pendingLifecycleControls.removeValue(forKey: identifier)
        {
            continuation.resume(with: result)
        }
    }

    package func abortInput(_ error: any Error = InteractiveProcessError.sessionTerminated) {
        inputFinished = true
        inputContinuation.finish()
        for (identifier, continuation) in pendingInputControls {
            pendingInputControls.removeValue(forKey: identifier)
            continuation.resume(throwing: error)
        }
    }

    package func waitForTermination() async throws -> ProcessTermination {
        if let terminationResult { return try terminationResult.get() }
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancelledTerminationWaiters.remove(identifier) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    terminationWaiters[identifier] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelTerminationWaiter(identifier) }
        }
    }

    private func cancelTerminationWaiter(_ identifier: UUID) {
        if let waiter = terminationWaiters.removeValue(forKey: identifier) {
            waiter.resume(throwing: CancellationError())
        } else {
            cancelledTerminationWaiters.insert(identifier)
        }
    }

    package func complete(_ result: Result<ProcessTermination, any Error>) {
        guard terminationResult == nil else { return }
        terminationResult = result
        standardOutputContinuation.finish()
        standardErrorContinuation.finish()
        inputContinuation.finish()
        lifecycleContinuation.finish()
        abortInput(InteractiveProcessError.sessionTerminated)
        for (identifier, continuation) in pendingLifecycleControls {
            pendingLifecycleControls.removeValue(forKey: identifier)
            // A terminate request that races process completion has already
            // achieved its requested state, just like terminate() called
            // after completion.
            continuation.resume()
        }
        let waiters = terminationWaiters.values
        terminationWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func completeLaunch(_ result: Result<Void, any Error>) {
        guard launchResult == nil else { return }
        launchResult = result
        let waiters = launchWaiters
        launchWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }
}

package struct InteractiveSessionHandle: InteractiveProcessSession {
    package let standardOutput: AsyncThrowingStream<[UInt8], any Error>
    package let standardError: AsyncThrowingStream<[UInt8], any Error>
    private let state: InteractiveSessionState

    package init(state: InteractiveSessionState) {
        self.state = state
        standardOutput = state.standardOutput
        standardError = state.standardError
    }

    package func writeStandardInput(_ bytes: [UInt8]) async throws {
        try await state.write(bytes)
    }

    package func finishStandardInput() async throws {
        try await state.finishInput()
    }

    package func terminate() async throws {
        try await state.terminate()
    }

    package func waitForTermination() async throws -> ProcessTermination {
        try await state.waitForTermination()
    }
}

package func cleanUpUnpublishedInteractiveSession(
    _ state: InteractiveSessionState
) async {
    let cleanup = Task.detached {
        try? await state.terminate()
        _ = try? await state.waitForTermination()
    }
    await cleanup.value
}
