import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// Every advertised tool is called against a real tmux and answers the shape it
/// publishes.
///
/// `CapabilityManifestTests` next door checks the DECLARED surface: the case
/// count, toolsets, annotations, schema keys. It calls one handler. A tool can
/// therefore be advertised, documented, schema-checked and completely
/// non-functional with every other gate green -- which is how libtmux-go
/// shipped `set_mouse_enabled` writing tmux's `mouse` option at server scope,
/// where it is a session option, so every call failed.
///
/// Arguments are synthesised from each tool's own `ToolArgument` metadata
/// rather than kept in a hand-written table, so a newly-required argument
/// cannot silently go unexercised. Only identifiers that must name live tmux
/// objects, and tmux's own vocabulary, come from the fixture.
@Suite("tool surface", .timeLimit(.minutes(10)))
struct ToolSurfaceTests {
    /// Tools deliberately not driven, each with the reason it cannot be.
    ///
    /// Keep this empty of convenience: every name here is a hole in the gate.
    static let notDriven: [String: String] = [
        "call_read_tools_batch": "drives other tools by name, so whichever they are covers it"
    ]

    /// A live session, window and pane for one tool to aim at and, if it is
    /// destructive, to destroy without taking another tool's target with it.
    private struct Target {
        let session: String
        let window: String
        let pane: String
    }

    /// Values the argument metadata cannot supply: tmux vocabulary, and the
    /// one-of-several optional arguments some tools require in combination.
    private static func semanticOverrides(
        _ tool: String,
        _ target: Target
    ) -> [String: JSONValue] {
        switch tool {
        case "find_pane_by_position": ["corner": .string("top-left")]
        case "resize_pane": ["direction": .string("up")]
        case "select_layout": ["layout": .string("even-horizontal")]
        case "respawn_pane": ["killFirst": .bool(true)]
        case "get_tmux_variables": ["names": .array([.string("pane_id")])]
        case "move_window": ["index": .number(7)]
        case "resize_window": ["width": .number(40), "height": .number(12)]
        case "rename_session": ["name": .string("\(target.session)-renamed")]
        case "rename_window": ["name": .string("\(target.session)-window")]
        case "send_keys_batch":
            [
                "operations": .array([
                    .object([
                        "paneId": .string(target.pane),
                        "keys": .array([.string("true")]),
                    ])
                ])
            ]
        default: [:]
        }
    }

    private static func value(for argument: ToolArgument, target: Target) -> JSONValue {
        // Match on a contained noun, so `otherPaneId` and `destinationSessionId`
        // are still recognised as needing a live identifier.
        let name = argument.name
        let lowered = name.lowercased()
        if lowered.contains("pane") { return .string(target.pane) }
        if lowered.contains("window") { return .string(target.window) }
        if lowered.contains("session") { return .string(target.session) }
        if lowered.contains("channel") { return .string("libtmux-surface-\(target.session)") }
        if let first = argument.allowed.first { return .string(first) }

        switch argument.kind {
        case .integer, .number:
            // Anything that waits must not wait long: this drives 45 tools.
            let bounded = min(max(argument.minimum ?? 1, 1), argument.maximum ?? 1)
            return .number(name.contains("econds") || name.contains("imeout") ? 1 : bounded)
        case .boolean:
            return .bool(false)
        case .stringArray, .commandArray:
            // An empty array trips every minimumItems bound.
            return .array(
                Array(repeating: .string("true"), count: max(argument.minimumItems ?? 1, 1)))
        case .object:
            return .object([:])
        case .string:
            return .string("x")
        }
    }

    private static func arguments(for definition: ToolDefinition, target: Target) -> JSONValue {
        var object: [String: JSONValue] = [:]
        for argument in definition.arguments where argument.isRequired {
            object[argument.name] = value(for: argument, target: target)
        }
        for (key, override) in semanticOverrides(definition.name, target) {
            object[key] = override
        }
        return .object(object)
    }

    /// Report the required keys an output schema promises but the answer omits.
    private static func missingRequiredKeys(
        schema: JSONValue,
        answer: JSONValue
    ) -> [String] {
        guard case .object(let schemaObject) = schema,
            case .array(let required) = schemaObject["required"] ?? .null,
            case .object(let answered) = answer
        else { return [] }
        return required.compactMap { entry in
            guard case .string(let key) = entry else { return nil }
            return answered[key] == nil ? key : nil
        }
    }

    @Test("every advertised tool answers the schema it publishes")
    func everyAdvertisedToolAnswersTheSchemaItPublishes() async throws {
        for (name, _) in Self.notDriven {
            #expect(
                TmuxTools.byName[name] != nil,
                "\(name) is exempted but no longer advertised; drop it from notDriven"
            )
        }

        var called: Set<String> = []
        var failures: [String] = []

        try await withTmuxServer { server in
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.inspect, .manage, .execute, .teardown]),
                caller: nil
            )

            for operation in ToolOperation.allCases {
                let name = operation.rawValue
                if Self.notDriven[name] != nil { continue }
                guard let definition = TmuxTools.byName[name] else {
                    failures.append("\(name): advertised by ToolOperation but absent from byName")
                    continue
                }

                // Its own session, and two windows so the tools that move or
                // select by direction have somewhere to go.
                let sessionName = "surface-\(name)"
                _ = try await tools.call(
                    ToolCall(
                        name: "create_session",
                        arguments: .object(["name": .string(sessionName)])
                    )
                )
                _ = try await tools.call(
                    ToolCall(
                        name: "create_window",
                        arguments: .object([
                            "session": .string(sessionName), "name": .string("second"),
                        ])
                    )
                )
                let snapshot = try await server.snapshot()
                guard let session = snapshot.sessions.first(where: { $0.name == sessionName }),
                    let link = snapshot.windowLinks.first(where: { $0.sessionID == session.id }),
                    let pane = snapshot.panes.first(where: { $0.windowID == link.windowID })
                else {
                    failures.append("\(name): fixture session did not materialise")
                    continue
                }
                let target = Target(
                    session: sessionName,
                    window: link.windowID.rawValue,
                    pane: pane.id.rawValue
                )

                let arguments = Self.arguments(for: definition, target: target)
                do {
                    let outcome = try await tools.call(
                        ToolCall(name: name, arguments: arguments)
                    )
                    called.insert(name)
                    guard let schema = definition.outputSchema else { continue }
                    let missing = Self.missingRequiredKeys(
                        schema: schema, answer: outcome.structured)
                    if !missing.isEmpty {
                        failures.append(
                            "\(name): answer omits required keys \(missing) from its output schema")
                    }
                } catch {
                    failures.append("\(name): refused its own arguments \(arguments): \(error)")
                }
            }
        }

        let advertised = Set(ToolOperation.allCases.map(\.rawValue))
        let expected = advertised.subtracting(Self.notDriven.keys)
        let neverCalled = expected.subtracting(called).sorted()
        #expect(
            neverCalled.isEmpty && failures.isEmpty,
            """
            advertised but never called: \(neverCalled)

            \(failures.joined(separator: "\n"))
            """
        )
    }
}
