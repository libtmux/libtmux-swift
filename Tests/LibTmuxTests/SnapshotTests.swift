import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

private let fixtureIncarnation = ServerIncarnation(
    endpoint: .socketPath("/tmp/libtmux-swift-test/value-fixture"),
    socketPath: "/tmp/libtmux-swift-test/value-fixture",
    processID: 4242,
    startedAt: 1
)

private func session(
    _ id: SessionID,
    _ name: String,
    incarnation: ServerIncarnation = fixtureIncarnation
) -> Session {
    Session(
        id: id,
        name: name,
        windowCount: 1,
        isAttached: false,
        createdAt: 0,
        incarnation: incarnation
    )
}

private func window(
    _ id: WindowID,
    name: String = "w",
    incarnation: ServerIncarnation = fixtureIncarnation
) -> Window {
    Window(
        id: id,
        name: name,
        paneCount: 1,
        width: 80,
        height: 24,
        incarnation: incarnation
    )
}

private func link(
    _ window: WindowID,
    session: SessionID,
    index: Int = 0,
    incarnation: ServerIncarnation = fixtureIncarnation
) -> WindowLink {
    WindowLink(
        sessionID: session,
        windowID: window,
        index: index,
        isActive: true,
        incarnation: incarnation
    )
}

private func pane(
    _ id: PaneID,
    window: WindowID,
    command: String,
    incarnation: ServerIncarnation = fixtureIncarnation
) -> Pane {
    Pane(
        id: id, index: 0, width: 80, height: 24, isActive: true,
        currentCommand: command,
        currentPath: "/",
        windowID: window,
        incarnation: incarnation
    )
}

/// Two sessions: `$0` runs editors throughout, `$1` runs a shell alongside one.
/// `$2` has no panes at all, which is what makes `.every` and `.none` differ.
private let snapshot = Snapshot(
    incarnation: fixtureIncarnation,
    sessions: [session("$0", "editors"), session("$1", "mixed"), session("$2", "bare")],
    windows: [
        window("@0"),
        window("@1"),
    ],
    windowLinks: [link("@0", session: "$0"), link("@1", session: "$1")],
    panes: [
        pane("%0", window: "@0", command: "nvim"),
        pane("%1", window: "@0", command: "vim"),
        pane("%2", window: "@1", command: "nvim"),
        pane("%3", window: "@1", command: "zsh"),
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
        #expect(snapshot.sessions(of: window).map(\.id) == ["$0"])
    }

    @Test("linked window panes belong to every linking session")
    func linkedWindowPanesBelongToEveryLinkingSession() throws {
        let linked = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "source"), session("$1", "destination")],
            windows: [window("@0")],
            windowLinks: [link("@0", session: "$0"), link("@0", session: "$1")],
            panes: [pane("%0", window: "@0", command: "nvim")],
            clients: []
        )

        #expect(linked.panes(of: linked.sessions[0]).map(\.id) == ["%0"])
        #expect(linked.panes(of: linked.sessions[1]).map(\.id) == ["%0"])

        let destination = try FilterExpr<Session>.where(
            \.name,
            .equals("destination")
        )
        #expect(try linked.panes(inSession: destination).map(\.id) == ["%0"])
    }

    @Test("session panes follow that session's window order")
    func sessionPanesFollowItsWindowOrder() {
        let ordered = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "ordered"), session("$1", "other")],
            windows: [window("@1"), window("@0")],
            windowLinks: [
                link("@0", session: "$0", index: 1),
                link("@1", session: "$0", index: 5),
                link("@1", session: "$1", index: 0),
            ],
            panes: [
                pane("%1", window: "@1", command: "later"),
                pane("%0", window: "@0", command: "first"),
            ],
            clients: []
        )

        #expect(ordered.panes(of: ordered.sessions[0]).map(\.id) == ["%0", "%1"])
    }

    @Test("session windows preserve first-link order without duplicates")
    func sessionWindowsPreserveFirstLinkOrderWithoutDuplicates() {
        let linked = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "linked")],
            windows: [window("@0"), window("@1")],
            windowLinks: [
                link("@1", session: "$0", index: 1),
                link("@0", session: "$0", index: 2),
                link("@1", session: "$0", index: 3),
            ],
            panes: [],
            clients: []
        )

        #expect(linked.windows(of: linked.sessions[0]).map(\.id) == ["@1", "@0"])
    }

    @Test("foreign models do not resolve against reused ids")
    func foreignModelsDoNotResolveAgainstReusedIDs() {
        let foreignIncarnation = ServerIncarnation(
            endpoint: .socketPath("/tmp/libtmux-swift-test/foreign-value-fixture"),
            socketPath: "/tmp/libtmux-swift-test/foreign-value-fixture",
            processID: 5252,
            startedAt: 2
        )
        let foreignSession = session("$0", "foreign", incarnation: foreignIncarnation)
        let foreignWindow = window("@0", incarnation: foreignIncarnation)
        let foreignClient = Client(
            name: "foreign-client",
            tty: "",
            processID: 6262,
            width: nil,
            height: nil,
            isControlMode: true,
            sessionID: "$0",
            incarnation: foreignIncarnation
        )

        #expect(snapshot.windows(of: foreignSession).isEmpty)
        #expect(snapshot.windowLinks(of: foreignSession).isEmpty)
        #expect(snapshot.panes(of: foreignSession).isEmpty)
        #expect(snapshot.links(of: foreignWindow).isEmpty)
        #expect(snapshot.panes(of: foreignWindow).isEmpty)
        #expect(snapshot.sessions(of: foreignWindow).isEmpty)
        #expect(snapshot.session(of: foreignClient) == nil)
    }

    @Test("foreign snapshot members never join through reused ids")
    func foreignMembersDoNotJoinThroughReusedIDs() throws {
        let foreignIncarnation = ServerIncarnation(
            endpoint: .socketPath("/tmp/libtmux-swift-test/foreign-member-fixture"),
            socketPath: "/tmp/libtmux-swift-test/foreign-member-fixture",
            processID: 7272,
            startedAt: 3
        )
        let mixed = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: snapshot.sessions + [
                session("$0", "foreign", incarnation: foreignIncarnation)
            ],
            windows: snapshot.windows + [
                window("@0", name: "foreign", incarnation: foreignIncarnation)
            ],
            windowLinks: snapshot.windowLinks + [
                link("@0", session: "$0", incarnation: foreignIncarnation)
            ],
            panes: snapshot.panes + [
                pane(
                    "%9",
                    window: "@0",
                    command: "foreign",
                    incarnation: foreignIncarnation
                )
            ],
            clients: []
        )

        let missingCommand = try FilterExpr<Pane>.where(
            \.currentCommand,
            .equals("missing")
        )
        #expect(try mixed.sessions(.none, ofPanes: missingCommand).count == 3)
        #expect(try mixed.windows(.none, ofPanes: missingCommand).count == 2)

        let localWindows = try FilterExpr<Window>.where(\.name, .equals("w"))
        #expect(try mixed.panes(inWindow: localWindows).count == 4)

        let editors = try FilterExpr<Session>.where(\.name, .equals("editors"))
        #expect(try mixed.panes(inSession: editors).map(\.id) == ["%0", "%1"])
        #expect(try mixed.windows(inSession: editors).map(\.id) == ["@0"])
    }

    @Test("some matches when at least one relation does")
    func someMatchesWhenAtLeastOneDoes() throws {
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
        #expect(
            try snapshot.sessions(.some, ofPanes: vimish).map(\.name)
                == ["editors", "mixed"]
        )
    }

    @Test("every is vacuously true for an object with no relations")
    func everyIsVacuouslyTrueWhenThereAreNoRelations() throws {
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
        // `bare` has no panes, so every one of them matches — the same reading
        // `allSatisfy` has on an empty collection.
        #expect(
            try snapshot.sessions(.every, ofPanes: vimish).map(\.name)
                == ["editors", "bare"]
        )
    }

    @Test("none matches when no relation does, including having none")
    func noneMatchesWhenNoRelationDoes() throws {
        let shell = try FilterExpr<Pane>.where(\.currentCommand, .equals("zsh"))
        #expect(
            try snapshot.sessions(.none, ofPanes: shell).map(\.name)
                == ["editors", "bare"]
        )
    }

    @Test("the to-one direction takes a filter, not a quantifier")
    func toOneDirectionTakesAFilter() throws {
        let mixed = try FilterExpr<Session>.where(\.name, .equals("mixed"))
        #expect(try snapshot.panes(inSession: mixed).map(\.id) == ["%2", "%3"])
        #expect(try snapshot.windows(inSession: mixed).map(\.id) == ["@1"])
    }

    @Test("windows quantify over their own panes")
    func windowsQuantifyOverTheirPanes() throws {
        let vimish = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["nvim", "vim"]))
        #expect(try snapshot.windows(.every, ofPanes: vimish).map(\.id) == ["@0"])
        #expect(try snapshot.windows(.some, ofPanes: vimish).map(\.id) == ["@0", "@1"])
    }

    @Test("some stops after its first related match")
    func someStopsAfterItsFirstRelatedMatch() throws {
        let related = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "owner")],
            windows: [window("@0")],
            windowLinks: [link("@0", session: "$0")],
            panes: [
                pane("%0", window: "@0", command: "z"),
                pane("%1", window: "@0", command: "aaaa"),
            ],
            clients: []
        )
        let pattern = try RegexPattern("z$")
        let expression = try FilterExpr<Pane>.where(\.currentCommand, .matches(pattern))
        #expect(try !pattern.containsMatch(in: "aaaa", maximumWork: 20))

        let matches = try related.sessions(
            .some,
            ofPanes: expression,
            regexBudget: try RegexMatchBudget(maximum: 20)
        )

        #expect(matches.map(\.id) == ["$0"])
    }

    @Test("every stops after its first related mismatch")
    func everyStopsAfterItsFirstRelatedMismatch() throws {
        let related = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "owner")],
            windows: [window("@0", name: "aaaa"), window("@1", name: "aaaa")],
            windowLinks: [link("@0", session: "$0"), link("@1", session: "$0")],
            panes: [],
            clients: []
        )
        let pattern = try RegexPattern("z$")
        let expression = try FilterExpr<Window>.where(\.name, .matches(pattern))
        #expect(try !pattern.containsMatch(in: "aaaa", maximumWork: 20))

        let matches = try related.sessions(
            .every,
            ofWindows: expression,
            regexBudget: try RegexMatchBudget(maximum: 20)
        )

        #expect(matches.isEmpty)
    }

    @Test("none stops after its first related match")
    func noneStopsAfterItsFirstRelatedMatch() throws {
        let related = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "owner")],
            windows: [window("@0")],
            windowLinks: [link("@0", session: "$0")],
            panes: [
                pane("%0", window: "@0", command: "z"),
                pane("%1", window: "@0", command: "aaaa"),
            ],
            clients: []
        )
        let pattern = try RegexPattern("z$")
        let expression = try FilterExpr<Pane>.where(\.currentCommand, .matches(pattern))
        #expect(try !pattern.containsMatch(in: "aaaa", maximumWork: 20))

        let matches = try related.windows(
            .none,
            ofPanes: expression,
            regexBudget: try RegexMatchBudget(maximum: 20)
        )

        #expect(matches.isEmpty)
    }

    @Test("relation matching shares work across owners")
    func relationMatchingSharesWorkAcrossOwners() throws {
        let related = Snapshot(
            incarnation: fixtureIncarnation,
            sessions: [session("$0", "first"), session("$1", "second")],
            windows: [window("@0"), window("@1")],
            windowLinks: [link("@0", session: "$0"), link("@1", session: "$1")],
            panes: [
                pane("%0", window: "@0", command: "aaaa"),
                pane("%1", window: "@1", command: "aaaa"),
            ],
            clients: []
        )
        let expression = try FilterExpr<Pane>.where(
            \.currentCommand,
            .matches(try RegexPattern("z$"))
        )

        #expect(throws: RegexMatchError.workLimitExceeded(maximum: 20)) {
            try related.sessions(
                .some,
                ofPanes: expression,
                regexBudget: try RegexMatchBudget(maximum: 20)
            )
        }
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

    @Test("a snapshot rejects a replacement that reuses the daemon pid")
    func snapshotRejectsAReplacementThatReusesTheDaemonPID() async throws {
        let endpoint = try Endpoint(socketName: "snapshot-replacement")
        let transport = SnapshotReplacementTransport()
        let server = Server(endpoint: endpoint, transport: transport)

        await #expect(throws: TmuxError.serverRestarted) {
            try await server.snapshot()
        }
        #expect(await transport.incarnationProbeCount == 2)
    }

    @Test("an absent server cannot answer an identity read")
    func absentServerCannotAnswerIdentityRead() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/none-\(UUID().uuidString.prefix(8))",
            tmuxExecutable: tmuxExecutablePath()
        )
        await #expect(throws: TmuxError.self) {
            _ = try await server.serverProcessID()
        }
        await #expect(throws: TmuxError.self) {
            try await server.snapshot()
        }
    }
}

private actor SnapshotReplacementTransport: ProcessTransport {
    private(set) var incarnationProbeCount = 0

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        guard
            let command = arguments.first(where: {
                [
                    "display-message", "list-sessions", "list-windows", "list-panes",
                    "list-clients",
                ].contains($0)
            })
        else {
            throw .invocationFailed(reason: "unexpected snapshot command")
        }

        if command == "list-clients" {
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        }

        var values = [
            "socket_path": "/tmp/libtmux-swift-test/snapshot-replacement/first/socket",
            "pid": "700", "start_time": "900",
            "session_id": "$0", "session_name": "held", "session_windows": "1",
            "session_attached": "0", "session_created": "100",
            "window_id": "@0", "window_name": "held", "window_index": "0",
            "window_panes": "1", "window_active": "1", "window_width": "80",
            "window_height": "24",
            "pane_id": "%0", "pane_index": "0", "pane_width": "80",
            "pane_height": "24", "pane_active": "1", "pane_current_command": "sh",
            "pane_current_path": "/tmp", "pane_at_top": "1", "pane_at_bottom": "1",
            "pane_at_left": "1", "pane_at_right": "1",
        ]
        if command == "display-message" {
            incarnationProbeCount += 1
            if incarnationProbeCount == 2 {
                values["socket_path"] =
                    "/tmp/libtmux-swift-test/snapshot-replacement/second/socket"
                values["start_time"] = "901"
            }
        }
        return try Self.projectedReply(to: arguments, values: values)
    }

    private static func projectedReply(
        to arguments: [String],
        values: [String: String]
    ) throws(TmuxError) -> TmuxReply {
        guard
            let flag = arguments.firstIndex(where: { $0 == "-F" || $0 == "-p" }),
            arguments.indices.contains(flag + 1)
        else {
            throw .invocationFailed(reason: "missing snapshot format")
        }
        let rendered = values.reduce(arguments[flag + 1]) { output, field in
            output.replacingOccurrences(of: "#{\(field.key)}", with: field.value)
        }
        guard !rendered.contains("#{") else {
            throw .invocationFailed(reason: "unknown snapshot format field")
        }
        return TmuxReply(
            standardOutput: Array("\(rendered)\n".utf8),
            standardError: [],
            exitCode: 0
        )
    }
}
