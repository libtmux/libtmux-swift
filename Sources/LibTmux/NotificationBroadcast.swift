import Foundation

/// One observer's control notifications with finite pending storage.
public struct ControlNotificationStream: AsyncSequence, Sendable {
    typealias Continuation = Base.Continuation

    typealias Base = AsyncThrowingStream<ControlNotification, any Error>
    private let base: Base

    init(
        bufferingPolicy: Continuation.BufferingPolicy = .unbounded,
        _ build: (Continuation) -> Void
    ) {
        self.base = Base(bufferingPolicy: bufferingPolicy, build)
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base.makeAsyncIterator())
    }

    /// Iterates notifications with `TmuxError` as the failure type.
    public struct Iterator: AsyncIteratorProtocol {
        private var base: Base.Iterator

        fileprivate init(_ base: Base.Iterator) {
            self.base = base
        }

        public mutating func next() async throws(TmuxError) -> ControlNotification? {
            do {
                return try await base.next()
            } catch {
                throw normalizedTmuxError(error)
            }
        }
    }
}

/// Hands every observer its own copy of a connection's notifications.
///
/// `AsyncStream` has one logical consumer: two iterators over the same stream
/// divide its elements rather than each receiving all of them. A waiter and a
/// watcher on one connection are exactly that shape, and the division is
/// silent — each simply misses roughly half of what it asked for.
final class NotificationBroadcast: Sendable {
    static let defaultLimit = 256

    private struct State {
        var observers: [Int: ControlNotificationStream.Continuation] = [:]
        var nextObserver = 0
        /// Replayed to the first observer, then discarded. Sending a command
        /// and *then* watching for what it caused is the ordinary way to write
        /// this, and a notification that arrived in between would otherwise be
        /// lost to a race the caller cannot see. Nothing accumulates once an
        /// observer exists, because from then on there is nothing to catch up
        /// on.
        var backlog: [ControlNotification]? = []
        var backlogOverflowed = false
        var isFinished = false
    }

    private let limit: Int
    private let lock = NSLock()
    private nonisolated(unsafe) var state = State()

    init(limit: Int = defaultLimit) {
        precondition(limit > 0)
        self.limit = limit
    }

    /// A stream carrying every notification from here on, preceded by the
    /// backlog if this is the first observer.
    func subscribe() -> ControlNotificationStream {
        ControlNotificationStream(bufferingPolicy: .bufferingOldest(limit)) { continuation in
            var overflowed = false
            let registration: Int? = withLock {
                if let backlog = state.backlog {
                    for notification in backlog { continuation.yield(notification) }
                    overflowed = state.backlogOverflowed
                    state.backlog = nil
                    state.backlogOverflowed = false
                }
                guard !overflowed, !state.isFinished else { return nil }
                let observer = state.nextObserver
                state.nextObserver += 1
                state.observers[observer] = continuation
                return observer
            }
            guard let registration else {
                if overflowed {
                    continuation.finish(
                        throwing: TmuxError.notificationBufferOverflow(limit: limit)
                    )
                } else {
                    continuation.finish()
                }
                return
            }
            continuation.onTermination = { [self] _ in
                withLock { _ = state.observers.removeValue(forKey: registration) }
            }
        }
    }

    func yield(_ notification: ControlNotification) {
        let overflowed = withLock { () -> [ControlNotificationStream.Continuation] in
            if state.backlog != nil {
                if state.backlog?.count ?? 0 < limit {
                    state.backlog?.append(notification)
                } else {
                    state.backlogOverflowed = true
                }
            }
            var dropped: [Int] = []
            for (id, observer) in state.observers {
                if case .dropped = observer.yield(notification) { dropped.append(id) }
            }
            return dropped.compactMap { state.observers.removeValue(forKey: $0) }
        }
        for observer in overflowed {
            observer.finish(throwing: TmuxError.notificationBufferOverflow(limit: limit))
        }
    }

    func finish() {
        let observers = withLock { () -> [ControlNotificationStream.Continuation] in
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
