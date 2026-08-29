import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

private func containsKey(_ key: String, in value: JSONValue) -> Bool {
    switch value {
    case let .array(values):
        values.contains { containsKey(key, in: $0) }
    case let .object(members):
        members[key] != nil || members.values.contains { containsKey(key, in: $0) }
    case .null, .bool, .integer, .unsignedInteger, .number, .string:
        false
    }
}

private func resourceJSON(_ resource: JSONValue) throws -> JSONValue {
    let text = try #require(resource["text"]?.stringValue)
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite("tmux tools", .timeLimit(.minutes(2)))
struct TmuxToolsTests {
    @Test("an unknown tool is refused by name")
    func unknownToolIsRefused() async throws {
        _ = try await withTmuxServer { server in
            await #expect(throws: ToolError.unknownTool("teleport")) {
                try await TmuxTools(server: server).call(ToolCall(name: "teleport"))
            }
        }
    }

    @Test("a listing crosses the boundary as decodable JSON")
    func listingCrossesAsDecodableJSON() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server)
                .call(ToolCall(name: "list_sessions"))
            #expect(try outcome.rows("sessions", SessionResult.self).map(\.name) == ["bootstrap"])
        }
    }

    @Test("default read results do not expose domain server provenance")
    func defaultReadResultsHideDomainServerProvenance() async throws {
        try await withTmuxServer { server in
            guard case let .socketPath(socketPath) = server.endpoint else { return }
            let tools = TmuxTools(server: server)
            var results: [JSONValue] = []
            for name in ["list_sessions", "list_windows", "list_panes", "snapshot"] {
                results.append(try await tools.call(ToolCall(name: name)).structured)
            }

            let session = try #require(try await server.sessions().first)
            let pane = try #require(try await server.panes().first)
            let resources = TmuxResources(server: server)
            let resourceURIs = [
                "tmux://snapshot",
                "tmux://sessions",
                "tmux://sessions/\(wireRef(session))/windows",
                "tmux://panes/\(wireRef(pane))",
            ]
            var resourceValues: [JSONValue] = []
            for uri in resourceURIs {
                resourceValues.append(try resourceJSON(try await resources.read(uri)))
            }

            let values = results + resourceValues
            for key in ["incarnation", "endpoint", "socketPath"] {
                #expect(values.allSatisfy { !containsKey(key, in: $0) })
            }
            let encoded = try values.map { try JSONEncoder().encode($0) }
            #expect(
                encoded.allSatisfy {
                    !String(decoding: $0, as: UTF8.self).contains(socketPath)
                }
            )
        }
    }

    @Test("list_windows returns every exact link whose global window matches")
    func listWindowsReturnsExactMatchingLinks() async throws {
        try await withTmuxServer { server in
            let sourceLink = try #require(try await server.windowLinks().first)
            let source = try #require(
                try await server.windows().first { $0.id == sourceLink.windowID }
            )
            let destination = try await server.newSession(named: "list-window-links")
            let firstDuplicate = try await server.link(source, into: destination)
            let secondDuplicate = try await server.link(source, into: destination)
            let expression = try FilterExpr<Window>.where(\.id, .equals(source.id))
            let filter = try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(expression)
            )

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(name: "list_windows", arguments: .object(["filter": filter]))
            )
            let rows = try #require(outcome.structured["windows"]?.arrayValue)

            #expect(rows.count == 3)
            #expect(Set(rows.compactMap { $0["id"]?.stringValue }) == [source.id.rawValue])
            #expect(
                Set(rows.compactMap { $0["target"]?.stringValue })
                    == [sourceLink.target, firstDuplicate.target, secondDuplicate.target]
            )
            #expect(
                rows.allSatisfy {
                    $0.objectValue?.keys.sorted()
                        == [
                            "height", "id", "index", "isActive", "linkRef", "name",
                            "paneCount", "sessionID", "target", "width", "windowRef",
                        ]
                }
            )
        }
    }

    @Test("a listing can be narrowed to the fields that answer the question")
    func listingProjectsToRequestedFields() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "list_panes",
                    arguments: .object(["fields": .array([.string("id")])])
                )
            )
            let rows = try #require(outcome.structured["panes"]?.arrayValue)
            // Everything else is context the caller said it would not read.
            #expect(rows.allSatisfy { $0.objectValue?.keys.sorted() == ["id", "ref"] })
        }
    }

    @Test("a client reads a field no listing carries")
    func clientReadsAnUnlistedField() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "read_format",
                    arguments: .object([
                        "template": .string("#{pane_tty}"),
                        "target": .string(wireRef(pane)),
                    ])
                )
            )
            #expect(try outcome.decode(FormatResult.self).value?.hasPrefix("/dev/") == true)
        }
    }

    @Test("a raw format target is refused")
    func rawFormatTargetIsRefused() async throws {
        _ = try await withTmuxServer { server in
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "read_format",
                        arguments: .object([
                            "template": .string("#{pane_tty}"), "target": .string("%999"),
                        ])
                    )
                )
            }
        }
    }

    @Test("a client filters by sending an expression, not by fetching everything")
    func clientFiltersBySendingAnExpression() async throws {
        try await withTmuxServer { server in
            _ = try await server.run(TmuxCommand("split-window", ["-d", "-t", "bootstrap"]))
            let tools = TmuxTools(server: server)

            let all = try await tools.call(ToolCall(name: "list_panes"))
            #expect(try all.rows("panes", PaneResult.self).count == 2)

            // Built here the way a Swift client would, then sent as text — the
            // round trip a closure could never make.
            let expression = try FilterExpr<Pane>.where(\.isActive, .equals(true))
            let encoded = String(
                decoding: try JSONEncoder().encode(expression),
                as: UTF8.self
            )
            let active = try await tools.call(
                ToolCall(
                    name: "list_panes",
                    arguments: .object(["filter": .string(encoded)])
                )
            )
            let filtered = try active.rows("panes", PaneResult.self)
            #expect(filtered.count == 1)
            #expect(filtered.first?.isActive == true)
        }
    }

    @Test("a filter may also arrive inlined rather than as JSON text")
    func filterMayArriveInlined() async throws {
        try await withTmuxServer { server in
            let expression = try FilterExpr<Pane>.where(\.isActive, .equals(true))
            let inlined = try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(expression)
            )
            // Models send both shapes, and rejecting either would be a
            // distinction with no reason behind it.
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(name: "list_panes", arguments: .object(["filter": inlined]))
            )
            #expect(try outcome.rows("panes", PaneResult.self).count == 1)
        }
    }

    @Test("invalid nested filters are refused")
    func invalidNestedFiltersAreRefused() async throws {
        try await withTmuxServer { server in
            let expression = FilterExpr<Pane>.not(
                .and([
                    .comparison(
                        field: "pane.retired",
                        operation: .equals(.flag(true))
                    )
                ])
            )
            let inlined = try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(expression)
            )
            let relation = try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(RelationQuery(.some, expression))
            )
            let calls = [
                (
                    ToolCall(name: "list_panes", arguments: .object(["filter": inlined])),
                    "filter"
                ),
                (
                    ToolCall(name: "list_windows", arguments: .object(["filter": inlined])),
                    "filter"
                ),
                (
                    ToolCall(
                        name: "search_panes",
                        arguments: .object(["pattern": .string("."), "filter": inlined])
                    ),
                    "filter"
                ),
                (
                    ToolCall(
                        name: "list_sessions",
                        arguments: .object(["pane_relation": relation])
                    ),
                    "pane_relation"
                ),
            ]

            for (call, argument) in calls {
                await #expect(
                    throws: ToolError.wrongArgumentType(
                        argument,
                        expected: "a filter using known field ids; pane.retired is unknown"
                    ),
                    "\(call.name) accepted an unknown nested field"
                ) {
                    try await TmuxTools(server: server).call(call)
                }
            }

            let incompatible = FilterExpr<Pane>.comparison(
                field: "pane.index", operation: .contains("3")
            )
            let encoded = try JSONDecoder().decode(
                JSONValue.self,
                from: try JSONEncoder().encode(incompatible)
            )
            await #expect(
                throws: ToolError.wrongArgumentType(
                    "filter",
                    expected:
                        "a filter whose operator and values match pane.index's integer type"
                )
            ) {
                try await TmuxTools(server: server).call(
                    ToolCall(name: "list_panes", arguments: .object(["filter": encoded]))
                )
            }
        }
    }

    @Test("a client that does not speak Swift can learn the vocabulary")
    func clientCanLearnTheVocabulary() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server)
                .call(ToolCall(name: "describe_filters"))
            let schema = try outcome.decode(FilterSchema.self)
            #expect(schema.schemaVersion == FilterSchema.version)
            let field = try #require(schema.field(named: "active", in: "pane"))
            #expect(field.id == "pane.active")
            #expect(field.type == .flag)
        }
    }

    @Test("describe_server answers what would otherwise cost a turn each")
    func describeServerAnswersTheOrientingQuestions() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(
                server: server,
                tier: .readonly,
                waitCeiling: .milliseconds(1_250)
            ).call(ToolCall(name: "describe_server"))
            let described = try outcome.decode(ServerDescription.self)
            #expect(described.tmuxVersion != nil)
            #expect(described.isSupported == true)
            #expect(described.safetyTier == .readonly)
            #expect(described.waitCeilingSeconds == 1.25)
            #expect(described.sessionCount >= 1)
            #expect(described.capabilities.formatSubscriptions)
        }
    }

    @Test("a snapshot answers every level in one call")
    func snapshotAnswersEveryLevel() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server)
                .call(ToolCall(name: "snapshot"))
            let snapshot = try outcome.decode(SnapshotResult.self)
            #expect(!snapshot.sessions.isEmpty)
            #expect(!snapshot.windows.isEmpty)
            #expect(!snapshot.panes.isEmpty)
        }
    }

}
