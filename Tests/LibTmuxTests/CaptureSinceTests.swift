import Testing
import TmuxFixture

@testable import LibTmux

@Suite("reading only what is new", .timeLimit(.minutes(1)))
struct CaptureSinceTests {
    private func bootstrapPane(_ server: Server) async throws -> Pane {
        try #require(try await server.panes().first)
    }

    /// Reads until `lines` are non-empty or the attempts run out, because a
    /// pane answers when its shell gets round to it.
    private func settle(
        _ server: Server,
        _ pane: Pane,
        from cursor: CaptureCursor
    ) async throws -> IncrementalCapture {
        var latest = IncrementalCapture(lines: [], cursor: cursor)
        for _ in 0..<40 {
            latest = try await server.capture(pane, since: latest.cursor)
            if !latest.lines.isEmpty { return latest }
            try await Task.sleep(for: .milliseconds(100))
        }
        return latest
    }

    @Test("the first read marks the place rather than dumping the backlog")
    func firstReadStartsWatching() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.run("printf 'before-watching\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            let started = try await server.capture(pane, since: nil)
            // A watcher asked to start now should not be handed a screenful of
            // what happened before it asked.
            #expect(started.lines.isEmpty)
            #expect(!started.restarted)
        }
    }

    @Test("a second read answers only what arrived between them")
    func secondReadIsTheDifference() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            try await server.run("printf 'first-new-line\\n'", in: pane)

            let next = try await settle(server, pane, from: started.cursor)
            #expect(next.lines.contains { $0.contains("first-new-line") })
            // What the pane showed before the cursor is not repeated.
            #expect(!next.lines.contains { $0.contains("$ ") && $0.isEmpty })
        }
    }

    @Test("a quiet pane answers nothing at all")
    func quietPaneAnswersNothing() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            try await server.run("printf 'settled\\n'", in: pane)
            let caught = try await settle(server, pane, from: started.cursor)

            try await Task.sleep(for: .milliseconds(300))
            let quiet = try await server.capture(pane, since: caught.cursor)
            // The whole point: watching something that is not happening costs
            // one command and no content.
            #expect(quiet.lines.isEmpty)

            let stillQuiet = try await server.capture(pane, since: quiet.cursor)
            #expect(stillQuiet.lines.isEmpty)
        }
    }

    @Test("a row rewritten in place is reported again")
    func rewrittenRowIsReportedAgain() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            // A carriage return without a newline rewrites the row, which is
            // what a spinner or a progress bar does. Position alone cannot see
            // that; the row's contents can.
            try await server.run("printf 'step one\\rstep two\\n'", in: pane)

            let caught = try await settle(server, pane, from: started.cursor)
            #expect(caught.lines.contains { $0.contains("step two") })
        }
    }

    @Test("a cursor from another pane starts over rather than lying")
    func cursorFromAnotherPaneRestarts() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let other = try await server.split(pane)
            let started = try await server.capture(pane, since: nil)

            let crossed = try await server.capture(other, since: started.cursor)
            // Anchors are per pane; using one against another would report
            // rows that were never there.
            #expect(crossed.lines.isEmpty)
            #expect(crossed.cursor.pane == other.id)
        }
    }

    @Test("a respawned pane says so rather than mixing two programs")
    func respawnIsReported() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let started = try await server.capture(pane, since: nil)
            try await server.respawn(pane)
            try await Task.sleep(for: .milliseconds(400))

            let after = try await server.capture(pane, since: started.cursor)
            // The cursor described a process that no longer exists, and the
            // rows it counted belong to it.
            #expect(after.restarted)
            #expect(after.lines.isEmpty)
        }
    }
}
