import Dispatch
import SpikeSupport

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

package struct DirectSpawnInteractive: InteractiveProcessLauncher {
    private let postSpawnCheckpoint: @Sendable () async throws -> Void

    package init(
        postSpawnCheckpoint: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.postSpawnCheckpoint = postSpawnCheckpoint
    }

    package func launch(
        _ request: InteractiveProcessRequest
    ) async throws -> any InteractiveProcessSession {
        try Task.checkCancellation()
        let process = try spawnPOSIX(
            request: ProcessRequest(
                executable: request.executable,
                arguments: request.arguments,
                environment: request.environment,
                workingDirectory: request.workingDirectory,
                outputPolicy: .complete
            ),
            interactive: true
        )
        let state = InteractiveSessionState()
        Task { await ownDirectSession(process: process, state: state) }
        await state.launched()
        do {
            try await postSpawnCheckpoint()
            try Task.checkCancellation()
            return InteractiveSessionHandle(state: state)
        } catch {
            await cleanUpUnpublishedInteractiveSession(state)
            throw error
        }
    }
}

private func ownDirectSession(
    process: SpawnedPOSIXProcess,
    state: InteractiveSessionState
) async {
    guard let standardInput = process.standardInput else {
        await state.launchFailed(ProcessInvocationError.ioFailure(operation: "stdin", code: EBADF))
        return
    }
    do {
        let status = try await withThrowingTaskGroup(
            of: InteractiveOwnerEvent.self,
            returning: ProcessTermination.self
        ) { group in
            do {
                group.addTask {
                    for try await bytes in posixByteStream(process.standardOutput) {
                        await state.yieldStandardOutput(bytes)
                    }
                    return .standardOutputEnded
                }
                group.addTask {
                    for try await bytes in posixByteStream(process.standardError) {
                        await state.yieldStandardError(bytes)
                    }
                    return .standardErrorEnded
                }
                group.addTask {
                    var open = true
                    defer { if open { close(standardInput) } }
                    for await message in state.inputMessages {
                        switch message {
                        case let .write(identifier, bytes):
                            do {
                                try await writePOSIXDescriptor(standardInput, bytes: bytes)
                                await state.controlCompleted(identifier)
                            } catch {
                                await state.controlCompleted(identifier, result: .failure(error))
                                await state.abortInput(error)
                                return .inputEnded
                            }
                        case let .finish(identifier):
                            _ = close(standardInput)
                            open = false
                            await state.controlCompleted(identifier)
                            return .inputEnded
                        }
                    }
                    return .inputEnded
                }
                group.addTask {
                    for await message in state.lifecycleMessages {
                        switch message {
                        case let .terminate(identifier):
                            terminatePOSIXProcessGroup(process.processIdentifier, signal: SIGKILL)
                            await state.controlCompleted(identifier)
                            return .terminationRequested
                        }
                    }
                    return .terminationRequested
                }
                group.addTask {
                    .processTerminated(try await waitForPOSIXProcess(process.processIdentifier))
                }

                var termination: ProcessTermination?
                var outputEnded = false
                var errorEnded = false
                while let event = try await group.next() {
                    switch event {
                    case .standardOutputEnded:
                        outputEnded = true
                    case .standardErrorEnded:
                        errorEnded = true
                    case let .processTerminated(value):
                        termination = value
                        await state.abortInput()
                    case .terminationRequested:
                        await state.abortInput()
                    case .inputEnded:
                        break
                    }
                    if let termination, outputEnded, errorEnded {
                        group.cancelAll()
                        return termination
                    }
                }
                throw InteractiveProcessError.sessionTerminated
            } catch {
                terminatePOSIXProcessGroup(process.processIdentifier, signal: SIGKILL)
                await state.abortInput(error)
                throw error
            }
        }
        await state.complete(.success(status))
    } catch {
        terminatePOSIXProcessGroup(process.processIdentifier, signal: SIGKILL)
        await state.abortInput(error)
        await state.complete(.failure(error))
    }
}

func posixByteStream(
    _ descriptor: Int32,
    closeWhenDone: Bool = true
) -> AsyncThrowingStream<[UInt8], any Error> {
    AsyncThrowingStream { continuation in
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            defer { if closeWhenDone { close(descriptor) } }
            while true {
                let count = buffer.withUnsafeMutableBytes {
                    read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    continuation.yield(Array(buffer[..<count]))
                } else if count == 0 {
                    continuation.finish()
                    return
                } else if errno != EINTR {
                    continuation.finish(
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

func writePOSIXDescriptor(_ descriptor: Int32, bytes: [UInt8]) async throws {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: writePOSIXDescriptorSynchronously(descriptor, bytes: bytes))
        }
    }
}

package func writePOSIXDescriptorSynchronously(
    _ descriptor: Int32,
    bytes: [UInt8]
) -> Result<Void, any Error> {
    var signalSet = sigset_t()
    var oldSignalSet = sigset_t()
    sigemptyset(&signalSet)
    sigaddset(&signalSet, SIGPIPE)
    let maskResult = pthread_sigmask(SIG_BLOCK, &signalSet, &oldSignalSet)
    guard maskResult == 0 else {
        return .failure(InteractiveProcessError.writeFailed(code: maskResult))
    }
    defer { pthread_sigmask(SIG_SETMASK, &oldSignalSet, nil) }

    var pendingBefore = sigset_t()
    sigemptyset(&pendingBefore)
    guard sigpending(&pendingBefore) == 0 else {
        return .failure(InteractiveProcessError.writeFailed(code: errno))
    }
    let hadPendingSIGPIPE = sigismember(&pendingBefore, SIGPIPE) == 1

    return bytes.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = write(
                descriptor,
                buffer.baseAddress!.advanced(by: offset),
                buffer.count - offset
            )
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                let code = errno
                if code == EPIPE, !hadPendingSIGPIPE {
                    var pendingAfter = sigset_t()
                    sigemptyset(&pendingAfter)
                    guard sigpending(&pendingAfter) == 0 else {
                        return .failure(InteractiveProcessError.writeFailed(code: errno))
                    }
                    if sigismember(&pendingAfter, SIGPIPE) == 1 {
                        var receivedSignal: Int32 = 0
                        let waitResult = sigwait(&signalSet, &receivedSignal)
                        guard waitResult == 0, receivedSignal == SIGPIPE else {
                            return .failure(
                                InteractiveProcessError.writeFailed(
                                    code: waitResult == 0 ? EINVAL : waitResult
                                )
                            )
                        }
                    }
                }
                return .failure(InteractiveProcessError.writeFailed(code: code))
            }
        }
        return .success(())
    }
}
