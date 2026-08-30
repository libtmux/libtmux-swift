import Subprocess

let defaultTmuxReplyByteLimit = 1_048_576

func tmuxOutputLimitError(_ limit: Int) -> TmuxError {
    .outputLimitExceeded(perStreamBytes: limit)
}

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// The process boundary.
///
/// Kept behind a protocol so tests can drive a server without spawning tmux,
/// and so the upstream process API stays out of the public surface.
///
/// A transport is told the limit so it can stop reading at it rather than
/// buffering what it will then discard. ``ServerRuntime`` checks the reply
/// against the same limit, so a transport that ignores it still fails closed.
protocol ProcessTransport: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply
}

func requireReplyFitsLimit(
    _ reply: TmuxReply,
    _ limit: Int
) throws(TmuxError) {
    guard reply.standardOutput.count <= limit, reply.standardError.count <= limit else {
        throw tmuxOutputLimitError(limit)
    }
}

/// The shipped transport.
///
/// Cancellation kills the child's whole process group: tmux forks a daemon and
/// panes fork shells, so signalling only the direct child would leave the rest
/// running.
struct SubprocessTransport: ProcessTransport {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            .send(
                signal: .kill,
                toProcessGroup: true,
                allowedDurationToNextStep: .zero
            )
        ]

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
            throw tmuxOutputLimitError(perStreamOutputLimit)
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
