/// Bounds one tmux command by wall-clock time.
///
/// Cancellation is the only bound a `Task` gives for free, and it is the wrong
/// one here: it fires when the *caller* is done waiting, not when a daemon has
/// stopped answering. A tmux that is wedged — swapping, stopped, or waiting on
/// a lock nothing will release — otherwise holds the calling task for as long
/// as it stays that way.
///
/// Both dispatch paths are already correct under cancellation, which is what
/// makes this a race and not a rewrite. A direct command's transport kills the
/// child's whole process group, and an abandoned control-mode submission keeps
/// its place in `ControlSession`'s queue with no continuation, so tmux's late
/// reply is consumed and discarded rather than handed to the next waiter.
/// `operation` takes an untyped `throws` because Swift 6.2 never infers a
/// closure literal's thrown type from its body — the same limitation
/// ``withTmuxError(_:)`` exists for. Every error out of it is normalized, so
/// the bound is still `throws(TmuxError)` to a caller.
func withCommandDeadline<Value: Sendable>(
    _ timeout: Duration?,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws(TmuxError) -> Value {
    guard let timeout else { return try await withTmuxErrorMapping(operation) }
    guard timeout > .zero else { throw .timedOut(after: timeout) }
    if Task.isCancelled { throw .cancelled }

    let outcome = await withTaskGroup(
        of: CommandDeadlineRace<Value>.self,
        returning: CommandDeadlineRace<Value>.self
    ) { group in
        group.addTask {
            do {
                return .completed(try await operation())
            } catch {
                return .failed(normalizedTmuxError(error))
            }
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                // The sleep is cancelled when the operation wins the race, and
                // by the caller's own cancellation. Neither is a timeout.
                return .cancelled
            }
            return .timedOut
        }
        let first = await group.next() ?? .cancelled
        group.cancelAll()
        return first
    }

    switch outcome {
    case let .completed(value): return value
    case let .failed(error): throw error
    case .timedOut: throw .timedOut(after: timeout)
    case .cancelled: throw .cancelled
    }
}

private enum CommandDeadlineRace<Value: Sendable>: Sendable {
    case completed(Value)
    case failed(TmuxError)
    case timedOut
    case cancelled
}
