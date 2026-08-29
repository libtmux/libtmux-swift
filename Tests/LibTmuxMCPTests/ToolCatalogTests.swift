import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

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
                if argument.kind == .stringArray || argument.kind == .commandArray {
                    #expect(member?["items"] != nil)
                }
                if argument.kind == .commandArray {
                    #expect(member?["items"]?["type"]?.stringValue == "object")
                    #expect(
                        member?["items"]?["required"]?.arrayValue?.contains(.string("command"))
                            == true
                    )
                }
            }
        }
    }

    @Test("numeric limits agree between schemas and argument readers")
    func numericLimitsAreEnforced() throws {
        let definition = try #require(TmuxTools.byName["capture_pane"])
        let schema = definition.inputSchema["properties"]?["max_lines"]
        #expect(schema?["minimum"]?.doubleValue == 1)
        #expect(schema?["maximum"]?.doubleValue == 2_000)

        let call = ToolCall(
            name: "capture_pane",
            arguments: .object(["pane": .string("pane-ref"), "max_lines": .number(2_001)])
        )
        let arguments = try Arguments(call, for: definition)
        #expect(throws: ToolError.self) {
            try arguments.integer("max_lines", or: 200)
        }
    }

    @Test("pattern list limits agree between schemas and argument readers")
    func patternListLimitsAreEnforced() throws {
        let definition = try #require(TmuxTools.byName["wait_for_output"])
        let schema = definition.inputSchema["properties"]?["patterns"]
        #expect(
            schema?["maxItems"]?.intValue == ToolPattern.maximumListCount
        )
        let values = Array(
            repeating: JSONValue.string("ready"),
            count: ToolPattern.maximumListCount + 1
        )
        let arguments = try Arguments(
            ToolCall(
                name: "wait_for_output",
                arguments: .object(["pane": .string("pane-ref"), "patterns": .array(values)])
            ),
            for: definition
        )

        #expect(throws: ToolError.self) { try arguments.strings("patterns") }
    }

    @Test("integer arguments reject fractions and values outside Int")
    func integerArgumentsMustFitExactly() throws {
        let definition = try #require(TmuxTools.byName["capture_pane"])
        for value in [1.5, 1e300] {
            let arguments = try Arguments(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object([
                        "pane": .string("pane-ref"), "max_lines": .number(value),
                    ])
                ),
                for: definition
            )
            #expect(
                throws: ToolError.wrongArgumentType(
                    "max_lines", expected: "a whole number"
                )
            ) {
                try arguments.integer("max_lines", or: 200)
            }
        }
    }

    @Test("timeout arguments reject nonfinite numbers")
    func timeoutArgumentsMustBeFinite() throws {
        let definition = try #require(TmuxTools.byName["run_shell"])
        for value in [Double.nan, .infinity, -.infinity] {
            let call = ToolCall(
                name: "run_shell",
                arguments: .object([
                    "pane": .string("pane-ref"),
                    "command": .string("true"),
                    "timeout": .number(value),
                ])
            )
            let arguments = try Arguments(call, for: definition)
            #expect(throws: ToolError.self) {
                try arguments.seconds("timeout", or: 30)
            }
        }
    }

    @Test("read-only hints match the authorization tier")
    func readOnlyAnnotationsMatchTiers() {
        for definition in TmuxTools.definitions {
            let annotations = definition.annotations
            #expect(
                annotations["readOnlyHint"]?.boolValue == (definition.tier == .readonly)
            )
        }
    }

    @Test("destructive hints describe effects, not authorization tiers")
    func destructiveAnnotationsDescribeEffects() throws {
        let expected = [
            "run_shell": true,
            "send_keys": true,
            "apply_workspace": true,
            "respawn_pane": true,
            "new_session": false,
            "new_window": false,
            "split_pane": false,
            "capture_pane": false,
        ]
        for (name, isDestructive) in expected {
            let definition = try #require(TmuxTools.byName[name])
            #expect(
                definition.annotations["destructiveHint"]?.boolValue == isDestructive,
                "\(name)"
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
        let fractional = Instructions.required(
            tier: .mutating,
            waitCeiling: .milliseconds(1_250)
        ).joined(separator: "\n\n")
        #expect(fractional.contains("1.25s"))
    }

    private static func sample(for argument: ToolArgument) -> JSONValue {
        if let first = argument.allowed.first { return .string(first) }
        switch argument.kind {
        case .string: return .string("%0")
        case .integer, .number: return .number(1)
        case .boolean: return .bool(false)
        case .stringArray: return .array([.string("x")])
        case .commandArray: return .array([.object(["command": .string("list-sessions")])])
        case .object: return .object([:])
        }
    }
}
