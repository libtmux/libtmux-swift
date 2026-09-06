import Testing

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("pane input preflight")
struct PaneInputGuardTests {
    private let incarnation = ServerIncarnation(
        endpoint: try! Endpoint(socketPath: "/tmp/libtmux-swift-test/input-preflight"),
        socketPath: "/tmp/libtmux-swift-test/input-preflight",
        processID: 42,
        startedAt: 7
    )

    private func pane(
        _ id: PaneID,
        window: WindowID = "@1",
        dead: Bool = false,
        mode: Int = 0,
        synchronized: Bool = false,
        command: String = "zsh"
    ) -> Pane {
        Pane(
            id: id, index: Int(id.rawValue.dropFirst()) ?? 0, width: 80, height: 24,
            isActive: id == "%1", isDead: dead, isInputOff: false, modeCount: mode,
            isSynchronized: synchronized, currentCommand: command,
            currentPath: "/tmp", windowID: window, incarnation: incarnation
        )
    }

    private func client(
        paneID: PaneID? = "%1",
        zoomed: Bool? = false,
        control: Bool = false,
        sessionID: SessionID = "$1"
    ) -> Client {
        Client(
            name: control ? "control" : "/dev/pts/7",
            tty: control ? "" : "/dev/pts/7",
            processID: 77,
            width: control ? nil : 80,
            height: control ? nil : 24,
            isControlMode: control,
            sessionID: sessionID,
            activePaneID: paneID,
            isWindowZoomed: zoomed,
            incarnation: incarnation
        )
    }

    private func snapshot(
        panes: [Pane],
        clients: [Client] = [],
        sessionIDs: [SessionID] = ["$1"],
        linkedWindows: Set<WindowID>? = nil
    ) -> Snapshot {
        let sessions = sessionIDs.map {
            Session(
                id: $0, name: $0.rawValue, windowCount: panes.count,
                isAttached: !clients.isEmpty, createdAt: 1, incarnation: incarnation
            )
        }
        let windows = linkedWindows ?? Set(panes.map(\.windowID))
        let links = sessionIDs.flatMap { sessionID in
            windows.enumerated().map { index, windowID in
                WindowLink(
                    sessionID: sessionID,
                    windowID: windowID,
                    index: index,
                    isActive: index == 0,
                    incarnation: incarnation
                )
            }
        }
        return Snapshot(
            incarnation: incarnation,
            sessions: sessions,
            windows: [],
            windowLinks: links,
            panes: panes,
            clients: clients
        )
    }

    private func resolve(
        _ requested: PaneID,
        panes: [Pane],
        clients: [Client] = [],
        sessionIDs: [SessionID] = ["$1"],
        linkedWindows: Set<WindowID>? = nil,
        scope: PaneInputScope = .configuredCohort,
        caller: CallerIdentity? = nil,
        sameServer: Bool = false,
        force: Bool = false
    ) throws -> PaneInputResolution {
        try TmuxTools.resolvePaneInput(
            requested: requested,
            snapshot: snapshot(
                panes: panes,
                clients: clients,
                sessionIDs: sessionIDs,
                linkedWindows: linkedWindows
            ),
            scope: scope,
            callerGuard: CallerGuard(identity: caller, isSameServer: sameServer),
            force: force
        )
    }

    @Test("caller environment distinguishes detached from malformed context")
    func callerEnvironmentDistinguishesDetachedFromMalformed() throws {
        #expect(CallerIdentity.current(environment: [:]) == nil)

        for environment in [
            ["TMUX": "/tmp/caller,42,1"],
            ["TMUX_PANE": "%1"],
            ["TMUX": "", "TMUX_PANE": ""],
            ["TMUX": "malformed", "TMUX_PANE": "%1"],
            ["TMUX": "/tmp/caller,42,1", "TMUX_PANE": "1"],
        ] {
            #expect(
                CallerIdentity.current(environment: environment) != nil,
                Comment(rawValue: "malformed caller was treated as detached: \(environment)")
            )
        }

        let identity = try #require(
            CallerIdentity.current(
                environment: [
                    "TMUX": "/tmp/caller,42,1",
                    "TMUX_PANE": "%7",
                ]
            )
        )
        #expect(identity.paneID == "%7")
        #expect(identity.sessionID == "$1")
        #expect(identity.socketPath == "/tmp/caller")
        #expect(identity.serverProcessID == 42)
    }

    @Test("caller context is complete and resolves in the selected snapshot")
    func callerContextResolvesInSelectedSnapshot() throws {
        let source = pane("%1")
        let malformed = [
            CallerIdentity(
                paneID: nil, sessionID: nil, socketPath: nil, serverProcessID: nil),
            CallerIdentity(
                paneID: "%1", sessionID: nil, socketPath: incarnation.socketPath,
                serverProcessID: incarnation.processID),
        ]
        for identity in malformed {
            #expect(throws: ToolError.self) {
                try resolve(source.id, panes: [source], caller: identity, force: true)
            }
        }

        let foreign = CallerIdentity(
            paneID: source.id,
            sessionID: "$99",
            socketPath: "/tmp/foreign",
            serverProcessID: 99
        )
        #expect(try resolve(source.id, panes: [source], caller: foreign).source.id == source.id)

        let sameDaemon = CallerIdentity(
            paneID: source.id,
            sessionID: "$1",
            socketPath: incarnation.socketPath,
            serverProcessID: incarnation.processID
        )
        #expect(throws: ToolError.self) {
            try resolve(
                source.id, panes: [source], sessionIDs: [], caller: sameDaemon,
                sameServer: true, force: true)
        }
        #expect(throws: ToolError.self) {
            try resolve(
                source.id, panes: [source], linkedWindows: [], caller: sameDaemon,
                sameServer: true, force: true)
        }
        #expect(throws: ToolError.self) {
            try resolve(source.id, panes: [source], caller: sameDaemon, sameServer: true)
        }
        #expect(
            try resolve(
                source.id, panes: [source], caller: sameDaemon,
                sameServer: true, force: true
            ).configuredPaneIDs == [source.id]
        )
    }

    @Test("terminal attention follows zoom and never yields to force")
    func terminalAttentionFollowsZoom() throws {
        let source = pane("%1", synchronized: true)
        let peer = pane("%2", synchronized: true)

        for requested in [source.id, peer.id] {
            #expect(throws: ToolError.self) {
                try resolve(
                    requested, panes: [source, peer], clients: [client(paneID: source.id)],
                    scope: .targetOnly, force: true)
            }
        }

        #expect(
            try resolve(
                peer.id, panes: [source, peer],
                clients: [client(paneID: source.id, zoomed: true)], scope: .targetOnly
            ).configuredPaneIDs == [peer.id]
        )
        #expect(throws: ToolError.self) {
            try resolve(
                source.id, panes: [source, peer],
                clients: [client(paneID: source.id, zoomed: true)], scope: .targetOnly)
        }
        #expect(
            try resolve(
                source.id, panes: [source, peer],
                clients: [client(paneID: source.id, control: true)], scope: .targetOnly
            ).configuredPaneIDs == [source.id]
        )

        for invalid in [client(paneID: nil), client(zoomed: nil)] {
            #expect(throws: ToolError.self) {
                try resolve(
                    source.id, panes: [source, peer], clients: [invalid],
                    scope: .targetOnly, force: true)
            }
        }

        #expect(throws: ToolError.self) {
            try resolve(
                source.id, panes: [source, peer],
                clients: [client(paneID: peer.id, zoomed: true)], force: true)
        }
    }

    @Test("effective synchronization selects configured members and sorts once")
    func effectiveSynchronizationSelectsConfiguredMembers() throws {
        let sourceOff = pane("%2")
        let modalPeer = pane("%1", mode: 2, synchronized: true)
        #expect(
            try resolve(sourceOff.id, panes: [modalPeer, sourceOff]).configuredPaneIDs
                == [sourceOff.id]
        )

        let sourceOn = pane("%2", synchronized: true)
        let peerOff = pane("%1")
        let peerOn = pane("%10", synchronized: true)
        let otherWindow = pane("%3", window: "@2", synchronized: true)
        #expect(
            try resolve(
                sourceOn.id,
                panes: [sourceOn, peerOn, peerOff, peerOn, otherWindow]
            ).configuredPaneIDs == [peerOn.id, sourceOn.id]
        )

        #expect(throws: ToolError.self) {
            try resolve(
                sourceOn.id,
                panes: [sourceOn, pane("%1", mode: 2, synchronized: true)],
                force: true)
        }
    }

    @Test("only exact zero mode and live panes accept input")
    func onlyExactZeroModeAndLivePanesAcceptInput() {
        for mode in [1, 2, 1_000_000] {
            #expect(throws: ToolError.self) {
                try resolve("%1", panes: [pane("%1", mode: mode)])
            }
        }
        #expect(throws: ToolError.self) {
            try resolve("%1", panes: [pane("%1", dead: true)], force: true)
        }
    }

    @Test("every configured member receives caller protection")
    func everyConfiguredMemberReceivesCallerProtection() throws {
        let caller = CallerIdentity(
            paneID: "%2", sessionID: "$1", socketPath: incarnation.socketPath,
            serverProcessID: incarnation.processID
        )
        let panes = [pane("%1", synchronized: true), pane("%2", synchronized: true)]
        #expect(throws: ToolError.self) {
            try resolve("%1", panes: panes, caller: caller, sameServer: true)
        }
        #expect(
            try resolve(
                "%1", panes: panes, caller: caller, sameServer: true, force: true
            ).configuredPaneIDs == ["%1", "%2"]
        )
    }

    @Test("target-only paste ignores synchronized peers")
    func targetOnlyPasteIgnoresSynchronizedPeers() throws {
        let source = pane("%1", synchronized: true)
        let peer = pane("%2", mode: 2, synchronized: true)
        #expect(
            try resolve(source.id, panes: [source, peer], scope: .targetOnly).configuredPaneIDs
                == [source.id]
        )
    }

    @Test("runs require one configured pane in a supported POSIX shell")
    func runsRequireOneSupportedShell() throws {
        for shell in ["sh", "ash", "bash", "dash", "ksh", "mksh", "pdksh", "zsh", "-zsh"] {
            #expect(
                try resolve(
                    "%1", panes: [pane("%1", command: shell)], scope: .singularPOSIXShell
                ).source.currentCommand == shell
            )
        }
        #expect(throws: ToolError.self) {
            try resolve("%1", panes: [pane("%1", command: "fish")], scope: .singularPOSIXShell)
        }
        #expect(throws: ToolError.self) {
            try resolve(
                "%1",
                panes: [pane("%1", synchronized: true), pane("%2", synchronized: true)],
                scope: .singularPOSIXShell
            )
        }
    }

    @Test("shell routes reject ASCII controls without rejecting quoted Unicode paths")
    func shellRouteValidation() throws {
        try TmuxTools.requireSafeShellRoute(
            executable: "/opt/tmux's/ømux",
            socketPath: "/tmp/libtmux-swift-test/socket's-雪"
        )
        for byte in Array(0...31) + [127] {
            let control = String(UnicodeScalar(byte)!)
            #expect(throws: ToolError.self) {
                try TmuxTools.requireSafeShellRoute(
                    executable: "/opt/tmux\(control)",
                    socketPath: "/tmp/libtmux-swift-test/socket"
                )
            }
            #expect(throws: ToolError.self) {
                try TmuxTools.requireSafeShellRoute(
                    executable: "/opt/tmux",
                    socketPath: "/tmp/libtmux-swift-test/socket\(control)"
                )
            }
        }
        #expect(throws: ToolError.self) {
            try TmuxTools.requireSafeShellRoute(
                executable: "tmux",
                socketPath: "/tmp/libtmux-swift-test/socket"
            )
        }
    }
}
