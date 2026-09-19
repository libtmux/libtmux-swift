// The example in <doc:Streaming>, and the streaming section of the README.

import LibTmux

public func beingToldRatherThanAsking(_ server: Server) async throws -> String? {
    let firstOutput: String? = try await server.connected(attachingTo: "work") { server, events in
        for try await notification in events.notifications {
            if case let .output(_, bytes) = notification.event {
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        return nil
    }
    return firstOutput
}
