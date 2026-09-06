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
            isActive: id == "%1", isDead: dead, modeCount: mode,
            isSynchronized: synchronized, currentCommand: command,
            currentPath: "/tmp", windowID: window, incarnation: incarnation
        )
    }

    private var detachedCaller: CallerGuard {
        CallerGuard(identity: nil, isSameServer: false)
    }

    @Test("effective synchronization selects configured members and sorts once")
    func effectiveSynchronizationSelectsConfiguredMembers() throws {
        let sourceOff = pane("%2")
        let modalPeer = pane("%1", mode: 2, synchronized: true)
        #expect(
            try TmuxTools.resolvePaneInput(
                requested: sourceOff.id,
                panes: [modalPeer, sourceOff],
                scope: .configuredCohort,
                callerGuard: detachedCaller,
                force: false
            ).configuredPaneIDs == [sourceOff.id]
        )

        let sourceOn = pane("%2", synchronized: true)
        let peerOff = pane("%1")
        let peerOn = pane("%10", synchronized: true)
        let otherWindow = pane("%3", window: "@2", synchronized: true)
        #expect(
            try TmuxTools.resolvePaneInput(
                requested: sourceOn.id,
                panes: [sourceOn, peerOn, peerOff, peerOn, otherWindow],
                scope: .configuredCohort,
                callerGuard: detachedCaller,
                force: false
            ).configuredPaneIDs == [peerOn.id, sourceOn.id]
        )

        #expect(throws: ToolError.self) {
            try TmuxTools.resolvePaneInput(
                requested: sourceOn.id,
                panes: [sourceOn, pane("%1", mode: 2, synchronized: true)],
                scope: .configuredCohort,
                callerGuard: detachedCaller,
                force: true
            )
        }
    }

    @Test("only exact zero mode and live panes accept input")
    func onlyExactZeroModeAndLivePanesAcceptInput() {
        for mode in [1, 2, 1_000_000] {
            #expect(throws: ToolError.self) {
                try TmuxTools.resolvePaneInput(
                    requested: "%1", panes: [pane("%1", mode: mode)],
                    scope: .configuredCohort, callerGuard: detachedCaller, force: false
                )
            }
        }
        #expect(throws: ToolError.self) {
            try TmuxTools.resolvePaneInput(
                requested: "%1", panes: [pane("%1", dead: true)],
                scope: .configuredCohort, callerGuard: detachedCaller, force: true
            )
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
            try TmuxTools.resolvePaneInput(
                requested: "%1", panes: panes, scope: .configuredCohort,
                callerGuard: CallerGuard(identity: caller, isSameServer: true), force: false
            )
        }
        #expect(
            try TmuxTools.resolvePaneInput(
                requested: "%1", panes: panes, scope: .configuredCohort,
                callerGuard: CallerGuard(identity: caller, isSameServer: true), force: true
            ).configuredPaneIDs == ["%1", "%2"]
        )
    }

    @Test("target-only paste ignores synchronized peers")
    func targetOnlyPasteIgnoresSynchronizedPeers() throws {
        let source = pane("%1", synchronized: true)
        let peer = pane("%2", mode: 2, synchronized: true)
        #expect(
            try TmuxTools.resolvePaneInput(
                requested: source.id, panes: [source, peer], scope: .targetOnly,
                callerGuard: detachedCaller, force: false
            ).configuredPaneIDs == [source.id]
        )
    }

    @Test("runs require one configured pane in a supported POSIX shell")
    func runsRequireOneSupportedShell() throws {
        for shell in ["sh", "ash", "bash", "dash", "ksh", "mksh", "pdksh", "zsh", "-zsh"] {
            #expect(
                try TmuxTools.resolvePaneInput(
                    requested: "%1", panes: [pane("%1", command: shell)],
                    scope: .singularPOSIXShell, callerGuard: detachedCaller, force: false
                ).source.currentCommand == shell
            )
        }
        #expect(throws: ToolError.self) {
            try TmuxTools.resolvePaneInput(
                requested: "%1", panes: [pane("%1", command: "fish")],
                scope: .singularPOSIXShell, callerGuard: detachedCaller, force: false
            )
        }
        #expect(throws: ToolError.self) {
            try TmuxTools.resolvePaneInput(
                requested: "%1",
                panes: [pane("%1", synchronized: true), pane("%2", synchronized: true)],
                scope: .singularPOSIXShell, callerGuard: detachedCaller, force: false
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
