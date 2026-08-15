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

/// The shipped transport.
///
/// Cancellation kills the child's whole process group: tmux forks a daemon and
/// panes fork shells, so signalling only the direct child would leave the rest
/// running.
struct SubprocessTransport: ProcessTransport {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true

        var resolved: [Subprocess.Environment.Key: String] = [:]
        for (key, value) in environment {
            guard let environmentKey = Subprocess.Environment.Key(rawValue: key) else {
                throw .invocationFailed(reason: "invalid environment key \(key)")
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
                output: .data(limit: .max),
                error: .data(limit: .max)
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
