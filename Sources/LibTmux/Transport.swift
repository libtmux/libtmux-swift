import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// The process boundary.
///
/// Kept behind a protocol so tests can drive a server without spawning tmux,
/// and so the upstream process API stays out of the public surface.
protocol ProcessTransport: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply
}

protocol OutputLimitedProcessTransport: ProcessTransport {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply
}

extension ProcessTransport {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        guard perStreamOutputLimit >= 0 else {
            throw .invocationFailed(reason: "output limit cannot be negative")
        }
        if let limited = self as? any OutputLimitedProcessTransport {
            return try await limited.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                perStreamOutputLimit: perStreamOutputLimit
            )
        }
        let reply = try await run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard reply.standardOutput.count <= perStreamOutputLimit,
            reply.standardError.count <= perStreamOutputLimit
        else {
            throw .invocationFailed(
                reason: "tmux output exceeded \(perStreamOutputLimit) bytes per stream"
            )
        }
        return reply
    }
}

/// The shipped transport.
///
/// Cancellation kills the child's whole process group: tmux forks a daemon and
/// panes fork shells, so signalling only the direct child would leave the rest
/// running.
struct SubprocessTransport: OutputLimitedProcessTransport {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        try await run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: .max
        )
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        guard perStreamOutputLimit >= 0 else {
            throw .invocationFailed(reason: "output limit cannot be negative")
        }
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true

        var resolved: [Subprocess.Environment.Key: String] = [:]
        for (key, value) in environment {
            guard let environmentKey = Subprocess.Environment.Key(rawValue: key) else {
                throw .processLaunchFailed(reason: "invalid environment key \(key)")
            }
            resolved[environmentKey] = value
        }

        do {
            let result = try await Subprocess.run(
                Subprocess.Configuration(
                    executable: .path(FilePath(executable)),
                    arguments: Arguments(arguments),
                    environment: .custom(resolved),
                    platformOptions: platformOptions
                ),
                input: .none,
                output: .data(limit: perStreamOutputLimit),
                error: .data(limit: perStreamOutputLimit)
            )
            // A cancelled run still returns: the child is killed and reports
            // its signal. Handing that back as a reply would look like tmux
            // answering, so cancellation is reported as cancellation.
            try Task.checkCancellation()
            return TmuxReply(
                standardOutput: Array(result.standardOutput),
                standardError: Array(result.standardError),
                exitCode: exitCode(of: result.terminationStatus)
            )
        } catch let error as SubprocessError where error.code == .outputLimitExceeded {
            if Task.isCancelled { throw .cancelled }
            throw .invocationFailed(
                reason: "tmux output exceeded \(perStreamOutputLimit) bytes per stream"
            )
        } catch let error as SubprocessError
            where error.code == .spawnFailed
            || error.code == .executableNotFound
            || error.code == .failedToChangeWorkingDirectory
        {
            throw .processLaunchFailed(reason: String(describing: error))
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw .cancelled
            }
            throw .invocationFailed(reason: String(describing: error))
        }
    }
}

/// A signalled child reports its signal, not an exit code. Preserving the
/// distinction as a negative value keeps "killed by SIGTERM" from being
/// mistaken for "exited 15".
private func exitCode(of status: TerminationStatus) -> Int32 {
    switch status {
    case let .exited(code): Int32(code)
    case let .signaled(signal): -Int32(signal)
    }
}

func normalizedTmuxError(_ error: any Error) -> TmuxError {
    if let error = error as? TmuxError { return error }
    if let error = error as? SubprocessError,
        error.code == .spawnFailed
            || error.code == .executableNotFound
            || error.code == .failedToChangeWorkingDirectory
    {
        return .processLaunchFailed(reason: String(describing: error))
    }
    if error is CancellationError || Task.isCancelled { return .cancelled }
    return .invocationFailed(reason: String(describing: error))
}

func withTmuxErrorMapping<Result>(
    _ operation: () async throws -> Result
) async throws(TmuxError) -> Result {
    do {
        return try await operation()
    } catch {
        throw normalizedTmuxError(error)
    }
}
