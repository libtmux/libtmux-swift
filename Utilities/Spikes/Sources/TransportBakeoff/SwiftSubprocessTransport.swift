import SpikeSupport
import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

package struct SwiftSubprocessTransport: ProcessTransport {
    package init() {}

    package func run(_ request: ProcessRequest) async throws -> ProcessReply {
        try Task.checkCancellation()
        let configuration = try subprocessConfiguration(for: request)
        do {
            let result = try await Subprocess.run(
                configuration,
                input: .none,
                output: .sequence,
                error: .sequence
            ) { execution in
                try await withTaskCancellationHandler {
                    do {
                        return try await withThrowingTaskGroup(of: CapturedStream.self) { group in
                            let limit = outputLimit(for: request.outputPolicy)
                            let arbiter = OutputLimitArbiter(limit: limit)
                            let teardown: @Sendable () async -> Void = {
                                try? execution.send(signal: .kill, toProcessGroup: true)
                                await execution.teardown(using: subprocessTeardownSequence)
                            }
                            group.addTask {
                                .standardOutput(
                                    try await collectSubprocessBytes(
                                        execution.standardOutput,
                                        stream: .standardOutput,
                                        limit: limit,
                                        arbiter: arbiter,
                                        onLimit: teardown
                                    ),
                                )
                            }
                            group.addTask {
                                .standardError(
                                    try await collectSubprocessBytes(
                                        execution.standardError,
                                        stream: .standardError,
                                        limit: limit,
                                        arbiter: arbiter,
                                        onLimit: teardown
                                    ),
                                )
                            }

                            var standardOutput: [UInt8] = []
                            var standardError: [UInt8] = []
                            for try await stream in group {
                                switch stream {
                                case let .standardOutput(bytes):
                                    standardOutput = bytes
                                case let .standardError(bytes):
                                    standardError = bytes
                                }
                            }
                            if let limitError = arbiter.error { throw limitError }
                            try Task.checkCancellation()
                            return (standardOutput, standardError)
                        }
                    } catch {
                        try? execution.send(signal: .kill, toProcessGroup: true)
                        if Task.isCancelled { throw CancellationError() }
                        throw error
                    }
                } onCancel: {
                    try? execution.send(signal: .kill, toProcessGroup: true)
                }
            }
            let bytes = result.closureResult
            return ProcessReply(
                standardOutput: bytes.0,
                standardError: bytes.1,
                termination: mapTermination(result.terminationStatus)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProcessOutputLimitError {
            throw error
        } catch let error as SubprocessError {
            throw ProcessInvocationError.upstream(error.description)
        }
    }
}

let subprocessTeardownSequence: [TeardownStep] = [
    .send(
        signal: .kill,
        toProcessGroup: true,
        allowedDurationToNextStep: .zero
    )
]

func subprocessConfiguration(for request: ProcessRequest) throws -> Subprocess.Configuration {
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

private func collectSubprocessBytes(
    _ sequence: SubprocessOutputSequence,
    stream: ProcessOutputStream,
    limit: Int?,
    arbiter: OutputLimitArbiter,
    onLimit: @escaping @Sendable () async -> Void
) async throws -> [UInt8] {
    var result: [UInt8] = []
    var exceeded = false
    for try await buffer in sequence {
        let chunk = buffer.withUnsafeBytes(Array.init)
        if !exceeded {
            result.append(contentsOf: chunk)
            if let limit, result.count > limit {
                exceeded = true
                result.removeAll(keepingCapacity: false)
                if arbiter.exceeded(on: stream) { await onLimit() }
            } else if arbiter.error != nil {
                exceeded = true
                result.removeAll(keepingCapacity: false)
            }
        }
    }
    return result
}

func mapTermination(_ status: TerminationStatus) -> ProcessTermination {
    switch status {
    case let .exited(code):
        .exited(code)
    case let .signaled(signal):
        .unhandledSignal(signal)
    }
}
