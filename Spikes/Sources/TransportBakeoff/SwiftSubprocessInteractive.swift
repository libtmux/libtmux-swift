import SpikeSupport
import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

#if canImport(Darwin)
    import Darwin
    import os
#elseif canImport(Glibc)
    import Glibc
    import Synchronization
#endif

package struct SwiftSubprocessInteractive: InteractiveProcessLauncher {
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
        let state = InteractiveSessionState()
        Task { await ownSwiftSubprocessSession(request: request, state: state) }
        try await state.waitUntilLaunched()
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

private func ownSwiftSubprocessSession(
    request: InteractiveProcessRequest,
    state: InteractiveSessionState
) async {
    do {
        let configuration = try subprocessConfiguration(for: request)
        let inputPipe = try SwiftSubprocessInputPipe()
        let shutdownIntent = SwiftSubprocessShutdownIntent()
        do {
            let result = try await Subprocess.run(
                configuration,
                input: .fileDescriptor(
                    FileDescriptor(rawValue: inputPipe.childReadDescriptor),
                    closeAfterSpawningProcess: false
                ),
                output: .sequence,
                error: .sequence
            ) { execution in
                await inputPipe.closeChildReadDescriptorAfterSpawn()
                await state.launched()
                try await withTaskCancellationHandler {
                    try await withThrowingTaskGroup(of: InteractiveOwnerEvent.self) { group in
                        group.addTask {
                            var iterator = execution.standardOutput.makeAsyncIterator()
                            while let buffer = try await iterator.next() {
                                let bytes = buffer.withUnsafeBytes(Array.init)
                                await state.yieldStandardOutput(bytes)
                            }
                            return .standardOutputEnded
                        }
                        group.addTask {
                            var iterator = execution.standardError.makeAsyncIterator()
                            while let buffer = try await iterator.next() {
                                let bytes = buffer.withUnsafeBytes(Array.init)
                                await state.yieldStandardError(bytes)
                            }
                            return .standardErrorEnded
                        }
                        group.addTask {
                            for await message in state.inputMessages {
                                switch message {
                                case let .write(identifier, bytes):
                                    do {
                                        try await inputPipe.write(bytes)
                                        await state.controlCompleted(identifier)
                                    } catch {
                                        await state.controlCompleted(
                                            identifier,
                                            result: .failure(error)
                                        )
                                        if shutdownIntent.isRequested,
                                            error as? InteractiveProcessError
                                                == .writeFailed(code: EPIPE)
                                        {
                                            return .inputEnded
                                        }
                                        throw error
                                    }
                                case let .finish(identifier):
                                    await inputPipe.finish()
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
                                    shutdownIntent.request()
                                    try? execution.send(signal: .kill, toProcessGroup: true)
                                    await state.controlCompleted(identifier)
                                    await execution.teardown(using: subprocessTeardownSequence)
                                    return .terminationRequested
                                }
                            }
                            return .terminationRequested
                        }

                        var outputEnded = false
                        var errorEnded = false
                        do {
                            while let event = try await group.next() {
                                switch event {
                                case .standardOutputEnded:
                                    outputEnded = true
                                case .standardErrorEnded:
                                    errorEnded = true
                                case .terminationRequested:
                                    await state.abortInput()
                                case .inputEnded, .processTerminated:
                                    break
                                }
                                if outputEnded && errorEnded {
                                    shutdownIntent.request()
                                    await state.abortInput()
                                    try? execution.send(signal: .kill, toProcessGroup: true)
                                    await execution.teardown(using: subprocessTeardownSequence)
                                    group.cancelAll()
                                    break
                                }
                            }
                            try await group.waitForAll()
                        } catch {
                            shutdownIntent.request()
                            await state.abortInput(error)
                            try? execution.send(signal: .kill, toProcessGroup: true)
                            await execution.teardown(using: subprocessTeardownSequence)
                            group.cancelAll()
                            throw error
                        }
                    }
                } onCancel: {
                    shutdownIntent.request()
                    try? execution.send(signal: .kill, toProcessGroup: true)
                }
            }
            await inputPipe.cleanup()
            await state.complete(.success(mapTermination(result.terminationStatus)))
        } catch {
            await inputPipe.cleanup()
            throw error
        }
    } catch {
        await state.launchFailed(error)
    }
}

private final class SwiftSubprocessShutdownIntent: Sendable {
    #if canImport(Darwin)
        private let requested = OSAllocatedUnfairLock<Bool>(initialState: false)
    #else
        private let requested = Mutex<Bool>(false)
    #endif

    var isRequested: Bool {
        requested.withLock { $0 }
    }

    func request() {
        requested.withLock { $0 = true }
    }
}

private actor SwiftSubprocessInputPipe {
    nonisolated let childReadDescriptor: Int32
    private var childReadDescriptorIsOpen = true
    private var parentWriteDescriptor: Int32?

    init() throws {
        let descriptors = try makeCLOEXECPipe()
        childReadDescriptor = descriptors[0]
        parentWriteDescriptor = descriptors[1]
    }

    func write(_ bytes: [UInt8]) async throws {
        guard let parentWriteDescriptor else {
            throw InteractiveProcessError.inputFinished
        }
        try await writePOSIXDescriptor(parentWriteDescriptor, bytes: bytes)
    }

    func closeChildReadDescriptorAfterSpawn() {
        guard childReadDescriptorIsOpen else { return }
        close(childReadDescriptor)
        childReadDescriptorIsOpen = false
    }

    func finish() {
        guard let parentWriteDescriptor else { return }
        close(parentWriteDescriptor)
        self.parentWriteDescriptor = nil
    }

    func cleanup() {
        closeChildReadDescriptorAfterSpawn()
        finish()
    }
}

private func subprocessConfiguration(
    for request: InteractiveProcessRequest
) throws -> Subprocess.Configuration {
    let executable: Subprocess.Executable
    switch request.executable {
    case let .name(name):
        executable = .name(name)
    case let .path(path):
        executable = .path(FilePath(path))
    }
    var environment: [Subprocess.Environment.Key: String] = [:]
    for (key, value) in request.environment {
        guard let environmentKey = Subprocess.Environment.Key(rawValue: key) else {
            throw ProcessInvocationError.upstream("invalid environment key")
        }
        environment[environmentKey] = value
    }
    var platformOptions = PlatformOptions()
    platformOptions.createSession = true
    platformOptions.teardownSequence = subprocessTeardownSequence
    return Subprocess.Configuration(
        executable: executable,
        arguments: Arguments(request.arguments),
        environment: .custom(environment),
        workingDirectory: request.workingDirectory.map { FilePath($0) },
        platformOptions: platformOptions
    )
}
