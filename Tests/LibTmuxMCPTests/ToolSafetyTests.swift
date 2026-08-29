import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("tool safety", .timeLimit(.minutes(1)))
struct ToolSafetyTests {
    @Test("caller identity discards a malformed pane id from the environment")
    func callerIdentityDiscardsAMalformedPaneID() throws {
        let identity = try #require(
            CallerIdentity.current(
                environment: ["TMUX": "/tmp/s,1,2", "TMUX_PANE": "%03"]
            )
        )
        #expect(identity.paneID == nil)
        #expect(identity.sessionID == "$2")
    }

    @Test(
        "caller identity decoding refuses malformed ids",
        arguments: [("%01", "$2"), ("%2", "$02")]
    )
    func callerIdentityDecodingRefusesMalformedIDs(
        _ paneID: String,
        _ sessionID: String
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "paneID": paneID,
            "sessionID": sessionID,
            "socketPath": NSNull(),
            "serverProcessID": 1,
        ])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CallerIdentity.self, from: data)
        }
    }

    @Test("default tool listings are readonly")
    func defaultToolListingsAreReadonly() throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-default-listing"
        )
        let visible = TmuxTools(server: server).visibleDefinitions

        #expect(visible.contains { $0.name == "list_panes" })
        #expect(visible.allSatisfy { $0.tier == .readonly })
    }

    @Test("default tools refuse mutating calls")
    func defaultToolsRefuseMutatingCalls() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-default-call"
        )

        await #expect(
            throws: ToolError.deniedByTier(
                "send_keys",
                needs: .mutating,
                allowed: .readonly
            )
        ) {
            try await TmuxTools(server: server).call(ToolCall(name: "send_keys"))
        }
    }

    @Test("an exact tool selection governs listings and calls")
    func exactToolSelectionIsShared() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-exact-tools"
        )
        let tools = TmuxTools(
            server: server,
            authority: ToolAuthority(
                tier: .mutating,
                enabledTools: [.newWindow]
            )
        )

        #expect(Set(tools.visibleDefinitions.map(\.name)) == ["new_window"])
        for name in ["run_shell", "send_keys"] {
            await #expect(throws: ToolError.notEnabled(name)) {
                try await tools.call(ToolCall(name: name))
            }
        }
    }

    @Test("the safety tier caps an exact tool selection")
    func tierCapsExactToolSelection() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-capped-tools"
        )
        let tools = TmuxTools(
            server: server,
            authority: ToolAuthority(
                tier: .readonly,
                enabledTools: [.newWindow]
            )
        )

        #expect(tools.visibleDefinitions.isEmpty)
        await #expect(
            throws: ToolError.deniedByTier(
                "new_window",
                needs: .mutating,
                allowed: .readonly
            )
        ) {
            try await tools.call(ToolCall(name: "new_window"))
        }
    }

    @Test("a tool above the tier is hidden as well as refused")
    func toolsAboveTheTierAreHidden() async throws {
        try await withTmuxServer { server in
            let readers = TmuxTools(server: server, tier: .readonly)
            let visible = Set(readers.visibleDefinitions.map(\.name))
            #expect(visible.contains("list_panes"))
            #expect(!visible.contains("send_keys"))
            #expect(!visible.contains("kill_pane"))

            // Hidden and refused, not one or the other: a client that kept an
            // old listing must not get through on it.
            await #expect(throws: ToolError.self) {
                try await readers.call(
                    ToolCall(
                        name: "kill_pane",
                        arguments: .object(["pane": .string("%0")])
                    )
                )
            }
        }
    }

    @Test("killing is available when the tier allows it")
    func killingIsAvailableAtTheDestructiveTier() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .destructive, caller: nil)
            let pane = try await server.split(
                try #require(try await server.panes().first)
            )
            _ = try await tools.call(
                ToolCall(name: "kill_pane", arguments: .object(["pane": .string(wireRef(pane))]))
            )
            #expect(try await server.panes().allSatisfy { $0.id != pane.id })
        }
    }

    @Test("the pane this server runs in is refused unless it is confirmed")
    func ownPaneIsRefusedWithoutConfirmation() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let session = try #require(try await server.sessions().first)
            // Standing in for running inside this very pane, which a test
            // process is not.
            let identity = CallerIdentity(
                paneID: pane.id,
                sessionID: session.id,
                socketPath: nil,
                serverProcessID: try await server.serverProcessID()
            )
            let tools = TmuxTools(server: server, tier: .destructive, caller: identity)

            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "respawn_pane",
                        arguments: .object(["pane": .string(wireRef(pane))])
                    )
                )
            }
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "kill_pane",
                        arguments: .object(["pane": .string(wireRef(pane))])
                    )
                )
            }
            // Still reachable on purpose: the guard exists to stop an accident,
            // not to remove a capability.
            _ = try await tools.call(
                ToolCall(
                    name: "kill_pane",
                    arguments: .object([
                        "pane": .string(wireRef(pane)), "confirm_self": .bool(true),
                    ])
                )
            )
        }
    }

    @Test("a failed caller identity probe cannot bypass the guard")
    func callerProbeFailureIsNotIgnored() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let session = try #require(try await fixture.sessions().first)
            let identity = CallerIdentity(
                paneID: pane.id,
                sessionID: session.id,
                socketPath: nil,
                serverProcessID: try await fixture.serverProcessID()
            )
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: FailingCallerProbeTransport()
            )
            let tools = TmuxTools(server: server, tier: .destructive, caller: identity)

            await #expect(throws: ToolError.tmux(.invocationFailed(reason: "probe failed"))) {
                try await tools.call(
                    ToolCall(
                        name: "kill_pane",
                        arguments: .object(["pane": .string(wireRef(pane))])
                    )
                )
            }
            #expect(try await fixture.panes().contains { $0.id == pane.id })
        }
    }

    @Test("killing what holds the caller's pane is refused too")
    func killingTheEnclosingWindowIsRefused() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let session = try #require(try await server.sessions().first)
            let window = try #require(
                try await server.windows().first { $0.id == pane.windowID }
            )
            let identity = CallerIdentity(
                paneID: pane.id,
                sessionID: session.id,
                socketPath: nil,
                serverProcessID: try await server.serverProcessID()
            )
            let tools = TmuxTools(server: server, tier: .destructive, caller: identity)
            // The pane is not the target here — its window and its session are.
            // Guarding only the pane would leave two other ways to end the same
            // conversation by accident.
            for (tool, target) in [
                ("kill_window", wireRef(window)), ("kill_session", wireRef(session)),
            ] {
                await #expect(throws: ToolError.self, "\(tool) killed the caller") {
                    try await tools.call(
                        ToolCall(
                            name: tool,
                            arguments: .object(["target": .string(target)])
                        )
                    )
                }
            }
            // Both still reachable when meant, which is what keeps the guard a
            // guard rather than a removed capability.
            _ = try await tools.call(
                ToolCall(
                    name: "kill_window",
                    arguments: .object([
                        "target": .string(wireRef(window)),
                        "confirm_self": .bool(true),
                    ])
                )
            )
        }
    }

    @Test("a moved caller window is protected in its current session")
    func movedCallerWindowIsProtectedInItsCurrentSession() async throws {
        try await withTmuxServer { server in
            let originalSession = try #require(try await server.sessions().first)
            let pane = try #require(try await server.panes().first)
            let source = try #require(
                try await server.windowLinks().first { $0.windowID == pane.windowID }
            )
            _ = try await server.newWindow(in: originalSession, named: "kept")
            let destination = try await server.newSession(named: "moved-caller")
            _ = try await server.move(source, to: destination)
            let identity = CallerIdentity(
                paneID: pane.id,
                sessionID: originalSession.id,
                socketPath: nil,
                serverProcessID: try await server.serverProcessID()
            )
            let tools = TmuxTools(server: server, tier: .destructive, caller: identity)

            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "kill_session",
                        arguments: .object(["target": .string(wireRef(destination))])
                    )
                )
            }
            #expect(try await server.sessions().contains { $0.id == destination.id })
        }
    }

    @Test("container kills on the caller server require confirmation before a move race")
    func containerKillsRequireConfirmationBeforeMoveRace() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let callerSession = try #require(try await server.sessions().first)
            let destination = try await server.newSession(named: "other-container")
            let window = try #require(try await server.snapshot().windows(of: destination).first)
            let identity = CallerIdentity(
                paneID: pane.id,
                sessionID: callerSession.id,
                socketPath: nil,
                serverProcessID: try await server.serverProcessID()
            )
            let tools = TmuxTools(server: server, tier: .destructive, caller: identity)

            for (tool, target) in [
                ("kill_window", wireRef(window)), ("kill_session", wireRef(destination)),
            ] {
                await #expect(throws: ToolError.self) {
                    try await tools.call(
                        ToolCall(
                            name: tool,
                            arguments: .object(["target": .string(target)])
                        )
                    )
                }
            }
            _ = try await tools.call(
                ToolCall(
                    name: "kill_session",
                    arguments: .object([
                        "target": .string(wireRef(destination)),
                        "confirm_self": .bool(true),
                    ])
                )
            )
        }
    }

    @Test("a caller on another server is not mistaken for this one")
    func aCallerElsewhereIsNotGuardedAgainst() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let session = try #require(try await server.sessions().first)
            let elsewhere = CallerIdentity(
                paneID: pane.id,
                sessionID: session.id,
                socketPath: nil,
                // Same pane id, different daemon: ids are only unique per
                // server, so guarding on the id alone would refuse work on
                // every other tmux on the machine.
                serverProcessID: -1
            )
            let tools = TmuxTools(server: server, tier: .destructive, caller: elsewhere)
            _ = try await tools.call(
                ToolCall(name: "kill_pane", arguments: .object(["pane": .string(wireRef(pane))]))
            )
        }
    }

    @Test("commands that would never return are refused by name")
    func blockingCommandsAreRefused() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .destructive)
            let reference = try await serverRef(server)
            for command in ["wait-for", "attach-session", "command-prompt"] {
                await #expect(throws: ToolError.self) {
                    try await tools.call(
                        ToolCall(
                            name: "run_command",
                            arguments: .object([
                                "server_ref": .string(reference), "command": .string(command),
                                "confirm_unsafe": .bool(true),
                            ])
                        )
                    )
                }
            }
        }
    }
}

private actor FailingCallerProbeTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private var failed = false

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if !failed, arguments.contains("display-message") {
            failed = true
            throw .invocationFailed(reason: "probe failed")
        }
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }
    @Test("a readonly format tool refuses to run a shell command")
    func readonlyFormatToolsRefuseShellJobs() throws {
        // tmux runs `#(...)` in any format it expands, so a template arriving
        // from a client would reach a shell from a tier that promises reads.
        for template in ["#(id)", "###(id)", "pre#(id)post"] {
            #expect(throws: ToolError.self) {
                try ToolPattern.checkedFormat(template, argument: "template")
            }
        }
        for template in ["#{pane_dead}", "##(id)", "#{?#{a},x,y}"] {
            #expect(try ToolPattern.checkedFormat(template, argument: "template") == template)
        }
    }

}
