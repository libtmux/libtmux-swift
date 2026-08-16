import Foundation

/// Hands every observer its own copy of a connection's notifications.
///
/// `AsyncStream` has one logical consumer: two iterators over the same stream
/// divide its elements rather than each receiving all of them. A waiter and a
/// watcher on one connection are exactly that shape, and the division is
/// silent — each simply misses roughly half of what it asked for.
final class NotificationBroadcast: Sendable {
    private struct State {
        var observers: [Int: AsyncStream<ControlNotification>.Continuation] = [:]
        var nextObserver = 0
        /// Replayed to the first observer, then discarded. Sending a command
        /// and *then* watching for what it caused is the ordinary way to write
        /// this, and a notification that arrived in between would otherwise be
        /// lost to a race the caller cannot see. Nothing accumulates once an
        /// observer exists, because from then on there is nothing to catch up
        /// on.
        var backlog: [ControlNotification]? = []
        var isFinished = false
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var state = State()

    /// A stream carrying every notification from here on, preceded by the
    /// backlog if this is the first observer.
    func subscribe() -> AsyncStream<ControlNotification> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let registration: Int? = withLock {
                if let backlog = state.backlog {
                    for notification in backlog { continuation.yield(notification) }
                    state.backlog = nil
                }
                guard !state.isFinished else { return nil }
                let observer = state.nextObserver
                state.nextObserver += 1
                state.observers[observer] = continuation
                return observer
            }
            guard let registration else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [self] _ in
                withLock { _ = state.observers.removeValue(forKey: registration) }
            }
        }
    }

    func yield(_ notification: ControlNotification) {
        // Buffering is unbounded because `%output` carries pane bytes rather
        // than state: dropping one loses terminal output with nothing to say
        // it went missing, and an observer watching for a particular line
        // would wait for something silently discarded. A caller that opens a
        // connection is expected to drain it or keep the scope short.
        let observers = withLock { () -> [AsyncStream<ControlNotification>.Continuation] in
            if state.backlog != nil { state.backlog?.append(notification) }
            return Array(state.observers.values)
        }
        for observer in observers { observer.yield(notification) }
    }

    func finish() {
        let observers = withLock { () -> [AsyncStream<ControlNotification>.Continuation] in
            state.isFinished = true
            let existing = Array(state.observers.values)
            state.observers = [:]
            state.backlog = nil
            return existing
        }
        for observer in observers { observer.finish() }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
