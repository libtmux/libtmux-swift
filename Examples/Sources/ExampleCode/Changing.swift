// The examples in the README's "Change what is there" section.

import LibTmux

public func buildASessionByHand(_ server: Server) async throws -> Pane {
    let session = try await server.newSession(named: "work", windowName: "editor")
    try await server.setOption("@purpose", to: "development", scope: .session(session))
    let logs = try await server.newWindow(in: session, named: "logs").window
    let pane = try await server.splitWindow(logs, direction: .right)
    try await server.run("tail -f /tmp/build.log", in: pane)
    return pane
}

public func runAProgramAndReadItsExit(
    _ server: Server,
    _ window: Window
) async throws -> Int? {
    try await server.setPanesOutliveTheirCommand(true)
    let pane = try await server.splitWindow(
        window,
        running: ["sh", "-c", "exit 42"],
        environment: ["CI": "1"]
    )
    var finished = try await server.refresh(pane)
    while finished?.isDead == false {
        finished = try await server.refresh(pane)
    }
    return finished?.exitStatus
}

public func setOptionsWithATypeAndATable(_ server: Server) async throws -> Int? {
    try await server.setOption(.mouse, to: true)
    let scrollback = try await server.option(.historyLimit)
    return scrollback
}

public func readBackWhatAPanePrinted(_ server: Server, _ pane: Pane) async throws -> [String] {
    let lines = try await server.capture(pane)
    print(lines.suffix(5).joined(separator: "\n"))
    return lines
}

public func spendOneProcessOnAllOfIt(_ server: Server) async throws {
    var plan = TmuxCommandList()
    for name in ["edit", "test", "logs"] {
        plan = plan.then("new-window", ["-d", "-n", name])
    }
    _ = try await server.run(plan)
}

public func arrangeSideBySide(_ server: Server, _ window: Window) async throws(TmuxError) {
    try await server.selectLayout(window, .evenHorizontal)
}

public func restoreSavedLayout(
    _ server: Server, _ window: Window, _ savedLayout: String
) async throws(TmuxError) {
    try await server.selectLayout(window, .custom(savedLayout))
}
