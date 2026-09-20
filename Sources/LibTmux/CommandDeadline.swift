import Foundation

/// Bounds one tmux command by wall-clock time.
///
/// The race is deliberately unstructured. A task group would be tidier and
/// would not hold: a group awaits its children at scope exit, so `cancelAll()`
/// *asks* the work to stop and a transport that never observes cancellation
/// turns the bound into a suggestion. Cancellation is cooperative; a bound
/// cannot be. So whichever side loses is cancelled and never awaited, and the
/// bound holds against any transport.
///
/// Abandoning the loser costs little in practice: ``SubprocessTransport``
/// kills the child's whole process group on cancellation, so the task left
/// behind ends almost at once. A transport that ignores cancellation leaves
/// one running for as long as its own work takes — its defect, bounded by its
/// own work rather than by anything this library can reach.
package func withCommandDeadline<Value: Sendable>(
    _ timeout: Duration?,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws(TmuxError) -> Value {
    guard let timeout else { return try await withTmuxErrorMapping(operation) }
    guard timeout > .zero else { throw .timedOut(after: timeout) }
    if Task.isCancelled { throw .cancelled }

    let first = FirstAnswer<Value>()
    let work = Task {
        do {
            first.resolve(.completed(try await operation()))
        } catch {
            first.resolve(.failed(normalizedTmuxError(error)))
        }
    }
    let bound = Task {
        do {
            try await Task.sleep(for: timeout)
        } catch {
            return
        }
        first.resolve(.timedOut)
    }
    defer {
        work.cancel()
        bound.cancel()
    }

    let outcome = await withTaskCancellationHandler {
        await first.value
    } onCancel: {
        work.cancel()
        bound.cancel()
        first.resolve(.cancelled)
    }

    switch outcome {
    case let .completed(value): return value
    case let .failed(error): throw error
    // The bound, not a measurement of it: the bound holds, so the two agree,
    // and a caller can still match `timedOut(after: .seconds(5))` against the
    // value it asked for. Reporting elapsed time instead would make the error
    // accurate and unmatchable at once.
    case .timedOut: throw .timedOut(after: timeout)
    case .cancelled: throw .cancelled
    }
}

/// Whichever of the two racers answers first, delivered once.
///
/// `NSLock` rather than `Mutex`: `Synchronization` is macOS 15 and this
/// package declares macOS 13, which a Linux compiler has no availability to
/// check — the macOS lane would be the only thing that failed.
private final class FirstAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: CommandDeadlineRace<Value>?
    private var waiter: CheckedContinuation<CommandDeadlineRace<Value>, Never>?

    var value: CommandDeadlineRace<Value> {
        get async {
            await withCheckedContinuation { continuation in
                let ready: CommandDeadlineRace<Value>? = lock.withLock {
                    if let answer { return answer }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    func resolve(_ outcome: CommandDeadlineRace<Value>) {
        let waiting: CheckedContinuation<CommandDeadlineRace<Value>, Never>? = lock.withLock {
            guard answer == nil else { return nil }
            answer = outcome
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(returning: outcome)
    }
}

private enum CommandDeadlineRace<Value: Sendable>: Sendable {
    case completed(Value)
    case failed(TmuxError)
    case timedOut
    case cancelled
}
