import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

private func firstRow(
    _ name: String,
    from outcome: ToolOutcome
) throws -> JSONValue {
    try #require(outcome.structured[name]?.arrayValue?.first)
}

private func resourceValue(_ resource: JSONValue) throws -> JSONValue {
    let text = try #require(resource["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func containsKey(_ key: String, in value: JSONValue) -> Bool {
    switch value {
    case let .array(values): values.contains { containsKey(key, in: $0) }
    case let .object(members):
        members[key] != nil || members.values.contains { containsKey(key, in: $0) }
    case .null, .bool, .number, .string: false
    }
}

@Suite("wire reference continuity", .timeLimit(.minutes(1)))
struct ReferenceContinuityTests {
    @Test(
        "server-wide mutations refuse an endpoint replacement",
        arguments: [
            "set_option", "set_environment",
        ])
    func serverWideMutationsFenceTheIncarnation(_ tool: String) async throws {
        try await withTmuxServer { fixture in
            let transport = ReplacingTransport(
                when: { $0.contains("display-message") },
                replace: {
                    try await replaceDaemon(on: fixture)
                }
            )
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )
            let name = "@libtmux_mcp_fenced_\(UUID().uuidString)"
            let arguments: [String: JSONValue] =
                tool == "set_option"
                ? ["name": .string(name), "value": .string("changed")]
                : ["name": .string(name), "value": .string("changed")]

            await #expect(throws: TmuxError.serverRestarted) {
                try await TmuxTools(server: server, tier: .mutating).call(
                    ToolCall(name: tool, arguments: .object(arguments))
                )
            }
            if tool == "set_option" {
                let value = try await fixture.option(name, scope: .server)
                #expect(value == nil)
            } else {
                let value = try await fixture.environmentValue(name)
                #expect(value == nil)
            }
        }
    }

    @Test("describe_server refuses metadata from a replacement daemon")
    func describeServerFencesItsReads() async throws {
        try await withTmuxServer { fixture in
            let transport = ReplacingTransport(
                when: { $0.contains("-V") },
                replace: {
                    try await replaceDaemon(on: fixture)
                }
            )
            let server = Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            )

            await #expect(throws: TmuxError.serverRestarted) {
                try await TmuxTools(server: server).call(ToolCall(name: "describe_server"))
            }
        }
    }

    @Test("a projected pane reference remains usable by targeted reads")
    func projectedPaneReferenceIsUsable() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let listed = try await tools.call(
                ToolCall(
                    name: "list_panes",
                    arguments: .object(["fields": .array([.string("id")])])
                )
            )
            let row = try firstRow("panes", from: listed)
            let reference = try #require(row["ref"]?.stringValue)

            #expect(row.objectValue?.keys.sorted() == ["id", "ref"])
            let captured = try await tools.call(
                ToolCall(name: "capture_pane", arguments: .object(["pane": .string(reference)]))
            )
            #expect(try captured.decode(CaptureResult.self).pane == row["id"]?.stringValue)
        }
    }

    @Test("references survive from listings into targeted resources")
    func referencesReachResources() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let session = try firstRow(
                "sessions",
                from: try await tools.call(ToolCall(name: "list_sessions"))
            )
            let pane = try firstRow(
                "panes",
                from: try await tools.call(ToolCall(name: "list_panes"))
            )
            let sessionReference = try #require(session["ref"]?.stringValue)
            let paneReference = try #require(pane["ref"]?.stringValue)
            let resources = TmuxResources(server: server)

            await #expect(throws: ToolError.self) {
                try await resources.read("tmux://panes/\(sessionReference)")
            }

            let paneValue = try resourceValue(
                try await resources.read("tmux://panes/\(paneReference)")
            )
            #expect(paneValue["id"] == pane["id"])
            #expect(paneValue["ref"]?.stringValue == paneReference)

            let windows = try resourceValue(
                try await resources.read("tmux://sessions/\(sessionReference)/windows")
            )
            let occurrence = try #require(windows.arrayValue?.first)
            #expect(occurrence["windowRef"]?.stringValue != nil)
            #expect(occurrence["linkRef"]?.stringValue != nil)
        }
    }

    @Test("an old reference rejects the same pane id after a daemon restart")
    func reusedPaneIDIsRejected() async throws {
        try await withTmuxServer { server in
            let oldServerReference = try #require(
                try await TmuxTools(server: server).call(ToolCall(name: "describe_server"))
                    .structured["ref"]?.stringValue
            )
            let old = try firstRow(
                "panes",
                from: try await TmuxTools(server: server).call(ToolCall(name: "list_panes"))
            )
            let oldID = try #require(old["id"]?.stringValue)
            let oldReference = try #require(old["ref"]?.stringValue)

            _ = try await server.run(TmuxCommand("kill-server"))
            _ = try await server.run(TmuxCommand("new-session", ["-d", "-s", "replacement"]))

            let tools = TmuxTools(server: server)
            let current = try firstRow(
                "panes",
                from: try await tools.call(ToolCall(name: "list_panes"))
            )
            #expect(current["id"]?.stringValue == oldID)
            #expect(current["ref"]?.stringValue != oldReference)
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "capture_pane",
                        arguments: .object(["pane": .string(oldReference)])
                    )
                )
            }
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server, tier: .destructive).call(
                    ToolCall(
                        name: "run_command",
                        arguments: .object([
                            "server_ref": .string(oldServerReference),
                            "command": .string("list-sessions"),
                            "confirm_unsafe": .bool(true),
                        ])
                    )
                )
            }
            await #expect(throws: ToolError.self) {
                try await TmuxResources(server: server).read(
                    "tmux://panes/\(oldReference)"
                )
            }
        }
    }

    @Test("an exact window-link reference supplies format context")
    func exactWindowLinkReferenceSuppliesFormatContext() async throws {
        try await withTmuxServer { server in
            let sourceLink = try #require(try await server.windowLinks().first)
            let source = try #require(
                try await server.windows().first { $0.id == sourceLink.windowID }
            )
            let destination = try await server.newSession(named: "reference-format")
            let duplicate = try await server.link(source, into: destination)
            let tools = TmuxTools(server: server)
            let rows = try #require(
                try await tools.call(ToolCall(name: "list_windows"))
                    .structured["windows"]?.arrayValue
            )
            let occurrence = try #require(
                rows.first { $0["target"]?.stringValue == duplicate.target }
            )
            let linkReference = try #require(occurrence["linkRef"]?.stringValue)

            let result = try await tools.call(
                ToolCall(
                    name: "read_format",
                    arguments: .object([
                        "template": .string("#{session_id}:#{window_index}:#{window_id}"),
                        "target": .string(linkReference),
                    ])
                )
            )
            #expect(
                try result.decode(FormatResult.self).value
                    == "\(duplicate.sessionID.rawValue):\(duplicate.index):"
                    + duplicate.windowID.rawValue
            )

            let pane = try #require(
                try await server.panes().first { $0.windowID == source.id }
            )
            let paneResult = try await tools.call(
                ToolCall(
                    name: "read_format",
                    arguments: .object([
                        "template": .string("#{session_id}:#{window_index}:#{pane_id}"),
                        "target": .string(WireReferenceCodec.processLocal.reference(to: pane)),
                        "window_link": .string(linkReference),
                    ])
                )
            )
            #expect(
                try paneResult.decode(FormatResult.self).value
                    == "\(duplicate.sessionID.rawValue):\(duplicate.index):\(pane.id.rawValue)"
            )
        }
    }

    @Test("creation results are projected and immediately actionable")
    func creationResultsAreProjectedAndActionable() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .mutating)
            let createdSession = try await tools.call(
                ToolCall(
                    name: "new_session",
                    arguments: .object(["name": .string("reference-created")])
                )
            )
            let sessionReference = try #require(createdSession.structured["ref"]?.stringValue)
            let createdWindow = try await tools.call(
                ToolCall(
                    name: "new_window",
                    arguments: .object(["target": .string(sessionReference)])
                )
            )
            #expect(createdWindow.structured["windowRef"]?.stringValue != nil)
            #expect(createdWindow.structured["linkRef"]?.stringValue != nil)

            let pane = try #require(try await server.panes().first)
            let split = try await tools.call(
                ToolCall(
                    name: "split_pane",
                    arguments: .object([
                        "pane": .string(WireReferenceCodec.processLocal.reference(to: pane))
                    ])
                )
            )
            let paneReference = try #require(split.structured["ref"]?.stringValue)
            _ = try await tools.call(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object(["pane": .string(paneReference)])
                )
            )

            let workspace = try await tools.call(
                ToolCall(
                    name: "apply_workspace",
                    arguments: .object([
                        "plan": .object([
                            "session_name": .string("reference-workspace"),
                            "windows": .array([
                                .object([
                                    "window_name": .string("one"),
                                    "panes": .array([.object(["shell_command": .array([])])]),
                                ])
                            ]),
                        ])
                    ])
                )
            )
            for key in ["incarnation", "endpoint", "socketPath"] {
                #expect(!containsKey(key, in: createdSession.structured))
                #expect(!containsKey(key, in: createdWindow.structured))
                #expect(!containsKey(key, in: split.structured))
                #expect(!containsKey(key, in: workspace.structured))
            }
            #expect(workspace.structured["session"]?["ref"]?.stringValue != nil)
            let workspaceWindow = try #require(
                workspace.structured["windows"]?.arrayValue?.first
            )
            #expect(workspaceWindow["windowRef"]?.stringValue != nil)
            let workspaceLink = try #require(workspaceWindow["linkRef"]?.stringValue)
            _ = try await tools.call(
                ToolCall(
                    name: "select",
                    arguments: .object(["target": .string(workspaceLink)])
                )
            )
            #expect(
                workspace.structured["panes"]?.arrayValue?.allSatisfy {
                    $0["ref"]?.stringValue != nil
                } == true
            )
        }
    }
}

private func replaceDaemon(on server: Server) async throws(TmuxError) {
    _ = try await server.run(TmuxCommand("kill-server"))
    _ = try await server.run(TmuxCommand("new-session", ["-d", "-s", "replacement"]))
}

private actor ReplacingTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let shouldReplace: @Sendable ([String]) -> Bool
    private let replace: @Sendable () async throws -> Void
    private var replaced = false

    init(
        when shouldReplace: @escaping @Sendable ([String]) -> Bool,
        replace: @escaping @Sendable () async throws -> Void
    ) {
        self.shouldReplace = shouldReplace
        self.replace = replace
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        let reply = try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        if !replaced, shouldReplace(arguments) {
            replaced = true
            do {
                try await replace()
            } catch let error as TmuxError {
                throw error
            } catch {
                throw .invocationFailed(reason: String(describing: error))
            }
        }
        return reply
    }
}
