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
    /// spelling needs macOS 15 where this package supports 13. Package-only
    /// transports share the generic request loop below.
    public func serve(
        _ lines: AsyncStream<String>,
        write: @escaping @Sendable (String) async -> Void
    ) async {
        let writeUntilFailure: @Sendable (String) async -> Bool = { line in
            await write(line)
            return true
        }
        await serveUntilWriteFails(lines, write: writeUntilFailure)
    }

    /// Reads requests until input ends, cancellation arrives, or `write` fails.
    ///
    /// A `false` result closes active requests and drops queued output. A
    /// successful writer preserves the normal end-of-input drain.
    package func serveUntilWriteFails(
        _ lines: AsyncStream<String>,
        write: @escaping @Sendable (String) async -> Bool
    ) async {
        await serveUntilWriteFails(
            read: { registry, outbound in
                await readRequests(lines, registry: registry, outbound: outbound)
            },
            write: write
        )
    }

    package func serveUntilWriteFails(
        _ handoff: BoundedLineHandoff,
        write: @escaping @Sendable (String) async -> Bool
    ) async {
        defer { handoff.close() }
        await serveUntilWriteFails(
            read: { registry, outbound in
                await readRequests(handoff, registry: registry, outbound: outbound)
            },
            write: write
        )
    }

    private func serveUntilWriteFails(
        read: @escaping @Sendable (RequestRegistry, OrderedOutbound) async -> Void,
        write: @escaping @Sendable (String) async -> Bool
    ) async {
        let registry = RequestRegistry()
        let outbound = OrderedOutbound(capacity: maximumInFlightRequests)
        await withTaskCancellationHandler {
            await withTaskGroup(of: ServiceEvent.self) { tasks in
                tasks.addTask {
                    await read(registry, outbound)
                    return .inputEnded
                }
                tasks.addTask {
                    while !Task.isCancelled, let message = await outbound.next() {
                        guard await write(message) else { return .writerFailed }
                        await outbound.didWrite()
                    }
                    return .outputEnded
                }

                var inputEnded = false
                while let event = await tasks.next() {
                    if Task.isCancelled {
                        await registry.close()
                        await outbound.cancel()
                        tasks.cancelAll()
                        return
                    }
                    switch event {
                    case .inputEnded:
                        inputEnded = true
                        await outbound.finish()
                    case .outputEnded:
                        if inputEnded { return }
                        await registry.close()
                        await outbound.cancel()
                        tasks.cancelAll()
                        return
                    case .writerFailed:
                        await registry.close()
                        await outbound.cancel()
                        tasks.cancelAll()
                        return
                    }
                }
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

    private func readRequests<Lines: AsyncSequence>(
        _ lines: Lines,
        registry: RequestRegistry,
        outbound: OrderedOutbound
    ) async where Lines.Element == String, Lines.Failure == Never {
        await withTaskGroup(of: Void.self) { requestGroup in
            for await line in lines {
                if Task.isCancelled { break }
                let decoded = MCPRequestHandler.decodeRequest(line)
                // Cancellation arrives as a notification, so it is read before
                // anything that would answer: it has no id of its own to reply
                // to, and it must overtake the request it cancels.
                if case let .request(request) = decoded,
                    let cancelled = request.cancelledRequestID
                {
                    await registry.cancel(cancelled)
                    continue
                }
                guard case let .request(request) = decoded, let identifier = request.id else {
                    if let response = await handler.respond(to: decoded),
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
                                to: decoded,
                                emit: { _ = await outbound.offer($0) }
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
    }
}

private enum ServiceEvent: Sendable {
    case inputEnded
    case outputEnded
    case writerFailed
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
