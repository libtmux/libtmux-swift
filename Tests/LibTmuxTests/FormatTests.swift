import Testing
import TmuxFixture

@testable import LibTmux

@Suite("ad-hoc formats", .timeLimit(.minutes(1)))
struct FormatTests {
    @Test("a format reads a field the models do not carry")
    func formatReadsAnUnmodelledField() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tty = try #require(try await server.format("#{pane_tty}", for: pane))
            #expect(tty.hasPrefix("/dev/"))
        }
    }

    @Test("a format resolves a session, a window, and a pane target alike")
    func formatResolvesEveryTargetKind() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let window = try #require(try await server.windows().first)
            let pane = try #require(try await server.panes().first)

            #expect(try await server.format("#{session_name}", for: session) == session.name)
            #expect(try await server.format("#{window_name}", for: window) == window.name)
            #expect(try await server.format("#{pane_id}", for: pane) == pane.id)
        }
    }

    @Test("a format with no target answers for the server")
    func formatWithoutATargetAnswersForTheServer() async throws {
        try await withTmuxServer { server in
            let reported = try #require(try await server.format("#{pid}"))
            #expect(Int(reported) == (try await server.serverProcessID()))
        }
    }

    @Test("a target that no longer exists reports nothing at all")
    func formatOfADeadTargetReportsNothing() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "doomed")
            let window = try await server.newWindow(in: session)
            let pane = try #require(
                try await server.panes().first { $0.windowID == window.id }
            )
            try await server.kill(session)

            // tmux answers an unresolvable target with empty output and a zero
            // exit, the same as any other empty answer, so nothing but a probe
            // tells the two apart.
            #expect(try await server.format("#{pane_tty}", for: pane) == nil)
            #expect(try await server.format("#{window_name}", for: window) == nil)
            #expect(try await server.format("#{session_name}", for: session) == nil)
        }
    }

    @Test("a field that is genuinely empty is not a missing target")
    func anEmptyValueIsNotAMissingTarget() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            // Nothing started this pane by name, so tmux has an answer and it
            // is the empty string. That is a value, not an absence.
            #expect(try await server.format("#{pane_start_command}", for: pane) == "")
        }
    }

    @Test("a template can read several fields at once, separated as you like")
    func formatReadsSeveralFieldsAtOnce() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let both = try #require(
                try await server.format("#{pane_id}:#{window_id}", for: pane)
            )
            #expect(both == "\(pane.id):\(pane.windowID)")
        }
    }

    @Test("a value carrying the separator the probe uses arrives whole")
    func aValueCarryingTheSeparatorSurvives() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            // Only the first separator divides the probe from the answer, so
            // a value containing one of its own is not cut short by it.
            let carried = "a\(FormatProjection.separator)b"
            _ = try await server.setOption("@carried", to: carried, scope: .server)
            #expect(
                try await server.format("#{@carried}", for: pane) == carried
            )
        }
    }
}
