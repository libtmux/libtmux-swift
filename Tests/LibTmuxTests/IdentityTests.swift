import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("server identity", .timeLimit(.minutes(1)))
struct IdentityTests {
    @Test("typed ids reject malformed decoded values and stay compact")
    func typedIDsValidateTheirWireForm() throws {
        let session: SessionID = "$42"
        #expect(SessionID(rawValue: "$42") == session)
        #expect(SessionID(rawValue: "@42") == nil)
        let encoded = try JSONEncoder().encode(session)
        #expect(encoded == Data(#""$42""#.utf8))
        #expect(try JSONDecoder().decode(SessionID.self, from: encoded) == session)

        for raw in [#""@42""#, #""$""#, #""$-1""#, #""$01""#, #""$١""#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SessionID.self, from: Data(raw.utf8))
            }
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WindowID.self, from: Data(#""%7""#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PaneID.self, from: Data(#""@7""#.utf8))
        }
    }

    @Test("tmux format comparison operands escape parser punctuation")
    func tmuxFormatComparisonOperandsEscapeParserPunctuation() {
        #expect(
            tmuxFormatComparisonOperand("/tmp/a,b#c{d}:e}")
                == #"/tmp/a#,b##c{d#}:e#}"#
        )
    }

    @Test("listed values carry the daemon's resolved socket path")
    func listedValuesCarryResolvedSocketProvenance() async throws {
        try await withTmuxServer { server in
            let incarnation = try await server.incarnation()
            let socketPath = try #require(try await server.format("#{socket_path}"))
            #expect(incarnation.socketPath == socketPath)

            let session = try #require(try await server.sessions().first)
            let window = try #require(try await server.windows().first)
            let link = try #require(try await server.windowLinks().first)
            let pane = try #require(try await server.panes().first)
            #expect(
                [session.incarnation, window.incarnation, link.incarnation, pane.incarnation]
                    .allSatisfy { $0 == incarnation }
            )
        }
    }

    @Test("unlink removes the exact duplicate link")
    func unlinkRemovesTheExactDuplicateLink() async throws {
        try await withTmuxServer(socketFileName: "s,#{}:") { server in
            let session = try #require(try await server.sessions().first)
            let window = try #require(try await server.windows().first)
            let original = try #require(try await server.windowLinks().first)

            let duplicate = try await server.link(window, into: session)
            let linked = try await server.windowLinks().filter { $0.windowID == window.id }
            #expect(linked.count == 2)
            #expect(Set(linked.map(\.id)).count == 2)

            let data = try JSONEncoder().encode(linked)
            #expect(try JSONDecoder().decode([WindowLink].self, from: data) == linked)

            let transport = InvocationCountingTransport()
            let counted = Server(
                endpoint: server.endpoint,
                tmuxExecutable: server.tmuxExecutable,
                transport: transport
            )
            try await counted.unlink(duplicate)

            #expect(await transport.invocationCount == 1)
            let remaining = try await server.windowLinks().filter { $0.windowID == window.id }
            #expect(remaining.map(\.id) == [original.id])
        }
    }

    @Test("concurrent links each return the appearance they created")
    func concurrentLinksReturnTheirOwnAppearances() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let source = try #require(try await server.windows().first)
            let links = try await withThrowingTaskGroup(of: WindowLink.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await server.link(source, into: session) }
                }
                var links: [WindowLink] = []
                for try await link in group { links.append(link) }
                return links
            }

            #expect(Set(links.map(\.id)).count == links.count)
            let listed = Set(try await server.windowLinks().map(\.id))
            #expect(links.allSatisfy { listed.contains($0.id) })
        }
    }

    @Test("window creation returns its exact appearance in one invocation")
    func windowCreationReturnsItsExactAppearanceAtomically() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let transport = InvocationCountingTransport()
            let counted = Server(
                endpoint: server.endpoint,
                tmuxExecutable: server.tmuxExecutable,
                transport: transport
            )

            let created: WindowAppearance = try await counted.newWindow(
                in: session,
                named: "atomic"
            )

            #expect(await transport.invocationCount == 1)
            #expect(created.window.name == "atomic")
            #expect(created.link.sessionID == session.id)
            #expect(created.link.windowID == created.window.id)
            let listed = try #require(
                try await server.windowLinks().first { $0.windowID == created.window.id }
            )
            #expect(created.link.id == listed.id)
        }
    }

    @Test("breaking a pane returns its exact appearance in one invocation")
    func breakPaneReturnsItsExactAppearanceAtomically() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let sourceWindow = try #require(try await server.windows().first)
            let sourceLink = try #require(try await server.windowLinks().first)
            let pane = try await server.splitWindow(sourceWindow)
            let transport = InvocationCountingTransport()
            let counted = Server(
                endpoint: server.endpoint,
                tmuxExecutable: server.tmuxExecutable,
                transport: transport
            )

            let created: WindowAppearance = try await counted.breakPane(
                pane,
                from: sourceLink
            )

            #expect(await transport.invocationCount == 1)
            #expect(created.link.sessionID == session.id)
            #expect(created.link.windowID == created.window.id)
            let listed = try #require(
                try await server.windowLinks().first { $0.windowID == created.window.id }
            )
            #expect(created.link.id == listed.id)
        }
    }

    @Test("linking needs a global window, not one of its existing links")
    func linkingUsesTheGlobalWindow() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            let destination = try await server.newSession(named: "link-global")

            let linked = try await server.link(window, into: destination)

            #expect(linked.windowID == window.id)
            #expect(linked.sessionID == destination.id)
        }
    }

    @Test("a mismatched resolved socket path cannot authorize unlink")
    func mismatchedSocketPathCannotAuthorizeUnlink() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let source = try #require(try await server.windows().first)
            let duplicate = try await server.link(source, into: session)
            let incarnation = duplicate.incarnation
            let forged = WindowLink(
                sessionID: duplicate.sessionID,
                windowID: duplicate.windowID,
                index: duplicate.index,
                isActive: duplicate.isActive,
                incarnation: ServerIncarnation(
                    endpoint: incarnation.endpoint,
                    socketPath: incarnation.socketPath + ",:wrong",
                    processID: incarnation.processID,
                    startedAt: incarnation.startedAt
                )
            )

            await #expect(throws: TmuxError.serverRestarted) {
                try await server.unlink(forged)
            }
            #expect(try await server.windowLinks().contains { $0.id == duplicate.id })
        }
    }

    @Test("connected unlink fences its rejected branch reply")
    func connectedUnlinkDrainsRejectionReply() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let first = try #require(try await server.windows().first)
            let second = try await server.newWindow(in: session).window
            let links = try await server.windowLinks()
            let firstLink = try #require(links.first { $0.windowID == first.id })
            let stale = try #require(
                links.first { $0.windowID == second.id }
            )
            try await server.swap(firstLink, with: stale)

            try await server.connected(attachingTo: session.id.rawValue) { connected, _ in
                await #expect(throws: TmuxError.staleServerValue) {
                    try await connected.unlink(stale)
                }
                let reply = try await connected.run(
                    TmuxCommand("display-message", ["-p", "next-reply"])
                )
                #expect(reply.isSuccess, Comment(rawValue: reply.errorText))
                #expect(reply.text == "next-reply\n")
            }
            #expect(try await server.windows().count == 2)
        }
    }

    @Test("connected unlink drains a nested mutation error")
    func connectedUnlinkDrainsNestedMutationError() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let onlyLink = try #require(try await server.windowLinks().first)

            try await server.connected(attachingTo: session.id.rawValue) { connected, _ in
                await #expect(
                    throws: TmuxError.invocationFailed(
                        reason: "window only linked to one session"
                    )
                ) {
                    try await connected.unlink(onlyLink)
                }
                let next = try await connected.run(
                    TmuxCommand("display-message", ["-p", "after-error"])
                )
                #expect(next.isSuccess, Comment(rawValue: next.errorText))
                #expect(next.text == "after-error\n")
            }
        }
    }

    @Test("direct guard markers do not trigger display hooks")
    func directGuardMarkersDoNotTriggerDisplayHooks() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let source = try #require(try await server.windows().first)
            let duplicate = try await server.link(source, into: session)
            let set = try await server.setHook(
                "after-display-message",
                to: "set-option -g @libtmux-marker-hook fired"
            )
            #expect(set.isSuccess, Comment(rawValue: set.errorText))

            try await server.unlink(duplicate)
            #expect(try await server.windowLinks().allSatisfy { $0.id != duplicate.id })
            #expect(try await server.option("@libtmux-marker-hook", scope: .server) == nil)
        }
    }

    @Test("connected guard ignores hook blocks while fencing")
    func connectedGuardIgnoresHookBlocks() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let link = try #require(
                try await server.windowLinks().first { $0.sessionID == session.id }
            )
            let suffix = UUID().uuidString
            let started = "guard-hook-started-\(suffix)"
            let release = "guard-hook-release-\(suffix)"
            let set = try await server.setHook(
                "after-display-message",
                to: "wait-for -S \(started) ; wait-for \(release) ; "
                    + "display-message -p hostile-hook-output"
            )
            #expect(set.isSuccess, Comment(rawValue: set.errorText))

            try await server.connected(attachingTo: session.id.rawValue) { connected, _ in
                let format = Task {
                    try await connected.format("#{window_id}", for: link)
                }
                _ = try await server.run(TmuxCommand("wait-for", [started]))
                let next = Task {
                    try await connected.run(
                        TmuxCommand("display-message", ["-p", "next-reply"])
                    )
                }
                _ = try await server.run(TmuxCommand("wait-for", ["-S", release]))

                #expect(try await format.value == link.windowID.rawValue)
                let reply = try await next.value
                #expect(reply.isSuccess, Comment(rawValue: reply.errorText))
                #expect(reply.text == "next-reply\n")
            }
        }
    }

    @Test("a foreign value is rejected before mutation")
    func foreignValueIsRejectedBeforeMutation() async throws {
        try await withTmuxServer { source in
            let link = try #require(try await source.windowLinks().first)
            try await withTmuxServer { destination in
                let before = try await destination.windowLinks()
                await #expect(throws: TmuxError.foreignServerValue) {
                    try await destination.unlink(link)
                }
                #expect(try await destination.windowLinks() == before)
            }
        }
    }

    @Test("a stale daemon value cannot target its replacement")
    func staleValueCannotTargetReplacement() async throws {
        try await withTmuxServer { server in
            let stale = try #require(try await server.windowLinks().first)
            _ = try await server.run(TmuxCommand("kill-server"))
            let replaced = try await waitUntil {
                if try await server.hasSession("replacement") { return true }
                return try await server.run(
                    TmuxCommand("new-session", ["-d", "-s", "replacement"])
                ).isSuccess
            }
            #expect(replaced)

            await #expect(throws: TmuxError.serverRestarted) {
                try await server.unlink(stale)
            }
            #expect(try await server.sessions().map(\.name) == ["replacement"])
        }
    }

}

private actor InvocationCountingTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private(set) var invocationCount = 0

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        invocationCount += 1
        return try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
    }
}
