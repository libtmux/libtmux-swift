import Foundation
import SpikeSupport

package struct FoundationInteractive: InteractiveProcessLauncher {
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
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: try resolvePOSIXExecutable(
                request.executable,
                environment: request.environment
            )
        )
        process.arguments = request.arguments
        process.environment = request.environment
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let coordinator = FoundationProcessCoordinator(process: process)
        let processIdentifier: Int32
        do {
            processIdentifier = try await coordinator.launch()
        } catch {
            throw ProcessInvocationError.upstream(String(describing: error))
        }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        let state = InteractiveSessionState()
        Task {
            await ownFoundationSession(
                processIdentifier: processIdentifier,
                input: inputPipe.fileHandleForWriting,
                output: outputPipe.fileHandleForReading,
                error: errorPipe.fileHandleForReading,
                coordinator: coordinator,
                state: state
            )
        }
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

private func ownFoundationSession(
    processIdentifier: Int32,
    input: FileHandle,
    output: FileHandle,
    error: FileHandle,
    coordinator: FoundationProcessCoordinator,
    state: InteractiveSessionState
) async {
    do {
        let status = try await withThrowingTaskGroup(
            of: InteractiveOwnerEvent.self,
            returning: ProcessTermination.self
        ) { group in
            do {
                group.addTask {
                    for try await bytes in posixByteStream(
                        output.fileDescriptor,
                        closeWhenDone: false
                    ) {
                        await state.yieldStandardOutput(bytes)
                    }
                    try output.close()
                    return .standardOutputEnded
                }
                group.addTask {
                    for try await bytes in posixByteStream(
                        error.fileDescriptor,
                        closeWhenDone: false
                    ) {
                        await state.yieldStandardError(bytes)
                    }
                    try error.close()
                    return .standardErrorEnded
                }
                group.addTask {
                    var open = true
                    defer { if open { try? input.close() } }
                    for await message in state.inputMessages {
                        switch message {
                        case let .write(identifier, bytes):
                            do {
                                try await writePOSIXDescriptor(input.fileDescriptor, bytes: bytes)
                                await state.controlCompleted(identifier)
                            } catch {
                                await state.controlCompleted(identifier, result: .failure(error))
                                await state.abortInput(error)
                                return .inputEnded
                            }
                        case let .finish(identifier):
                            try input.close()
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
                            await coordinator.cancel()
                            await state.controlCompleted(identifier)
                            return .terminationRequested
                        }
                    }
                    return .terminationRequested
                }
                group.addTask {
                    .processTerminated(await coordinator.waitForTermination())
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
                await coordinator.cancel()
                await state.abortInput(error)
                throw error
            }
        }
        await state.complete(.success(status))
    } catch {
        await coordinator.cancel()
        await state.abortInput(error)
        await state.complete(.failure(error))
    }
}
