// The examples in <doc:Waiting>, and the waiting section of the README.

import LibTmux

public func waitingOnAChannel(_ server: Server, pane: Pane) async throws {
    try await server.run(
        "make; \(server.shellInvocation) wait-for -S built",
        in: pane
    )
    try await server.wait(for: "built")
}

public func watchingAFormat(_ server: Server, pane: Pane) async throws -> String? {
    try await server.connected(attachingTo: "work") { server, control in
        try await control.watch(
            FormatSubscription(
                name: "cmd",
                scope: .pane(pane.id),
                format: "#{pane_current_command}"
            )
        )
        for try await change in control.changes(named: "cmd") {
            return change.value
        }
        return nil
    }
}

public func waitingOnOutput(
    _ server: Server,
    pane: Pane
) async throws -> OutputWait {
    let ready = try RegexPattern("Listening on")
    let failed = try RegexPattern("EADDRINUSE|error", options: [.caseInsensitive])
    let waited = try await server.waitForOutput(
        in: pane,
        matching: [ready],
        stoppingAt: [failed]
    )
    return waited
}

public func watchingForChanges(
    _ server: Server,
    pane: Pane,
    building: Bool
) async throws {
    var mark = try await server.capture(pane, since: nil).cursor
    while building {
        let update = try await server.capture(pane, since: mark)
        for line in update.lines { print(line) }
        mark = update.cursor
    }
}
