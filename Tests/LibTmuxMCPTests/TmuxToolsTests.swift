import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

@Suite("tmux tools", .timeLimit(.minutes(1)))
struct TmuxToolsTests {
    @Test("every tool is described before it can be called")
    func everyToolIsDescribed() {
        let names = TmuxTools.definitions.map(\.name)
        #expect(
            names == [
                "list_sessions", "list_windows", "list_panes",
                "describe_filters", "read_format", "run_command",
            ]
        )
        // A required argument that no summary mentions is a tool nobody can
        // call correctly.
        for definition in TmuxTools.definitions {
            #expect(!definition.summary.isEmpty)
            for argument in definition.arguments {
                #expect(!argument.summary.isEmpty)
            }
        }
    }

    @Test("an unknown tool is refused by name")
    func unknownToolIsRefused() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            await #expect(throws: ToolError.unknownTool("teleport")) {
                try await tools.call(ToolCall(name: "teleport"))
            }
        }
    }

    @Test("a listing crosses the boundary as decodable JSON")
    func listingCrossesAsDecodableJSON() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let data = try await tools.call(ToolCall(name: "list_sessions"))
            let sessions = try JSONDecoder().decode([Session].self, from: data)
            #expect(sessions.map(\.name) == ["bootstrap"])
        }
    }

    @Test("a client reads a field no listing carries")
    func clientReadsAnUnlistedField() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let pane = try #require(try await server.panes().first)

            let data = try await tools.call(
                ToolCall(name: "read_format", template: "#{pane_tty}", target: pane.id)
            )
            let result = try JSONDecoder().decode(FormatResult.self, from: data)
            // The listed types carry a curated set of fields; this is how a
            // client reaches any of the rest without one being modelled first.
            #expect(result.value?.hasPrefix("/dev/") == true)
        }
    }

    @Test("a format with no target answers for the server")
    func formatWithoutATargetAnswersForTheServer() async throws {
        try await withTmuxServer { server in
            let data = try await TmuxTools(server: server).call(
                ToolCall(name: "read_format", template: "#{pid}")
            )
            let result = try JSONDecoder().decode(FormatResult.self, from: data)
            #expect(Int(result.value ?? "") == (try await server.serverProcessID()))
        }
    }

    @Test("a format naming a target that is gone reports nothing, not empty text")
    func formatOfAMissingTargetReportsNothing() async throws {
        try await withTmuxServer { server in
            let data = try await TmuxTools(server: server).call(
                ToolCall(name: "read_format", template: "#{pane_tty}", target: "%999")
            )
            let result = try JSONDecoder().decode(FormatResult.self, from: data)
            #expect(result.value == nil)
        }
    }

    @Test("read_format requires the template it reads")
    func readFormatRequiresATemplate() async throws {
        try await withTmuxServer { server in
            await #expect(throws: ToolError.missingArgument("template")) {
                try await TmuxTools(server: server).call(ToolCall(name: "read_format"))
            }
        }
    }

    @Test("a client filters by sending an expression, not by fetching everything")
    func clientFiltersBySendingAnExpression() async throws {
        try await withTmuxServer { server in
            _ = try await server.run(
                TmuxCommand("split-window", ["-d", "-t", "bootstrap"])
            )
            let tools = TmuxTools(server: server)

            let allPanes = try await tools.call(ToolCall(name: "list_panes"))
            let unfiltered = try JSONDecoder().decode([Pane].self, from: allPanes)
            #expect(unfiltered.count == 2)

            // The expression is built here the way a Swift client would, then
            // sent as text — the round trip a closure could never make.
            let expression = try FilterExpr<Pane>.where(\.isActive, .equals(true))
            let encoded = String(
                decoding: try JSONEncoder().encode(expression),
                as: UTF8.self
            )
            let activeOnly = try await tools.call(
                ToolCall(name: "list_panes", filter: encoded)
            )
            let filtered = try JSONDecoder().decode([Pane].self, from: activeOnly)
            #expect(filtered.count == 1)
            #expect(filtered.first?.isActive == true)
        }
    }

    @Test("a client that does not speak Swift can learn the vocabulary")
    func clientCanLearnTheVocabulary() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let described = try await tools.call(ToolCall(name: "describe_filters"))
            let schema = try JSONDecoder().decode(FilterSchema.self, from: described)
            #expect(schema.schemaVersion == FilterSchema.version)

            // Everything needed to build the expression above, without a Swift
            // key path: the field's id and the type its literal must take.
            let field = try #require(schema.field(named: "active", in: "pane"))
            #expect(field.id == "pane.active")
            #expect(field.type == .flag)
        }
    }

    @Test("a rejected tmux command is reported, not thrown")
    func rejectedCommandIsReported() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            let replied = try await tools.call(
                ToolCall(
                    name: "run_command",
                    command: "has-session",
                    arguments: ["-t", "absent"]
                )
            )
            let result = try JSONDecoder().decode(CommandResult.self, from: replied)
            // A client asking whether a session exists wants the answer.
            #expect(result.exitCode != 0)
            #expect(!result.standardError.isEmpty)
        }
    }

    @Test("run_command requires the command it runs")
    func runCommandRequiresItsCommand() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server)
            await #expect(throws: ToolError.missingArgument("command")) {
                try await tools.call(ToolCall(name: "run_command"))
            }
        }
    }
}

@Suite("relation queries across the boundary", .timeLimit(.minutes(1)))
struct RelationQueryBoundaryTests {
    @Test("a relation query travels as one value and selects by it")
    func relationQueryTravelsAsOneValue() async throws {
        try await withTmuxServer { server in
            // One session whose panes are all shells, one running an editor.
            let editors = try await server.newSession(named: "editors")
            let window = try #require(
                try await server.snapshot().windows(of: editors).first
            )
            let pane = try #require(try await server.snapshot().panes(of: window).first)
            try await server.run("exec sleep 61", in: pane)

            let running = try await waitUntil {
                // The cheapest read that answers the question: a snapshot
                // here would be six tmux invocations per iteration.
                try await server.panes()
                    .first { $0.id == pane.id }?.currentCommand == "sleep"
            }
            #expect(running)

            let query = RelationQuery(
                .some,
                try FilterExpr<Pane>.where(\.currentCommand, .equals("sleep"))
            )
            let encoded = String(
                decoding: try JSONEncoder().encode(query),
                as: UTF8.self
            )

            let tools = TmuxTools(server: server)
            let replied = try await tools.call(
                ToolCall(name: "list_sessions", paneRelation: encoded)
            )
            let selected = try JSONDecoder().decode([Session].self, from: replied)
            // "sessions where some pane runs sleep" — quantifier and expression
            // crossed together, which two loose arguments could not guarantee.
            #expect(selected.map(\.name) == ["editors"])
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
