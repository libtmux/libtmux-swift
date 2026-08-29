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
    /// `AsyncStream` concretely, rather than any non-throwing `AsyncSequence`:
    /// naming the failure type is what makes a sequence non-throwing, and that
    /// spelling needs macOS 15 where this package supports 13. Both callers
    /// have a stream in hand anyway — one reading a pipe, one a test.
    public func serve(
        _ lines: AsyncStream<String>,
        write: @escaping @Sendable (String) async -> Void
    ) async {
        let registry = RequestRegistry()
        await withDiscardingTaskGroup { group in
            for await line in lines {
                // Cancellation arrives as a notification, so it is read before
                // anything that would answer: it has no id of its own to reply
                // to, and it must overtake the request it cancels.
                if let cancelled = MCPRequestHandler.cancelledRequestID(in: line) {
                    await registry.cancel(cancelled)
                    continue
                }
                guard let identifier = MCPRequestHandler.requestID(in: line) else {
                    if let response = await handler.respond(to: line) {
                        await write(response)
                    }
                    continue
                }
                guard
                    let work = await registry.start(
                        identifier,
                        maximum: maximumInFlightRequests,
                        operation: {
                            // Progress and answers share the serialised writer,
                            // so the two cannot interleave.
                            await handler.respond(to: line, emit: write)
                        }
                    )
                else {
                    if let response = handler.capacityFailure(
                        id: identifier,
                        maximum: maximumInFlightRequests
                    ) {
                        await write(response)
                    }
                    continue
                }
                group.addTask {
                    let answer = await work.value
                    if let answer { await write(answer) }
                    await registry.finish(identifier)
                }
            }
        }
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

    func start(
        _ id: JSONValue,
        maximum: Int,
        operation: @escaping @Sendable () async -> String?
    ) -> Task<String?, Never>? {
        guard entries[id] == nil, entries.count < maximum else { return nil }
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
