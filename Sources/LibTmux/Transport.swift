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

/// The process boundary: what turns an argument vector into tmux's answer.
///
/// Every command that takes a process goes through one of these, which makes
/// it the seam for the two things a consumer cannot otherwise do. A server in
/// ``TmuxMode/connected(to:)`` carries most of its commands over the
/// connection instead, and reaches here only for the ones that take their own
/// process -- see the note at the end.
///
/// A **test double** stands in for tmux, so a suite can exercise decoding,
/// provenance guards and error paths without a tmux on the machine. This
/// package's own suite is built on that, and it is why the protocol has one
/// requirement: implementing it should not be a project.
///
/// A **decorator** wraps the shipped ``SubprocessTransport`` to see every
/// command — to log it, time it, trace it, or count it. The library takes no
/// logging dependency and installs no global hook, because a library that
/// picks the logger picks it for its host; wrapping the seam leaves that
/// choice where it belongs.
///
/// ```swift
/// struct LoggingTransport: ProcessTransport {
///     let wrapped = SubprocessTransport()
///
///     func run(
///         executable: String,
///         arguments: [String],
///         environment: [String: String],
///         perStreamOutputLimit: Int
///     ) async throws(TmuxError) -> TmuxReply {
///         let started = ContinuousClock.now
///         defer { print(arguments.joined(separator: " "), started.duration(to: .now)) }
///         return try await wrapped.run(
///             executable: executable,
///             arguments: arguments,
///             environment: environment,
///             perStreamOutputLimit: perStreamOutputLimit
///         )
///     }
/// }
/// ```
///
/// A transport is told the limit so it can stop reading at it rather than
/// buffering what it will then discard. The library checks the reply against
/// the same limit afterwards, so a transport that ignores it still fails
/// closed rather than returning more than was asked for.
///
/// **A transport must return promptly when its task is cancelled.** It is the
/// one requirement beyond answering the call. ``Server/withTimeout(_:)`` does
/// not depend on it -- a bound abandons work that overstays rather than
/// waiting on it -- but a transport that never observes cancellation leaves
/// that work running after the call returns, for as long as its own work
/// takes. Wrapping ``SubprocessTransport`` satisfies this, as does anything
/// built from another cancellable `async` call; a loop that never checks
/// `Task.isCancelled` does not.
///
/// A control-mode connection does not come through here: it is a long-lived
/// process this library owns, not one command's round trip. A server in
/// ``TmuxMode/connected(to:)`` therefore reaches its transport only for the
/// calls that take their own process.
public protocol ProcessTransport: Sendable {
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

/// The shipped transport, and what a ``Server`` uses unless told otherwise.
///
/// Cancellation kills the child's whole process group: tmux forks a daemon and
/// panes fork shells, so signalling only the direct child would leave the rest
/// running. It is also why a bound that abandons this transport leaves nothing
/// behind — the work it walks away from has already been told to die.
public struct SubprocessTransport: ProcessTransport {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        var platformOptions = PlatformOptions()
        platformOptions.processGroupID = 0
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
