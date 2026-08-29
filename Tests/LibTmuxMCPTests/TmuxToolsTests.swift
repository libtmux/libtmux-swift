import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

extension ToolOutcome {
    /// Decodes what a tool answered, the way a client would.
    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }

    /// Decodes a listing out of the object it is named inside.
    ///
    /// `structuredContent` is an object in MCP, so a listing answers
    /// `{"panes": [...]}` rather than a bare array.
    func rows<Value: Decodable>(_ name: String, _ type: Value.Type) throws -> [Value] {
        guard let rows = structured[name] else { throw ListingMissing(name: name) }
        return try JSONDecoder().decode(
            [Value].self,
            from: try JSONEncoder().encode(rows)
        )
    }
}

/// Thrown when a listing did not answer under the name its schema promises.
struct ListingMissing: Error {
    let name: String
}

@Suite("the tool catalogue", .timeLimit(.minutes(1)))
struct ToolCatalogTests {
    @Test("every tool is described before it can be called")
    func everyToolIsDescribed() {
        for definition in TmuxTools.definitions {
            #expect(!definition.summary.isEmpty)
            #expect(!definition.title.isEmpty)
            for argument in definition.arguments {
                #expect(!argument.summary.isEmpty)
            }
        }
    }

    @Test("no two tools share a name")
    func toolNamesAreUnique() {
        let names = TmuxTools.definitions.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("every declared argument is one the tool can actually receive")
    func declaredArgumentsAreReadable() throws {
        // The bug this replaces: the protocol layer named the arguments it
        // carried, and the two it forgot could never arrive however correctly
        // they were sent. Reading through the declaration is what makes the
        // schema and the reader the same list.
        for definition in TmuxTools.definitions {
            var members: [String: JSONValue] = [:]
            for argument in definition.arguments {
                members[argument.name] = Self.sample(for: argument)
            }
            let call = ToolCall(name: definition.name, arguments: .object(members))
            #expect(throws: Never.self) { try Arguments(call, for: definition) }
        }
    }

    @Test("an argument the tool does not declare is refused, with the list")
    func undeclaredArgumentsAreRefused() throws {
        let definition = try #require(TmuxTools.byName["wait_for_output"])
        let call = ToolCall(
            name: "wait_for_output",
            arguments: .object(["pane": .string("%0"), "pattern": .string("x")])
        )
        // Silently ignoring this is what makes a wait look like a quiet pane.
        #expect(throws: ToolError.self) { try Arguments(call, for: definition) }
    }

    @Test("a required argument that is missing says which one")
    func missingRequiredArgumentIsNamed() throws {
        let definition = try #require(TmuxTools.byName["read_format"])
        #expect(throws: ToolError.missingArgument("template")) {
            try Arguments(ToolCall(name: "read_format"), for: definition)
        }
    }

    @Test("a value outside an argument's enum is refused with the choices")
    func valueOutsideEnumIsRefused() throws {
        let definition = try #require(TmuxTools.byName["split_pane"])
        let call = ToolCall(
            name: "split_pane",
            arguments: .object(["pane": .string("%0"), "direction": .string("sideways")])
        )
        let arguments = try Arguments(call, for: definition)
        #expect(throws: ToolError.self) { try arguments.string("direction", or: "below") }
    }

    @Test("every schema declares its type and refuses extra properties")
    func schemasAreWellFormed() {
        for definition in TmuxTools.definitions {
            let schema = definition.inputSchema
            #expect(schema["type"]?.stringValue == "object")
            #expect(schema["additionalProperties"]?.boolValue == false)
            let properties = schema["properties"]?.objectValue ?? [:]
            #expect(properties.count == definition.arguments.count)
            for argument in definition.arguments {
                let member = properties[argument.name]
                #expect(member?["type"]?.stringValue == argument.kind.schemaType)
                #expect(member?["description"]?.stringValue?.isEmpty == false)
                if argument.kind == .stringArray {
                    #expect(member?["items"] != nil)
                }
            }
        }
    }

    @Test("behaviour hints match the tier each tool is filed under")
    func annotationsMatchTiers() {
        for definition in TmuxTools.definitions {
            let annotations = definition.annotations
            #expect(
                annotations["readOnlyHint"]?.boolValue == (definition.tier == .readonly)
            )
            #expect(
                annotations["destructiveHint"]?.boolValue
                    == (definition.tier == .destructive)
            )
        }
    }

    @Test("the server blurb fits the budget clients allocate for it")
    func instructionsFitTheBudget() {
        // Measured rather than asserted at runtime: a blurb that outgrew its
        // budget should fail here, not drop a section in front of a user.
        for tier in SafetyTier.allCases {
            let text = Instructions.required(tier: tier, waitCeiling: .seconds(120))
                .joined(separator: "\n\n")
            #expect(text.utf8.count <= Instructions.maximumBytes)
        }
    }

    private static func sample(for argument: ToolArgument) -> JSONValue {
        if let first = argument.allowed.first { return .string(first) }
        switch argument.kind {
        case .string: return .string("%0")
        case .integer, .number: return .number(1)
        case .boolean: return .bool(false)
        case .stringArray: return .array([.string("x")])
        case .object: return .object([:])
        }
    }
}

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
                ToolCall(name: "kill_pane", arguments: .object(["pane": .string(pane.id.rawValue)]))
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
                        name: "kill_pane",
                        arguments: .object(["pane": .string(pane.id.rawValue)])
                    )
                )
            }
            // Still reachable on purpose: the guard exists to stop an accident,
            // not to remove a capability.
            _ = try await tools.call(
                ToolCall(
                    name: "kill_pane",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue), "confirm_self": .bool(true),
                    ])
                )
            )
        }
    }

    @Test("killing what holds the caller's pane is refused too")
    func killingTheEnclosingWindowIsRefused() async throws {
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
            // The pane is not the target here — its window and its session are.
            // Guarding only the pane would leave two other ways to end the same
            // conversation by accident.
            for (tool, target) in [
                ("kill_window", pane.windowID.rawValue), ("kill_session", session.id.rawValue),
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
                        "target": .string(pane.windowID.rawValue),
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
                        arguments: .object(["target": .string(destination.id.rawValue)])
                    )
                )
            }
            #expect(try await server.sessions().contains { $0.id == destination.id })
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
                ToolCall(name: "kill_pane", arguments: .object(["pane": .string(pane.id.rawValue)]))
            )
        }
    }

    @Test("commands that would never return are refused by name")
    func blockingCommandsAreRefused() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            for command in ["wait-for", "attach-session", "command-prompt"] {
                await #expect(throws: ToolError.self) {
                    try await tools.call(
                        ToolCall(
                            name: "run_command",
                            arguments: .object(["command": .string(command)])
                        )
                    )
                }
            }
        }
    }
}

@Suite("tmux tools", .timeLimit(.minutes(2)))
struct TmuxToolsTests {
    @Test("an unknown tool is refused by name")
    func unknownToolIsRefused() async throws {
        try await withTmuxServer { server in
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
            #expect(try outcome.rows("sessions", Session.self).map(\.name) == ["bootstrap"])
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
            #expect(rows.allSatisfy { $0.objectValue?.keys.sorted() == ["id"] })
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
                        "target": .string(pane.id.rawValue),
                    ])
                )
            )
            #expect(try outcome.decode(FormatResult.self).value?.hasPrefix("/dev/") == true)
        }
    }

    @Test("a format naming a target that is gone reports nothing, not empty text")
    func formatOfAMissingTargetReportsNothing() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "read_format",
                    arguments: .object([
                        "template": .string("#{pane_tty}"), "target": .string("%999"),
                    ])
                )
            )
            #expect(try outcome.decode(FormatResult.self).value == nil)
        }
    }

    @Test("a client filters by sending an expression, not by fetching everything")
    func clientFiltersBySendingAnExpression() async throws {
        try await withTmuxServer { server in
            _ = try await server.run(TmuxCommand("split-window", ["-d", "-t", "bootstrap"]))
            let tools = TmuxTools(server: server)

            let all = try await tools.call(ToolCall(name: "list_panes"))
            #expect(try all.rows("panes", Pane.self).count == 2)

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
            let filtered = try active.rows("panes", Pane.self)
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
            #expect(try outcome.rows("panes", Pane.self).count == 1)
        }
    }

    @Test("unknown nested filter fields are refused")
    func unknownNestedFilterFieldsAreRefused() async throws {
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
            let outcome = try await TmuxTools(server: server, tier: .readonly)
                .call(ToolCall(name: "describe_server"))
            let described = try outcome.decode(ServerDescription.self)
            #expect(described.tmuxVersion != nil)
            #expect(described.isSupported == true)
            #expect(described.safetyTier == .readonly)
            #expect(described.sessionCount >= 1)
            #expect(described.capabilities.formatSubscriptions)
        }
    }

    @Test("a snapshot answers every level in one call")
    func snapshotAnswersEveryLevel() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server)
                .call(ToolCall(name: "snapshot"))
            let snapshot = try outcome.decode(Snapshot.self)
            #expect(!snapshot.sessions.isEmpty)
            #expect(!snapshot.windows.isEmpty)
            #expect(!snapshot.panes.isEmpty)
        }
    }

    @Test("capture reports what it dropped rather than looking like a short pane")
    func captureReportsWhatItDropped() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue), "max_lines": .number(2),
                    ])
                )
            )
            let captured = try outcome.decode(CaptureResult.self)
            #expect(captured.lines.count <= 2)
            #expect(captured.droppedLines >= 0)
        }
    }

    @Test("watching a pane sends the difference, not the screen")
    func captureSinceSendsOnlyWhatIsNew() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)

            let started = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(pane.id.rawValue)])
                )
            ).decode(CaptureSinceResult.self)
            // Starting to watch is not the same as asking for the backlog.
            #expect(started.lines.isEmpty)
            #expect(!started.cursor.isEmpty)

            try await server.run("printf 'incremental-marker\\n'", in: pane)
            var caught = started
            for _ in 0..<30 {
                caught = try await tools.call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "pane": .string(pane.id.rawValue), "cursor": .string(caught.cursor),
                        ])
                    )
                ).decode(CaptureSinceResult.self)
                if !caught.lines.isEmpty { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(caught.lines.contains { $0.contains("incremental-marker") })

            let quiet = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue), "cursor": .string(caught.cursor),
                    ])
                )
            ).decode(CaptureSinceResult.self)
            // The whole point: a second look at a pane that has not moved
            // costs one call and no content.
            #expect(quiet.lines.isEmpty)
        }
    }

    @Test("a cursor that is not one is refused rather than guessed at")
    func malformedCursorIsRefused() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "pane": .string(pane.id.rawValue), "cursor": .string("not-a-cursor"),
                        ])
                    )
                )
            }
        }
    }

    @Test("a structurally impossible cursor is refused")
    func impossibleCursorIsRefused() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let started = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(pane.id.rawValue)])
                )
            ).decode(CaptureSinceResult.self)
            var payload = try #require(
                JSONSerialization.jsonObject(with: Data(started.cursor.utf8))
                    as? [String: Any]
            )
            payload["anchor"] = -1
            let impossible = try #require(
                String(
                    data: JSONSerialization.data(withJSONObject: payload),
                    encoding: .utf8
                )
            )

            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "capture_since",
                        arguments: .object([
                            "pane": .string(pane.id.rawValue),
                            "cursor": .string(impossible),
                        ])
                    )
                )
            }
        }
    }

    @Test("a stale pane id fails with the id in the message")
    func stalePaneIDIsNamed() async throws {
        try await withTmuxServer { server in
            await #expect(throws: ToolError.self) {
                try await TmuxTools(server: server).call(
                    ToolCall(
                        name: "capture_pane",
                        arguments: .object(["pane": .string("%999")])
                    )
                )
            }
        }
    }

    @Test("search finds text in what a pane printed, with the pane that printed it")
    func searchFindsPrintedText() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'needle-in-a-pane\\n'", in: pane)
            let tools = TmuxTools(server: server)

            var found: SearchResult?
            for _ in 0..<20 {
                let outcome = try await tools.call(
                    ToolCall(
                        name: "search_panes",
                        arguments: .object(["pattern": .string("needle-in-a-pane")])
                    )
                )
                found = try outcome.decode(SearchResult.self)
                if !(found?.matches.isEmpty ?? true) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(found?.matches.first?.pane == pane.id.rawValue)
        }
    }

    @Test("a rejected tmux command is reported, not thrown")
    func rejectedCommandIsReported() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_command",
                    arguments: .object([
                        "command": .string("has-session"),
                        "arguments": .array([.string("-t"), .string("absent")]),
                    ])
                )
            )
            let result = try outcome.decode(CommandResult.self)
            // A client asking whether a session exists wants the answer.
            #expect(result.exitCode != 0)
            #expect(!result.standardError.isEmpty)
        }
    }

    @Test("a batch says which step failed and stops there")
    func batchAttributesItsFailure() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_commands",
                    arguments: .object([
                        "commands": .array([
                            .object(["command": .string("list-sessions")]),
                            .object([
                                "command": .string("has-session"),
                                "arguments": .array([.string("-t"), .string("absent")]),
                            ]),
                            .object(["command": .string("list-windows")]),
                        ])
                    ])
                )
            )
            let batch = try outcome.decode(BatchResult.self)
            #expect(batch.requested == 3)
            // A `;` list merges every command's output into one stream; this
            // says which one stopped it.
            #expect(batch.steps.count == 2)
            #expect(batch.steps.last?.step == 1)
            #expect(batch.steps.last?.command == "has-session")
            #expect(batch.stoppedEarly)
        }
    }

    @Test("run_shell reports the exit status and only its own output")
    func runShellReportsStatusAndOutput() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("printf 'shell-marker\\n'"),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(!result.timedOut)
            #expect(result.output.contains { $0.contains("shell-marker") })
        }
    }

    @Test("run_shell does not depend on a tmux being on the pane's PATH")
    func runShellDoesNotNeedTmuxOnPath() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            // A bare `tmux` here would be whichever one the pane can find, and
            // a client of a different protocol version is refused with `server
            // exited unexpectedly` — reaching the caller as a command that
            // simply never finished. Emptying PATH is the same fault, made
            // deterministic.
            try await server.run("PATH=/nonexistent; export PATH", in: pane)
            try await Task.sleep(for: .milliseconds(200))

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("/bin/echo path-independent"),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(!result.timedOut)
            #expect(result.exitStatus == 0)
        }
    }

    @Test("run_shell carries a failing command's status back")
    func runShellCarriesFailure() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("(exit 3)"),
                        "timeout": .number(20),
                    ])
                )
            )
            #expect(try outcome.decode(RunShellResult.self).exitStatus == 3)
        }
    }

    @Test("run_shell is pane-global when its window has several links")
    func runShellDoesNotRequireAWindowLink() async throws {
        try await withTmuxServer { server in
            let source = try #require(try await server.windowLinks().first)
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.windowID }
            )
            let destination = try await server.newSession(named: "run-shell-destination")
            _ = try await server.link(source, into: destination)
            _ = try await server.link(source, into: destination)

            let outcome = try await TmuxTools(server: server, caller: nil).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("printf 'pane-global\\n'"),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(!result.timedOut)
        }
    }

    @Test("run_shell reports an identical output occurrence")
    func runShellReportsRepeatedOutput() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let command = "printf 'repeated-shell-output\\n'"
            let echoOff = "libtmux-test-echo-off-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; \(server.shellInvocation) wait-for -S \(echoOff)",
                in: pane
            )
            try await server.wait(for: echoOff)
            let seeded = "libtmux-test-seeded-\(UUID().uuidString)"
            try await server.run(
                "\(command); \(server.shellInvocation) wait-for -S \(seeded)",
                in: pane
            )
            try await server.wait(for: seeded)

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string(command),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(result.output.contains { $0.hasSuffix("repeated-shell-output") })
        }
    }

    @Test("concurrent run_shell calls keep their own status")
    func concurrentRunShellCallsKeepTheirStatus() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let results = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
                for expected in 1...8 {
                    group.addTask {
                        let outcome = try await tools.call(
                            ToolCall(
                                name: "run_shell",
                                arguments: .object([
                                    "pane": .string(pane.id.rawValue),
                                    "command": .string("(exit \(expected))"),
                                    "timeout": .number(20),
                                ])
                            )
                        )
                        return (expected, try outcome.decode(RunShellResult.self).exitStatus)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }

            for (expected, actual) in results {
                #expect(actual == expected)
            }
        }
    }

    @Test("a timed-out run keeps later output separate")
    func timedOutRunKeepsThePaneLease() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("sleep 1; printf 'first-run-finished\\n'"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            let second = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("printf 'second-run-only\\n'"),
                        "timeout": .number(5),
                    ])
                )
            )
            let result = try second.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(result.output.contains { $0.hasSuffix("second-run-only") })
            #expect(!result.output.contains { $0.hasSuffix("first-run-finished") })
        }
    }

    @Test("separate tool values share one pane lease")
    func paneLeaseIsSharedAcrossToolValues() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let firstTools = TmuxTools(server: server)
            let first = try await firstTools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("sleep 2"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            let secondTools = TmuxTools(server: server)
            await #expect(throws: ToolError.self) {
                try await secondTools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(pane.id.rawValue),
                            "command": .string("printf 'must-not-run\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            }
        }
    }

    @Test("respawning a pane releases its timed-out run")
    func paneRespawnReleasesTimedOutRun() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("sleep 30"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            try await server.respawn(pane)
            let second = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("printf 'after-respawn\n'"),
                        "timeout": .number(3),
                    ])
                )
            )
            let result = try second.decode(RunShellResult.self)
            #expect(!result.timedOut)
            #expect(result.output.contains { $0.hasSuffix("after-respawn") })
        }
    }

    @Test("a retained dead pane releases its timed-out run")
    func retainedDeadPaneReleasesTimedOutRun() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let window = try #require(
                try await server.windows().first { $0.id == pane.windowID }
            )
            try await server.setOption("remain-on-exit", to: "on", of: window)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("exit"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)
            #expect(
                try await waitUntil {
                    try await server.format("#{pane_dead}", addressing: pane.id.rawValue) == "1"
                }
            )

            do {
                _ = try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(pane.id.rawValue),
                            "command": .string("printf 'dead-pane\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            } catch let error as ToolError {
                if case let .refusedForSafety(reason) = error {
                    #expect(!reason.contains("earlier run_shell"))
                }
            }
        }
    }

    @Test("waiting for a busy pane is bounded")
    func busyPaneWaitUsesTheRequestedTimeout() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "command": .string("sleep 2"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            let started = ContinuousClock.now
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(pane.id.rawValue),
                            "command": .string("printf 'must-not-run\\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            }
            #expect(ContinuousClock.now - started < .seconds(1))
        }
    }

    @Test("a workspace plan builds a whole session in one call")
    func workspacePlanBuildsASession() async throws {
        try await withTmuxServer { server in
            let plan = """
                {"session_name":"planned","windows":[
                  {"window_name":"one","panes":[{"shell_command":[]}]},
                  {"window_name":"two","panes":[{"shell_command":[]},{"shell_command":[]}]}
                ]}
                """
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "apply_workspace",
                    arguments: .object(["plan": .string(plan)])
                )
            )
            let built = try outcome.decode(WorkspaceResult.self)
            #expect(built.session.name == "planned")
            #expect(built.windows.count == 2)
            #expect(built.panes.count == 3)
        }
    }

    @Test("a wait is clamped to the ceiling and says what was enforced")
    func waitsAreClampedToTheCeiling() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, waitCeiling: .seconds(1))
            let outcome = try await tools.call(
                ToolCall(
                    name: "wait_for_output",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "patterns": .array([.string("never-arrives")]),
                        // Far past the ceiling: clamped rather than refused, so
                        // an over-large ask still does something useful.
                        "timeout": .number(9999),
                    ])
                )
            )
            let waited = try outcome.decode(OutputWaitResult.self)
            #expect(waited.effectiveTimeout == 1)
            #expect(waited.outcome == "timedOut")
            #expect(!waited.sawNewOutput)
        }
    }

    @Test("format watches require an exact link when a window appears more than once")
    func linkedPaneWatchesRequireAnExactLink() async throws {
        try await withTmuxServer { server in
            let source = try #require(try await server.windowLinks().first)
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.windowID }
            )
            let destination = try await server.newSession(named: "wait-destination")
            let destinationLink = try await server.link(source, into: destination)
            let duplicate = try await server.link(source, into: destination)
            let tools = TmuxTools(server: server, caller: nil)

            await #expect(throws: ToolError.self) {
                try await tools.windowLink(for: pane, matching: nil)
            }
            #expect(
                try await tools.windowLink(for: pane, matching: destinationLink.target)
                    == destinationLink
            )
            #expect(
                try await tools.windowLink(for: pane, matching: duplicate.target)
                    == duplicate
            )
            await #expect(throws: ToolError.self) {
                try await tools.windowLink(for: pane, matching: destination.id.rawValue)
            }
        }
    }

    @Test("watch_format ignores another link's initial value")
    func watchFormatFiltersDuplicateWindowLinks() async throws {
        try await withTmuxServer { server in
            let source = try #require(try await server.windowLinks().first)
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.windowID }
            )
            let destination = try await server.newSession(named: "watch-destination")
            let exact = try await server.link(source, into: destination)
            _ = try await server.link(source, into: destination)

            let outcome = try await TmuxTools(server: server, caller: nil).call(
                ToolCall(
                    name: "watch_format",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "window_link": .string(exact.target),
                        "format": .string("#{window_index}:#{window_active}"),
                        "timeout": .number(0.5),
                    ])
                )
            )
            #expect(try outcome.decode(FormatWatchResult.self).outcome == "timedOut")
        }
    }

    @Test("a wait whose condition already holds answers instead of blocking")
    func waitAnswersWhenTheConditionAlreadyHolds() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'already-listening\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            let tools = TmuxTools(server: server, waitCeiling: .seconds(30))
            let outcome = try await tools.call(
                ToolCall(
                    name: "wait_for_output",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "patterns": .array([.string("already-listening")]),
                        "timeout": .number(30),
                    ])
                )
            )
            let waited = try outcome.decode(OutputWaitResult.self)
            // The failure this replaces: an agent asked to wait for something
            // that had already happened sat for the whole timeout and then
            // reported a fact it knew on arrival.
            #expect(waited.outcome == "matched")
            #expect(waited.matchedAtEntry)
            #expect(waited.seconds < 5)
        }
    }

    @Test("require_fresh waits past a match that is already on screen")
    func requireFreshWaitsPastAStaleMatch() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'already-listening\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "wait_for_output",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "patterns": .array([.string("already-listening")]),
                        "require_fresh": .bool(true),
                        "timeout": .number(1),
                    ])
                )
            )
            let waited = try outcome.decode(OutputWaitResult.self)
            #expect(waited.outcome == "timedOut")
            #expect(waited.matchedAtEntry)
        }
    }

    @Test("watch_format returns on the value it was told to wait for")
    func watchFormatReturnsOnItsValue() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            // Started first and long enough to outlast the subscription being
            // made: tmux reports a subscribed format's value once on creation
            // and then on change, so a command that has already ended is a
            // change the watch was never there to see.
            try await server.run("exec sleep 60", in: pane)
            let running = try await waitUntil {
                try await server.panes()
                    .first { $0.id == pane.id }?.currentCommand == "sleep"
            }
            #expect(running)

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "watch_format",
                    arguments: .object([
                        "pane": .string(pane.id.rawValue),
                        "format": .string("#{pane_current_command}"),
                        "matching": .string("^sleep$"),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(FormatWatchResult.self)
            #expect(result.outcome == "changed")
            #expect(result.value == "sleep")
        }
    }

    @Test("a channel wait returns when the channel is signalled")
    func channelWaitReturnsOnSignal() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            async let waited = tools.call(
                ToolCall(
                    name: "wait_for_channel",
                    arguments: .object([
                        "channel": .string("gate"), "timeout": .number(20),
                    ])
                )
            )
            try await Task.sleep(for: .milliseconds(200))
            _ = try await tools.call(
                ToolCall(
                    name: "signal_channel",
                    arguments: .object(["channel": .string("gate")])
                )
            )
            #expect(try await waited.decode(ChannelWaitResult.self).released)
        }
    }

    @Test("a channel wait that times out says so rather than hanging")
    func channelWaitTimesOut() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "wait_for_channel",
                    arguments: .object([
                        "channel": .string("never-signalled"), "timeout": .number(1),
                    ])
                )
            )
            #expect(try outcome.decode(ChannelWaitResult.self).released == false)
        }
    }
}

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
                        "pane": .string(pane.id.rawValue), "text": .string("C-c Enter"),
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
            let tools = TmuxTools(server: server)
            let watching = try await tools.call(
                ToolCall(
                    name: "capture_since",
                    arguments: .object(["pane": .string(pane.id.rawValue)])
                )
            ).decode(CaptureSinceResult.self)

            _ = try await tools.call(
                ToolCall(
                    name: "respawn_pane", arguments: .object(["pane": .string(pane.id.rawValue)]))
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
                        "pane": .string(pane.id.rawValue), "cursor": .string(watching.cursor),
                    ])
                )
            ).decode(CaptureSinceResult.self)
            #expect(after.restarted)
        }
    }

    @Test("list_servers finds a running server and not a socket left behind")
    func listServersFindsWhatIsRunning() async throws {
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
                try await tools.call(ToolCall(name: "kill_server"))
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

@Suite("relation queries across the boundary", .timeLimit(.minutes(1)))
struct RelationQueryBoundaryTests {
    @Test("a relation query travels as one value and selects by it")
    func relationQueryTravelsAsOneValue() async throws {
        try await withTmuxServer { server in
            let editors = try await server.newSession(named: "editors")
            let window = try #require(try await server.snapshot().windows(of: editors).first)
            let pane = try #require(try await server.snapshot().panes(of: window).first)
            try await server.run("exec sleep 61", in: pane)

            let running = try await waitUntil {
                try await server.panes()
                    .first { $0.id == pane.id }?.currentCommand == "sleep"
            }
            #expect(running)

            let query = RelationQuery(
                .some,
                try FilterExpr<Pane>.where(\.currentCommand, .equals("sleep"))
            )
            let encoded = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "list_sessions",
                    arguments: .object(["pane_relation": .string(encoded)])
                )
            )
            // "sessions where some pane runs sleep" — quantifier and expression
            // crossed together, which two loose arguments could not guarantee.
            #expect(try outcome.rows("sessions", Session.self).map(\.name) == ["editors"])
        }
    }

    @Test("a relation query round-trips without losing its quantifier")
    func relationQueryRoundTrips() throws {
        let query = RelationQuery(
            .every,
            try FilterExpr<Pane>.where(\.isActive, .equals(true))
        )
        let data = try JSONEncoder().encode(query)
        let decoded = try JSONDecoder().decode(RelationQuery<Pane>.self, from: data)
        #expect(decoded == query)
        #expect(decoded.quantifier == .every)
    }
}
