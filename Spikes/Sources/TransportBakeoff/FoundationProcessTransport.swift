import Dispatch
import Foundation
import SpikeSupport

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

actor FoundationProcessCoordinator {
    private let process: Process
    private var termination: ProcessTermination?
    private var waiters: [CheckedContinuation<ProcessTermination, Never>] = []

    init(process: Process) {
        self.process = process
    }

    func launch() throws -> Int32 {
        try process.run()
        let processIdentifier = process.processIdentifier
        DispatchQueue.global().async { [process, weak self] in
            process.waitUntilExit()
            let termination: ProcessTermination =
                process.terminationReason == .exit
                ? .exited(process.terminationStatus)
                : .unhandledSignal(process.terminationStatus)
            Task { await self?.didTerminate(termination) }
        }
        return processIdentifier
    }

    func cancel() {
        guard termination == nil, process.isRunning else { return }
        terminatePOSIXProcess(process.processIdentifier, grouped: false, signal: SIGKILL)
    }

    func waitForTermination() async -> ProcessTermination {
        if let termination { return termination }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func didTerminate(_ value: ProcessTermination) {
        guard termination == nil else { return }
        termination = value
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume(returning: value)
        }
    }
}

package struct FoundationProcessTransport: ProcessTransport {
    package static let providesProcessGroupIsolation = false

    package init() {}

    package func run(_ request: ProcessRequest) async throws -> ProcessReply {
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
            guard FileManager.default.fileExists(atPath: workingDirectory) else {
                throw ProcessInvocationError.invalidWorkingDirectory(workingDirectory)
            }
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let coordinator = FoundationProcessCoordinator(process: process)
        let processIdentifier: Int32
        do {
            processIdentifier = try await coordinator.launch()
        } catch {
            throw ProcessInvocationError.upstream(String(describing: error))
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        let arbiter = OutputLimitArbiter(limit: outputLimit(for: request.outputPolicy))

        return try await withTaskCancellationHandler {
            async let standardOutput = readPOSIXDescriptor(
                outputPipe.fileHandleForReading.fileDescriptor,
                stream: .standardOutput,
                limit: outputLimit(for: request.outputPolicy),
                processGroup: processIdentifier,
                arbiter: arbiter,
                grouped: false,
                closeWhenDone: false
            )
            async let standardError = readPOSIXDescriptor(
                errorPipe.fileHandleForReading.fileDescriptor,
                stream: .standardError,
                limit: outputLimit(for: request.outputPolicy),
                processGroup: processIdentifier,
                arbiter: arbiter,
                grouped: false,
                closeWhenDone: false
            )
            async let termination = coordinator.waitForTermination()
            let (output, error, status) = try await (
                standardOutput,
                standardError,
                termination
            )
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            try Task.checkCancellation()
            if let limitError = arbiter.error { throw limitError }
            return ProcessReply(
                standardOutput: output.bytes,
                standardError: error.bytes,
                termination: status
            )
        } onCancel: {
            Task { await coordinator.cancel() }
        }
    }
}
