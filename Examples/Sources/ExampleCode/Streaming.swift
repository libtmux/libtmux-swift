// The example in <doc:Streaming>, and the streaming section of the README.

import LibTmux

// Compiled, never executed: the loop has no way out, so running it verbatim
// never returns. That is a property of the example as documented rather than of
// the library — `ControlModeTests` drives the same machinery live by returning
// from the loop on the notification it was waiting for.
public func beingToldRatherThanAsking(_ server: Server) async throws {
    try await server.connected(attachingTo: "work") { server, events in
        for await notification in events.notifications
        where notification.name == "output" {
            print(notification.arguments)
        }
    }
}
