import Foundation
import LibTmux

/// Serves MCP over a stream of request lines.
///
/// Every request runs in a task of its own, which is the whole point: a wait
/// that blocks for thirty seconds must not stop `ping`, a second wait, or the
/// cancellation that would end it. Serving them one at a time makes the
/// server's slowest tool its latency for everything.
public struct MCPService: Sendable {
    static let defaultMaximumInFlightRequests = 64

    private let handler: MCPRequestHandler
    private let maximumInFlightRequests: Int

    public init(handler: MCPRequestHandler) {
        self.handler = handler
        self.maximumInFlightRequests = Self.defaultMaximumInFlightRequests
    }

    init(handler: MCPRequestHandler, maximumInFlightRequests: Int) {
        precondition(maximumInFlightRequests > 0)
        self.handler = handler
        self.maximumInFlightRequests = maximumInFlightRequests
    }

    /// Reads requests from `lines` and writes each answer through `write`.
    ///
    /// Returns once `lines` has ended *and* every request it carried has been
    /// answered. The end of input means no more requests, not abandon the ones
    /// in hand: a client that sent a batch and closed its end is still owed the
    /// replies, and cancelling them would drop answers that were already
    /// computed.
    /// Cancelling this call cancels active requests and queued output. The
    /// `write` closure must return cooperatively when its task is cancelled.
    /// `AsyncStream` concretely, rather than any non-throwing `AsyncSequence`:
    /// naming the failure type is what makes a sequence non-throwing, and that
    /// spelling needs macOS 15 where this package supports 13. Both callers
    /// have a stream in hand anyway — one reading a pipe, one a test.
    public func serve(
        _ lines: AsyncStream<String>,
        write: @escaping @Sendable (String) async -> Void
    ) async {
        let registry = RequestRegistry()
        let outbound = OrderedOutbound(capacity: maximumInFlightRequests)
        await withTaskCancellationHandler {
            await withDiscardingTaskGroup { outputGroup in
                outputGroup.addTask {
                    while !Task.isCancelled, let message = await outbound.next() {
                        await write(message)
                        await outbound.didWrite()
                    }
                }
                await withDiscardingTaskGroup { requestGroup in
                    for await line in lines {
                        if Task.isCancelled { break }
                        // Cancellation arrives as a notification, so it is read before
                        // anything that would answer: it has no id of its own to reply
                        // to, and it must overtake the request it cancels.
                        if let cancelled = MCPRequestHandler.cancelledRequestID(in: line) {
                            await registry.cancel(cancelled)
                            continue
                        }
                        guard let identifier = MCPRequestHandler.requestID(in: line) else {
                            if let response = await handler.respond(to: line),
                                !(await outbound.enqueue(response))
                            {
                                break
                            }
                            continue
                        }
                        guard
                            let work = await registry.start(
                                identifier,
                                maximum: maximumInFlightRequests,
                                operation: {
                                    await handler.respond(
                                        to: line,
                                        emit: { _ = await outbound.enqueue($0) }
                                    )
                                }
                            )
                        else {
                            if let response = handler.capacityFailure(
                                id: identifier,
                                maximum: maximumInFlightRequests
                            ), !(await outbound.enqueue(response)) {
                                break
                            }
                            continue
                        }
                        requestGroup.addTask {
                            let answer = await withTaskCancellationHandler {
                                await work.value
                            } onCancel: {
                                work.cancel()
                            }
                            if !Task.isCancelled, let answer {
                                _ = await outbound.writeAndWait(answer)
                            }
                            await registry.finish(identifier)
                        }
                    }
                }
                await outbound.finish()
            }
            if Task.isCancelled {
                await registry.close()
                await outbound.cancel()
            }
        } onCancel: {
            Task {
                await registry.close()
                await outbound.cancel()
            }
        }
    }
}

/// Holds complete protocol lines for one ordered writer.
private actor OrderedOutbound {
    private struct Submission {
        let line: String
        let accepted: CheckedContinuation<Bool, Never>?
        let delivered: CheckedContinuation<Bool, Never>?
    }

    private enum State {
        case open
        case finishing
        case cancelled
    }

    private let capacity: Int
    private let pendingCapacity: Int
    private var state = State.open
    private var buffered: [Submission] = []
    private var pending: [Submission] = []
    private var activeDelivery: CheckedContinuation<Bool, Never>?
    private var receiver: CheckedContinuation<String?, Never>?

    init(capacity: Int) {
        precondition(capacity > 0 && capacity < Int.max)
        self.capacity = capacity
        // Each admitted request can suspend one submission; the sequential
        // input loop can suspend one more while emitting a protocol error.
        self.pendingCapacity = capacity + 1
    }

    func enqueue(_ line: String) async -> Bool {
        await withCheckedContinuation { accepted in
            submit(Submission(line: line, accepted: accepted, delivered: nil))
        }
    }

    func writeAndWait(_ line: String) async -> Bool {
        await withCheckedContinuation { delivered in
            submit(Submission(line: line, accepted: nil, delivered: delivered))
        }
    }

    func next() async -> String? {
        if !buffered.isEmpty {
            return activate(buffered.removeFirst())
        }
        guard state == .open else { return nil }
        return await withCheckedContinuation { continuation in
            precondition(receiver == nil)
            receiver = continuation
        }
    }

    func didWrite() {
        activeDelivery?.resume(returning: true)
        activeDelivery = nil
    }

    func finish() {
        guard state == .open else { return }
        state = .finishing
        if buffered.isEmpty {
            receiver?.resume(returning: nil)
            receiver = nil
        }
    }

    func cancel() {
        guard state != .cancelled else { return }
        state = .cancelled
        receiver?.resume(returning: nil)
        receiver = nil
        for submission in buffered {
            submission.delivered?.resume(returning: false)
        }
        buffered.removeAll()
        for submission in pending {
            submission.accepted?.resume(returning: false)
            submission.delivered?.resume(returning: false)
        }
        pending.removeAll()
        activeDelivery?.resume(returning: false)
        activeDelivery = nil
    }

    private func submit(_ submission: Submission) {
        guard state == .open else {
            submission.accepted?.resume(returning: false)
            submission.delivered?.resume(returning: false)
            return
        }
        if let receiver {
            self.receiver = nil
            submission.accepted?.resume(returning: true)
            activeDelivery = submission.delivered
            receiver.resume(returning: submission.line)
        } else if buffered.count < capacity {
            buffered.append(submission)
            submission.accepted?.resume(returning: true)
        } else if pending.count < pendingCapacity {
            pending.append(submission)
        } else {
            submission.accepted?.resume(returning: false)
            submission.delivered?.resume(returning: false)
        }
    }

    private func activate(_ submission: Submission) -> String {
        precondition(activeDelivery == nil)
        activeDelivery = submission.delivered
        if !pending.isEmpty {
            let admitted = pending.removeFirst()
            buffered.append(admitted)
            admitted.accepted?.resume(returning: true)
        }
        return submission.line
    }
}

/// Tracks what is in flight so a cancellation can reach it.
private actor RequestRegistry {
    private enum State {
        case running
        case completed
        case cancelled
    }

    private struct Entry {
        let task: Task<String?, Never>
        var state: State
    }

    private var entries: [JSONValue: Entry] = [:]
    private var isClosed = false

    func start(
        _ id: JSONValue,
        maximum: Int,
        operation: @escaping @Sendable () async -> String?
    ) -> Task<String?, Never>? {
        guard !isClosed, entries[id] == nil, entries.count < maximum else { return nil }
        let task = Task {
            let answer = await operation()
            return acceptCompletion(answer, for: id)
        }
        entries[id] = Entry(task: task, state: .running)
        return task
    }

    func finish(_ id: JSONValue) {
        entries[id] = nil
    }

    func cancel(_ id: JSONValue) {
        guard var entry = entries[id], case .running = entry.state else { return }
        entry.state = .cancelled
        entries[id] = entry
        entry.task.cancel()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            entry.state = .cancelled
            entries[id] = entry
            entry.task.cancel()
        }
    }

    private func acceptCompletion(_ answer: String?, for id: JSONValue) -> String? {
        guard var entry = entries[id], case .running = entry.state else { return nil }
        entry.state = .completed
        entries[id] = entry
        return answer
    }
}

extension MCPRequestHandler {
    /// The id a request will be answered under, for tracking it while it runs.
    public static func requestID(in line: String) -> JSONValue? {
        guard case let .request(request) = decodeRequest(line) else { return nil }
        return request.id
    }
}
