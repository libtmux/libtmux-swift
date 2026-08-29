import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("the tools added for reach", .timeLimit(.minutes(2)))
struct ReachToolTests {
    @Test("what set_option wrote, show_options reads back")
    func optionsRoundTrip() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            _ = try await tools.call(
                ToolCall(
                    name: "set_option",
                    arguments: .object([
                        "name": .string("@round-trip"), "value": .string("yes"),
                        "scope": .string("server"),
                    ])
                )
            )
            let outcome = try await tools.call(
                ToolCall(
                    name: "show_options",
                    arguments: .object([
                        "name": .string("@round-trip"), "scope": .string("server"),
                    ])
                )
            )
            // Reading and writing configuration should not need two different
            // mental models, which is what an asymmetric pair produces.
            let options = try #require(outcome.structured["options"]?.arrayValue)
            #expect(options.first?["value"]?.stringValue == "yes")
        }
    }

    @Test("show_options reads one explicitly targeted session")
    func showOptionsTargetsOneSession() async throws {
        try await withTmuxServer { server in
            let bootstrap = try #require(try await server.sessions().first)
            let other = try await server.newSession(named: "option-other")
            for (session, value) in [(bootstrap, "bootstrap"), (other, "other")] {
                let reply = try await server.run(
                    TmuxCommand(
                        "set-option",
                        ["-t", session.id.rawValue, "@targeted", value]
                    )
                )
                #expect(reply.isSuccess, Comment(rawValue: reply.errorText))
            }

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "show_options",
                    arguments: .object([
                        "name": .string("@targeted"),
                        "scope": .string("session"),
                        "target": .string(wireRef(bootstrap)),
                    ])
                )
            )
            let options = try #require(outcome.structured["options"]?.arrayValue)
            #expect(options.map { $0["value"]?.stringValue } == ["bootstrap"])
        }
    }

    @Test("show_options requires a target for a local table")
    func localShowOptionsRequiresTarget() async throws {
        _ = try await withTmuxServer { server in
            await #expect(throws: ToolError.missingArgument("target")) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "show_options",
                        arguments: .object(["scope": .string("session")])
                    )
                )
            }
        }
    }

    @Test("show_options rejects a target for a global table")
    func globalShowOptionsRejectsTarget() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "show_options",
                        arguments: .object([
                            "scope": .string("global_session"),
                            "target": .string(wireRef(session)),
                        ])
                    )
                )
            }
        }
    }

    @Test("set_environment does not report a rejected write as success")
    func rejectedEnvironmentWriteIsAnError() async throws {
        try await withTmuxServer { server in
            do {
                _ = try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "set_environment",
                        arguments: .object([
                            "name": .string("INVALID=NAME"), "value": .string("value"),
                        ])
                    )
                )
                Issue.record("the rejected environment write reported success")
            } catch let error as ToolError {
                guard case .tmuxRejected = error else {
                    Issue.record("unexpected error: \(error)")
                    return
                }
            }
        }
    }

    @Test("paste_text puts key names in as text rather than pressing them")
    func pasteDoesNotInterpretKeys() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            // send_keys would read this as an interrupt and a newline. That it
            // does is right for driving a program and exactly wrong for text.
            _ = try await tools.call(
                ToolCall(
                    name: "paste_text",
                    arguments: .object([
                        "pane": .string(wireRef(pane)), "text": .string("C-c Enter"),
                    ])
                )
            )
            var seen = false
            for _ in 0..<30 {
                let rows = try await server.capture(pane)
                if rows.contains(where: { $0.contains("C-c Enter") }) {
                    seen = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(seen, "the text did not arrive as text")
        }
    }

    @Test("respawn keeps the pane, and a watcher is told the program changed")
    func respawnKeepsThePaneAndSaysSo() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .destructive)
            let watching = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(wireRef(pane))])
                )
            ).decode(CaptureSinceResult.self)

            _ = try await tools.call(
                ToolCall(
                    name: "respawn_pane", arguments: .object(["pane": .string(wireRef(pane))]))
            )
            try await Task.sleep(for: .milliseconds(400))

            // The id survives, so anything holding it keeps working — which is
            // exactly why a watcher has to be told, or it would read the new
            // program's output as the old one's.
            #expect(try await server.panes().contains { $0.id == pane.id })
            let after = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object([
                        "pane": .string(wireRef(pane)), "cursor": .string(watching.cursor),
                    ])
                )
            ).decode(CaptureSinceResult.self)
            #expect(after.restarted)
        }
    }

    @Test("list_servers finds a running server and not a socket left behind")
    func listServersFindsWhatIsRunning() async throws {
        let schema = try #require(TmuxTools.byName["list_servers"]?.outputSchema)
        #expect(schema["properties"]?["servers"]?["maxItems"]?.doubleValue == 128)
        try await withTmuxServer { server in
            guard case let .socketPath(path) = server.endpoint else { return }
            let directory = (path as NSString).deletingLastPathComponent
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "list_servers",
                    arguments: .object(["directories": .array([.string(directory)])])
                )
            )
            let servers = try #require(outcome.structured["servers"]?.arrayValue)
            #expect(servers.count == 1)
            #expect(servers.first?["socketPath"]?.stringValue == path)
            #expect(outcome.structured["truncated"]?.boolValue == false)
        }
    }

    @Test("killing the caller's own server is refused unless it is confirmed")
    func killServerIsGuarded() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let session = try #require(try await server.sessions().first)
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
                        name: "kill_server",
                        arguments: .object([
                            "server_ref": .string(try await serverRef(server))
                        ])
                    )
                )
            }
            // Still running, which is the point of the guard.
            #expect(try await server.isRunning())
        }
    }

    @Test("hooks can be read and are deliberately not writable")
    func hooksAreReadOnly() async throws {
        try await withTmuxServer { server in
            try await server.setHook("after-new-window", to: "display-message hooked")
            let outcome = try await TmuxTools(server: server)
                .call(ToolCall(name: "show_hooks"))
            let hooks = try #require(outcome.structured["hooks"]?.arrayValue)
            #expect(hooks.contains { $0["name"]?.stringValue == "after-new-window" })
            // A hook outlives this process, so writing one from here would keep
            // firing long after the conversation that set it ended.
            #expect(TmuxTools.byName["set_hook"] == nil)
        }
    }
}
