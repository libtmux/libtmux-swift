import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// A declared output schema is a promise MCP holds the server to: whatever
/// `structuredContent` carries must conform to it. So these run the tools for
/// real and check the answers against what was advertised, rather than checking
/// the schemas against each other.
@Suite("output schemas", .timeLimit(.minutes(2)))
struct OutputSchemaTests {
    /// Every complaint about `value` against `schema`, empty when it conforms.
    private func complaints(_ value: JSONValue, against schema: JSONValue) -> [String] {
        guard let expected = schema["type"] else { return [] }
        let allowed: [String] =
            expected.stringValue.map { [$0] }
            ?? (expected.arrayValue?.compactMap(\.stringValue) ?? [])

        let actual: String =
            switch value {
            case .null: "null"
            case .bool: "boolean"
            case let .number(number): number == number.rounded() ? "integer" : "number"
            case .string: "string"
            case .array: "array"
            case .object: "object"
            }
        // A whole number is a legal `number`, which is how seconds that land
        // exactly on a second stay valid.
        let satisfied =
            allowed.contains(actual)
            || (actual == "integer" && allowed.contains("number"))
        guard satisfied else {
            return ["expected \(allowed.joined(separator: " or ")), got \(actual)"]
        }

        var found: [String] = []
        if actual == "object", let members = value.objectValue {
            let properties = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                if members[name] == nil { found.append("missing required \(name)") }
            }
            for (name, member) in members {
                guard let property = properties[name] else {
                    // A schema that names no properties is not describing the
                    // shape — the listing rows are deliberately open, because
                    // `fields` projects them. One that names some is, so a key
                    // it does not name is drift.
                    if !properties.isEmpty { found.append("undeclared property \(name)") }
                    continue
                }
                found += complaints(member, against: property).map { "\(name): \($0)" }
            }
        }
        if actual == "array", let elements = value.arrayValue, let items = schema["items"] {
            for (index, element) in elements.enumerated() {
                found += complaints(element, against: items).map { "[\(index)]: \($0)" }
            }
        }
        return found
    }

    /// Runs a tool and checks its answer against the schema it advertises.
    private func check(
        _ name: String,
        _ arguments: JSONValue,
        on tools: TmuxTools
    ) async throws {
        let definition = try #require(TmuxTools.byName[name])
        guard let schema = definition.outputSchema else { return }
        let outcome = try await tools.call(ToolCall(name: name, arguments: arguments))
        // MCP types structuredContent as an object; a bare array is not a
        // result a validating client has to accept.
        #expect(outcome.structured.objectValue != nil, "\(name) did not answer an object")
        let found = complaints(outcome.structured, against: schema)
        #expect(found.isEmpty, "\(name): \(found.joined(separator: "; "))")
    }

    @Test("what the reading tools answer is what they advertise")
    func readingToolsConform() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .destructive, caller: nil)
            let pane = try #require(try await server.panes().first)

            try await check("describe_server", .object([:]), on: tools)
            try await check("list_sessions", .object([:]), on: tools)
            try await check("list_windows", .object([:]), on: tools)
            try await check("list_panes", .object([:]), on: tools)
            try await check(
                "list_panes",
                .object(["fields": .array([.string("id")])]),
                on: tools
            )
            try await check(
                "capture_pane",
                .object(["pane": .string(pane.id)]),
                on: tools
            )
            try await check(
                "capture_since",
                .object(["pane": .string(pane.id)]),
                on: tools
            )
            try await check(
                "search_panes",
                .object(["pattern": .string("nothing-matches-this")]),
                on: tools
            )
            try await check(
                "read_format",
                .object(["template": .string("#{pid}")]),
                on: tools
            )
            // The nullable branch: a target that has gone answers null, and a
            // schema that only allowed a string would make that a violation.
            try await check(
                "read_format",
                .object([
                    "template": .string("#{pane_tty}"), "target": .string("%999"),
                ]),
                on: tools
            )
        }
    }

    @Test("what the waiting tools answer is what they advertise")
    func waitingToolsConform() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, waitCeiling: .seconds(2))
            let pane = try #require(try await server.panes().first)

            try await check(
                "wait_for_output",
                .object([
                    "pane": .string(pane.id),
                    "patterns": .array([.string("never-arrives")]),
                    "require_fresh": .bool(true),
                    "timeout": .number(1),
                ]),
                on: tools
            )
            try await check(
                "watch_format",
                .object([
                    "pane": .string(pane.id),
                    "format": .string("#{pane_dead}"),
                    "matching": .string("never-matches"),
                    "timeout": .number(1),
                ]),
                on: tools
            )
            try await check(
                "wait_for_channel",
                .object(["channel": .string("never-signalled"), "timeout": .number(1)]),
                on: tools
            )
            try await check(
                "signal_channel",
                .object(["channel": .string("spent")]),
                on: tools
            )
        }
    }

    @Test("what the changing tools answer is what they advertise")
    func changingToolsConform() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .destructive, caller: nil)
            let pane = try #require(try await server.panes().first)

            try await check(
                "send_keys",
                .object(["pane": .string(pane.id), "keys": .array([.string("Escape")])]),
                on: tools
            )
            try await check(
                "run_shell",
                .object([
                    "pane": .string(pane.id),
                    "command": .string("printf 'schema\\n'"),
                    "timeout": .number(20),
                ]),
                on: tools
            )
            try await check(
                "run_command",
                .object([
                    "command": .string("has-session"),
                    "arguments": .array([.string("-t"), .string("absent")]),
                ]),
                on: tools
            )
            try await check(
                "run_commands",
                .object([
                    "commands": .array([.object(["command": .string("list-sessions")])])
                ]),
                on: tools
            )
            try await check(
                "set_option",
                .object([
                    "name": .string("@schema"), "value": .string("yes"),
                    "scope": .string("server"),
                ]),
                on: tools
            )

            let extra = try await server.split(pane)
            try await check("kill_pane", .object(["pane": .string(extra.id)]), on: tools)
        }
    }

    @Test("a declared schema describes an object, as the protocol requires")
    func schemasDescribeObjects() {
        for definition in TmuxTools.definitions {
            guard let schema = definition.outputSchema else { continue }
            #expect(
                schema["type"]?.stringValue == "object",
                "\(definition.name) advertises a non-object result"
            )
            #expect(schema["properties"]?.objectValue?.isEmpty == false)
        }
    }

    @Test("the tools that answer a fixed shape all declare it")
    func fixedShapeToolsDeclareASchema() {
        // Left undeclared on purpose, and named so that adding a tool without a
        // schema is a decision rather than an oversight.
        let exempt: Set<String> = [
            // Its shape is the filter vocabulary, which is versioned and
            // described by its own schemaVersion field.
            "describe_filters",
            // Answers whatever tmux objects it made, which differ per plan.
            "apply_workspace",
            // The whole hierarchy, described by the library's own types.
            "snapshot",
            // Creations answer the object they made.
            "new_session", "new_window", "split_pane",
        ]
        for definition in TmuxTools.definitions where !exempt.contains(definition.name) {
            #expect(
                definition.outputSchema != nil,
                "\(definition.name) answers a fixed shape but does not say so"
            )
        }
    }
}
