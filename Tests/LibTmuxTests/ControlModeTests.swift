import Testing
import TmuxFixture

@testable import LibTmux

@Suite("control mode", .timeLimit(.minutes(1)))
struct ControlModeTests {
    @Test("a reply belongs to the command that produced it")
    func replyBelongsToItsCommand() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let sessions = try await control.send(
                    TmuxCommand("list-sessions", ["-F", "#{session_name}"])
                )
                #expect(!sessions.isError)
                #expect(sessions.lines == ["bootstrap"])

                let message = try await control.send(
                    TmuxCommand("display-message", ["-p", "second"])
                )
                #expect(message.lines == ["second"])
                // Attribution, not concatenation: the second reply carries only
                // the second command's output, and a later block number.
                #expect(message.number > sessions.number)
            }
        }
    }

    @Test("a rejected command closes its block with an error, not the connection")
    func rejectedCommandDoesNotCloseTheConnection() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let failed = try await control.send(TmuxCommand("no-such-command"))
                #expect(failed.isError)
                #expect(failed.lines.contains { $0.contains("no-such-command") })

                // The connection survives it.
                let after = try await control.send(
                    TmuxCommand("display-message", ["-p", "alive"])
                )
                #expect(!after.isError)
                #expect(after.lines == ["alive"])
            }
        }
    }

    @Test("a command that prints nothing yields an empty reply")
    func silentCommandYieldsAnEmptyReply() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                let reply = try await control.send(
                    TmuxCommand("set-option", ["-s", "@quiet", "yes"])
                )
                #expect(!reply.isError)
                #expect(reply.lines.isEmpty)
            }
        }
    }

    @Test("pane output arrives as it happens, not by polling")
    func paneOutputArrivesAsItHappens() async throws {
        try await withTmuxServer { server in
            let marker = "libtmux-stream-marker"
            let seen = try await server.withControlMode(attachingTo: "bootstrap") {
                control in
                // %output is only reported for a session the connection is
                // attached to, which is why this runs inside the scope rather
                // than being set up beforehand.
                _ = try await control.send(
                    TmuxCommand(
                        "send-keys",
                        ["-t", "bootstrap", "echo \(marker)", "Enter"]
                    )
                )
                for await notification in control.notifications
                where notification.name == "output" {
                    if notification.arguments.contains(marker) { return true }
                }
                return false
            }
            #expect(seen, "pane output never reached the control connection")
        }
    }

    @Test("the server volunteers what changed without being asked")
    func serverVolunteersWhatChanged() async throws {
        try await withTmuxServer { server in
            let names = try await server.withControlMode(attachingTo: "bootstrap") {
                control in
                _ = try await control.send(
                    TmuxCommand("new-window", ["-d", "-t", "bootstrap"])
                )
                var seen: [String] = []
                for await notification in control.notifications {
                    seen.append(notification.name)
                    if seen.contains(where: { $0.hasPrefix("window") }) { break }
                }
                return seen
            }
            // Which notifications a release sends varies; that it reports a
            // window appearing does not.
            #expect(names.contains { $0.hasPrefix("window") })
        }
    }

    @Test("work done through control mode is visible to ordinary commands")
    func controlModeWorkIsVisibleOutside() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                _ = try await control.send(
                    TmuxCommand("new-session", ["-d", "-s", "made-in-control"])
                )
            }
            let sessions = try await server.sessions()
            #expect(sessions.contains { $0.name == "made-in-control" })
        }
    }

    @Test("the connection closes when its scope ends")
    func connectionClosesWithItsScope() async throws {
        try await withTmuxServer { server in
            try await server.withControlMode(attachingTo: "bootstrap") { control in
                _ = try await control.send(TmuxCommand("display-message", ["-p", "hi"]))
            }
            // The control client is gone, but the server it attached to is not.
            let clients = try await server.clients()
            #expect(clients.isEmpty)
            let running = try await server.isRunning()
            #expect(running)
        }
    }
}
