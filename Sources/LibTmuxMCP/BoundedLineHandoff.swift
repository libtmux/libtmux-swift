import Foundation

package final class BoundedLineHandoff: AsyncSequence, @unchecked Sendable {
    package typealias Element = String

    package struct AsyncIterator: AsyncIteratorProtocol {
        private let handoff: BoundedLineHandoff

        fileprivate init(handoff: BoundedLineHandoff) {
            self.handoff = handoff
        }

        package mutating func next() async -> String? {
            guard let line = await handoff.next() else { return nil }
            handoff.acknowledge()
            return line
        }
    }

    private let capacity: Int
    private let condition = NSCondition()
    private var lines: [String] = []
    private var outstanding = 0
    private var finished = false
    private var closed = false
    private var waitingConsumer: CheckedContinuation<String?, Never>?

    package init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    package func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(handoff: self)
    }

    package func submit(_ line: String) -> Bool {
        condition.lock()
        while outstanding >= capacity, !closed {
            condition.wait()
        }
        guard !closed, !finished else {
            condition.unlock()
            return false
        }

        outstanding += 1
        let consumer = waitingConsumer
        waitingConsumer = nil
        if consumer == nil {
            lines.append(line)
        }
        condition.unlock()
        consumer?.resume(returning: line)
        return true
    }

    package func next() async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                condition.lock()
                if Task.isCancelled || closed || (finished && lines.isEmpty) {
                    condition.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if !lines.isEmpty {
                    let line = lines.removeFirst()
                    condition.unlock()
                    continuation.resume(returning: line)
                    return
                }
                precondition(waitingConsumer == nil)
                waitingConsumer = continuation
                condition.unlock()
            }
        } onCancel: {
            cancelWaitingConsumer()
        }
    }

    package func acknowledge() {
        condition.lock()
        if outstanding > 0 {
            outstanding -= 1
            condition.broadcast()
        }
        condition.unlock()
    }

    package func finish() {
        condition.lock()
        finished = true
        let consumer = lines.isEmpty ? waitingConsumer : nil
        if consumer != nil {
            waitingConsumer = nil
        }
        condition.unlock()
        consumer?.resume(returning: nil)
    }

    package func close() {
        condition.lock()
        closed = true
        lines.removeAll()
        outstanding = 0
        let consumer = waitingConsumer
        waitingConsumer = nil
        condition.broadcast()
        condition.unlock()
        consumer?.resume(returning: nil)
    }

    private func cancelWaitingConsumer() {
        condition.lock()
        let consumer = waitingConsumer
        waitingConsumer = nil
        condition.unlock()
        consumer?.resume(returning: nil)
    }
}
