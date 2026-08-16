import Foundation
import LibTmux

/// Serves MCP over a stream of request lines.
///
/// Every request runs in a task of its own, which is the whole point: a wait
/// that blocks for thirty seconds must not stop `ping`, a second wait, or the
/// cancellation that would end it. Serving them one at a time makes the
/// server's slowest tool its latency for everything.
public struct MCPService: Sendable {
    private let handler: MCPRequestHandler

    public init(handler: MCPRequestHandler) {
        self.handler = handler
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
        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                // Cancellation arrives as a notification, so it is read before
                // anything that would answer: it has no id of its own to reply
                // to, and it must overtake the request it cancels.
                if let cancelled = MCPRequestHandler.cancelledRequestID(in: line) {
                    await registry.cancel(cancelled)
                    continue
                }
                let identifier = MCPRequestHandler.requestID(in: line)
                group.addTask {
                    let work = Task {
                        await handler.respond(to: line)
                    }
                    if let identifier {
                        await registry.register(identifier, work)
                    }
                    let answer = await work.value
                    if let identifier { await registry.finish(identifier) }
                    guard let answer else { return }
                    await write(answer)
                }
            }
        }
    }
}

/// Tracks what is in flight so a cancellation can reach it.
private actor RequestRegistry {
    private var tasks: [JSONValue: Task<String?, Never>] = [:]

    func register(_ id: JSONValue, _ task: Task<String?, Never>) {
        tasks[id] = task
    }

    func finish(_ id: JSONValue) {
        tasks[id] = nil
    }

    func cancel(_ id: JSONValue) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }
}

extension MCPRequestHandler {
    /// The id a request will be answered under, for tracking it while it runs.
    public static func requestID(in line: String) -> JSONValue? {
        guard
            let request = try? JSONDecoder().decode(
                MCPRequest.self,
                from: Data(line.utf8)
            )
        else { return nil }
        return request.id
    }
}
