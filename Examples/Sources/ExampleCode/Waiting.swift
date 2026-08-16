// The examples in <doc:Waiting>, and the waiting section of the README.

import LibTmux

public func waitingOnAChannel(_ server: Server, pane: Pane) async throws {
    try await server.run("make && tmux wait-for -S built", in: pane)
    try await server.wait(for: "built")
}

public func watchingAFormat(_ server: Server, pane: Pane) async throws {
    try await server.connected(attachingTo: "work") { server, control in
        try await control.watch(
            FormatSubscription(
                name: "cmd",
                scope: .pane(pane.id),
                format: "#{pane_current_command}"
            )
        )
        for await change in control.changes(named: "cmd") where change.value == "sh" {
            return
        }
    }
}

public func waitingOnOutput(_ server: Server, pane: Pane) async throws -> OutputWait {
    let waited = try await server.waitForOutput(
        in: pane,
        matching: ["Listening on"],
        stoppingAt: ["EADDRINUSE", "error"]
    )
    return waited
}
