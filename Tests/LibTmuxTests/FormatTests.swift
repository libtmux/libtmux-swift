import Testing
import TmuxFixture

@testable import LibTmux

@Suite("ad-hoc formats", .timeLimit(.minutes(5)))
struct FormatTests {
    @Test("a format reads a field the models do not carry")
    func formatReadsAnUnmodelledField() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == pane.windowID }
            )
            let tty = try #require(
                try await server.format("#{pane_tty}", for: pane, through: link)
            )
            #expect(tty.hasPrefix("/dev/"))
        }
    }

    @Test("a format resolves a session, a window, and a pane target alike")
    func formatResolvesEveryTargetKind() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let window = try #require(try await server.windows().first)
            let pane = try #require(try await server.panes().first)
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == window.id }
            )

            #expect(try await server.format("#{session_name}", for: session) == session.name)
            #expect(try await server.format("#{window_name}", for: link) == window.name)
            #expect(
                try await server.format("#{pane_id}", for: pane, through: link)
                    == pane.id.rawValue
            )
        }
    }

    @Test("a linked window format is evaluated through the selected session")
    func linkedWindowFormatUsesTheSelectedSession() async throws {
        try await withTmuxServer { server in
            let sourceSession = try #require(try await server.sessions().first)
            let source = try #require(try await server.windowLinks().first)
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.windowID }
            )
            let window = try #require(
                try await server.windows().first { $0.id == source.windowID }
            )
            let destinationSession = try await server.newSession(named: "format-destination")
            let destination = try await server.link(window, into: destinationSession)

            #expect(
                try await server.format("#{session_name}", for: source)
                    == sourceSession.name
            )
            #expect(
                try await server.format("#{session_name}", for: destination)
                    == destinationSession.name
            )
            #expect(
                try await server.format("#{session_name}", for: pane, through: destination)
                    == destinationSession.name
            )
        }
    }

    @Test("a reindexed link cannot format the window now at its old target")
    func reindexedLinkCannotFormatItsReplacement() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let firstWindow = try #require(try await server.windows().first)
            _ = try await server.newWindow(in: session, named: "format-replacement")
            let links = try await server.windowLinks()
                .filter { $0.sessionID == session.id }
                .sorted { $0.index < $1.index }
            let first = try #require(links.first { $0.windowID == firstWindow.id })
            let other = try #require(links.first { $0.windowID != firstWindow.id })
            let pane = try #require(
                try await server.panes().first { $0.windowID == first.windowID }
            )

            try await server.swap(first, with: other)

            #expect(try await server.format("#{window_id}", for: first) == nil)
            #expect(
                try await server.format("#{window_id}:#{pane_id}", for: pane, through: first)
                    == nil
            )
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
            let window = try await server.newWindow(in: session).window
            let pane = try #require(
                try await server.panes().first { $0.windowID == window.id }
            )
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == window.id }
            )
            try await server.kill(session)

            // tmux answers an unresolvable target with empty output and a zero
            // exit, the same as any other empty answer, so nothing but a probe
            // tells the two apart.
            #expect(try await server.format("#{pane_tty}", for: pane, through: link) == nil)
            #expect(try await server.format("#{window_name}", for: link) == nil)
            #expect(try await server.format("#{session_name}", for: session) == nil)
        }
    }

    @Test("a field that is genuinely empty is not a missing target")
    func anEmptyValueIsNotAMissingTarget() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == pane.windowID }
            )
            // No search has run in this pane, so tmux has an answer and it is
            // the empty string. That is a value, not an absence.
            #expect(
                try await server.format("#{pane_search_string}", for: pane, through: link) == ""
            )
        }
    }

    @Test("a template can read several fields at once, separated as you like")
    func formatReadsSeveralFieldsAtOnce() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == pane.windowID }
            )
            let both = try #require(
                try await server.format(
                    "#{pane_id}:#{window_id}", for: pane, through: link)
            )
            #expect(both == "\(pane.id):\(pane.windowID)")
        }
    }

    @Test("a value carrying the separator the probe uses arrives whole")
    func aValueCarryingTheSeparatorSurvives() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let link = try #require(
                try await server.windowLinks().first { $0.windowID == pane.windowID }
            )
            // Only the first separator divides the probe from the answer, so
            // a value containing one of its own is not cut short by it.
            let carried = "a\(FormatProjection.separator)b"
            _ = try await server.setOption("@carried", to: carried, scope: .server)
            #expect(
                try await server.format("#{@carried}", for: pane, through: link) == carried
            )
        }
    }

    @Test("a condition nests its operands and escapes them")
    func conditionNestsAndEscapes() {
        #expect(FormatCondition.equals("pane_id", 3).text == "#{==:#{pane_id},3}")
        // `#`, `,` and `}` end a comparison operand unless tmux is told they do
        // not, so a socket path carrying one still compares as itself.
        #expect(
            FormatCondition.equals("socket_path", "a,b}c#d").text
                == "#{==:#{socket_path},a#,b#}c##d}"
        )
        #expect(
            FormatCondition.all(
                .equals("a", 1),
                .equals("b", 2),
                .equals("c", 3)
            ).text == "#{&&:#{==:#{a},1},#{&&:#{==:#{b},2},#{==:#{c},3}}}"
        )
    }
}
