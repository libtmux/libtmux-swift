import Foundation

/// Says that a call is still running, to a client that asked to be told.
///
/// A wait can hold a request for a minute, and without this the client cannot
/// tell that from a server that has died — so it either shows nothing or gives
/// up. MCP's answer is `notifications/progress`, which a client opts into by
/// putting a `progressToken` in a request's `_meta`. Measured against the Codex
/// CLI, which sends one on every `tools/call`.
///
/// Silent when no token was sent: an unsolicited notification is a protocol
/// error, not a courtesy.
public struct ProgressReporter: Sendable {
    /// Echoed back on every notification. A client matches it to the request
    /// it belongs to, and it may legitimately be `0` — absent is `nil`, not
    /// falsy.
    let token: JSONValue?
    let emit: @Sendable (String) async -> Void

    /// Reports nothing, for a caller with no client behind it.
    public static let silent = ProgressReporter(token: nil) { _ in }

    public init(token: JSONValue?, emit: @escaping @Sendable (String) async -> Void) {
        self.token = token
        self.emit = emit
    }

    /// Reads the token a request opted in with, if it sent one.
    static func token(in params: JSONValue?) -> JSONValue? {
        guard let value = params?["_meta"]?["progressToken"], !value.isNull else {
            return nil
        }
        return value
    }

    func report(_ progress: Double, of total: Double?, _ message: String) async {
        guard let token else { return }
        var body: [String: JSONValue] = [
            "progressToken": token,
            "progress": .number(progress),
            "message": .string(message),
        ]
        if let total { body["total"] = .number(total) }
        let notification: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/progress"),
            "params": .object(body),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(notification),
            data.count < MCPRequestHandler.maximumResponseBytes
        else { return }
        await emit(String(decoding: data, as: UTF8.self))
    }

    /// Runs `work`, saying how long it has been running until it finishes.
    ///
    /// The heartbeat costs nothing but a timer — no tmux command and no
    /// capture — so a tool that is waiting on events stays a tool that is
    /// waiting on events. `total` is the deadline, so a client can render the
    /// fraction rather than a spinner.
    func whileRunning<Result: Sendable>(
        upTo deadline: Duration,
        every interval: Duration = .seconds(2),
        describing label: String,
        _ work: @escaping @Sendable () async throws -> Result
    ) async rethrows -> Result {
        guard token != nil else { return try await work() }
        let total = deadline.secondsValue
        return try await withThrowingTaskGroup(of: Void.self, returning: Result.self) { group in
            group.addTask {
                var elapsed = 0.0
                let step = interval.secondsValue
                while elapsed < total {
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    elapsed = min(elapsed + step, total)
                    await report(
                        elapsed,
                        of: total,
                        "\(label) — \(Int(elapsed))s of \(Int(total))s"
                    )
                }
            }
            defer { group.cancelAll() }
            return try await work()
        }
    }

}
