// The example in <doc:Streaming>, and the streaming section of the README.

import LibTmux

public func beingToldRatherThanAsking(_ server: Server) async throws -> String? {
    let firstLine: String? = try await server.connected(attachingTo: "work") { server, events in
        for await notification in events.notifications
        where notification.name == "output" {
            return notification.arguments
        }
        return nil
    }
    return firstLine
}
