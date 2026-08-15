// The examples in the README's "Change what is there" section.

import LibTmux

func buildASessionByHand(_ server: Server) async throws {
    let session = try await server.newSession(named: "work", windowName: "editor")
    let logs = try await server.newWindow(in: session, named: "logs")
    let pane = try await server.splitWindow(logs, direction: .right)
    try await server.run("tail -f /tmp/build.log", in: pane)
}

func readBackWhatAPanePrinted(_ server: Server, _ pane: Pane) async throws {
    let lines = try await server.capture(pane)
    print(lines.suffix(5).joined(separator: "\n"))
}

func spendOneProcessOnAllOfIt(_ server: Server) async throws {
    var plan = TmuxCommandList()
    for name in ["edit", "test", "logs"] {
        plan = plan.then("new-window", ["-d", "-n", name])
    }
    _ = try await server.run(plan)
}
