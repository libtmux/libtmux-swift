import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

private func session(_ id: String, _ name: String) -> Session {
    Session(id: id, name: name, windowCount: 1, isAttached: false, createdAt: 0)
}

private func window(_ id: String, session: String, name: String = "w") -> Window {
    Window(
        id: id, name: name, index: 0, paneCount: 1, isActive: true,
        width: 80, height: 24, sessionID: session
    )
}

private func pane(_ id: String, window: String, session: String, command: String) -> Pane {
    Pane(
        id: id, index: 0, width: 80, height: 24, isActive: true,
        currentCommand: command, currentPath: "/", windowID: window, sessionID: session
    )
}

/// Two sessions: `$0` runs editors throughout, `$1` runs a shell alongside one.
/// `$2` has no panes at all, which is what makes `.every` and `.none` differ.
private let snapshot = Snapshot(
    serverProcessID: 4242,
    sessions: [session("$0", "editors"), session("$1", "mixed"), session("$2", "bare")],
    windows: [
        window("@0", session: "$0"),
        window("@1", session: "$1"),
    ],
    panes: [
        pane("%0", window: "@0", session: "$0", command: "nvim"),
        pane("%1", window: "@0", session: "$0", command: "vim"),
        pane("%2", window: "@1", session: "$1", command: "nvim"),
        pane("%3", window: "@1", session: "$1", command: "zsh"),
    ],
    clients: []
)

@Suite("snapshot relations")
struct SnapshotRelationTests {
    @Test("relations resolve without touching tmux")
    func relationsResolveLocally() throws {
        let editors = try #require(snapshot.sessions.first)
        #expect(snapshot.windows(of: editors).map(\.id) == ["@0"])
        #expect(snapshot.panes(of: editors).map(\.id) == ["%0", "%1"])

        let window = try #require(snapshot.windows.first)
        #expect(snapshot.panes(of: window).map(\.id) == ["%0", "%1"])
        #expect(snapshot.session(of: window)?.id == "$0")
    }

    @Test("some matches when at least one relation does")
    func someMatchesWhenAtLeastOneDoes() throws {
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
        #expect(snapshot.sessions(.some, ofPanes: vimish).map(\.name) == ["editors", "mixed"])
    }

    @Test("every is vacuously true for an object with no relations")
    func everyIsVacuouslyTrueWhenThereAreNoRelations() throws {
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
        // `bare` has no panes, so every one of them matches — the same reading
        // `allSatisfy` has on an empty collection.
        #expect(snapshot.sessions(.every, ofPanes: vimish).map(\.name) == ["editors", "bare"])
    }

    @Test("none matches when no relation does, including having none")
    func noneMatchesWhenNoRelationDoes() throws {
        let shell = try FilterExpr<Pane>.where(\.currentCommand, .equals("zsh"))
        #expect(snapshot.sessions(.none, ofPanes: shell).map(\.name) == ["editors", "bare"])
    }

    @Test("the to-one direction takes a filter, not a quantifier")
    func toOneDirectionTakesAFilter() throws {
        let mixed = try FilterExpr<Session>.where(\.name, .equals("mixed"))
        #expect(snapshot.panes(inSession: mixed).map(\.id) == ["%2", "%3"])
        #expect(snapshot.windows(inSession: mixed).map(\.id) == ["@1"])
    }

    @Test("windows quantify over their own panes")
    func windowsQuantifyOverTheirPanes() throws {
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
        #expect(snapshot.windows(.every, ofPanes: vimish).map(\.id) == ["@0"])
        #expect(snapshot.windows(.some, ofPanes: vimish).map(\.id) == ["@0", "@1"])
    }

    @Test("a snapshot round-trips through JSON")
    func snapshotRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}

@Suite("snapshot capture")
struct SnapshotCaptureTests {
    @Test("a capture reports the server it came from, and its objects agree")
    func captureReportsItsServerAndAgrees() async throws {
        try await withTmuxServer { server in
            _ = try await server.run(TmuxCommand("split-window", ["-d", "-t", "bootstrap"]))
            let snapshot = try await server.snapshot()

            let processID = try await server.serverProcessID()
            #expect(snapshot.serverProcessID == processID)

            let session = try #require(snapshot.sessions.first)
            #expect(snapshot.windows(of: session).count == 1)
            #expect(snapshot.panes(of: session).count == 2)

            let window = try #require(snapshot.windows.first)
            #expect(snapshot.panes(of: window).count == window.paneCount)
        }
    }

    @Test("a restarted server yields a different identity, not a merged picture")
    func restartedServerYieldsADifferentIdentity() async throws {
        try await withTmuxServer { server in
            let first = try await server.snapshot()
            _ = try await server.run(TmuxCommand("kill-server"))
            _ = try await server.run(TmuxCommand("new-session", ["-d", "-s", "second"]))

            let second = try await server.snapshot()
            // The capture that spans a restart is what `snapshot()` rejects;
            // two whole captures either side of one legitimately differ.
            #expect(first.serverProcessID != second.serverProcessID)
            #expect(second.sessions.map(\.name) == ["second"])
        }
    }

    @Test("an absent server has no identity to capture")
    func absentServerHasNoIdentity() async throws {
        let server = try Server(
            socketPath: "/tmp/lt-none-\(UUID().uuidString.prefix(8))",
            tmuxExecutable: tmuxExecutablePath()
        )
        let processID = try await server.serverProcessID()
        #expect(processID == nil)
        await #expect(throws: TmuxError.serverRestarted) {
            try await server.snapshot()
        }
    }
}
