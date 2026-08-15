import Foundation
import Testing

@testable import KeyPathBakeoff

enum LoweringContender: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case generatedSwitch
    case erasedMap
    case typedDescriptor

    var testDescription: String { rawValue }

    func command(
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<Pane>.where(\.command, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.command, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneFields.command, operation)
        }
    }

    func width(
        _ operation: FilterOperator<Int>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<Pane>.where(\.width, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.width, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneFields.width, operation)
        }
    }

    func title(
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<Pane>.where(\.title, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.title, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneFields.title, operation)
        }
    }

    func alternateTitle(
        _ operation: FilterOperator<String?>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<Pane>.where(\.alternateTitle, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.alternateTitle, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneFields.alternateTitle, operation)
        }
    }

    func session(
        _ operation: ToOneFilterOperator<PaneSession>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<Pane>.where(\.session, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.session, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneRelations.session, operation)
        }
    }

    func children(
        _ operation: ToManyFilterOperator<RelatedPane>
    ) throws(QueryConstructionError) -> FilterExpr<Pane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<Pane>.where(\.relatedPanes, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.relatedPanes, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneRelations.relatedPanes, operation)
        }
    }

    func sessionName(
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<PaneSession> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<PaneSession>.where(\.name, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.name, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(PaneSessionFields.name, operation)
        }
    }

    func childCommand(
        _ operation: FilterOperator<String>
    ) throws(QueryConstructionError) -> FilterExpr<RelatedPane> {
        switch self {
        case .generatedSwitch:
            try FilterExpr<RelatedPane>.where(\.command, operation)
        case .erasedMap:
            try ErasedMapLowering.where(\.command, operation)
        case .typedDescriptor:
            TypedDescriptorLowering.where(RelatedPaneFields.command, operation)
        }
    }
}

private func requireSendable<Value: Sendable>(_ value: Value) {
    _ = value
}

@Suite("typed key-path lowering")
struct LoweringTests {
    @Test("qualified and concise key-path call sites lower immediately")
    func acceptedCallSites() throws {
        let qualified = try FilterExpr<Pane>.where(
            \.command,
            .in(["nvim", "vim"])
        )
        let concise: FilterExpr<Pane> = try `where`(
            \.title,
            .contains("logs")
        )

        #expect(
            qualified.node
                == .predicate(
                    model: .pane,
                    field: .paneCommand,
                    operation: .membership(
                        tag: .in,
                        values: [.string("nvim"), .string("vim")]
                    )
                )
        )
        #expect(
            concise.node
                == .predicate(
                    model: .pane,
                    field: .paneTitle,
                    operation: .scalar(tag: .contains, value: .string("logs"))
                )
        )
        requireSendable(qualified)
        requireSendable(concise)
    }

    @Test("filter expressions cross task-group boundaries as values")
    func expressionsCrossTaskGroups() async throws {
        let expression = try FilterExpr<Pane>.where(\.command, .eq("nvim"))
        let nodes = await withTaskGroup(of: FilterNode.self, returning: [FilterNode].self) {
            group in
            group.addTask { expression.node }
            group.addTask { FilterExpr<Pane>.not(expression).node }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(nodes) == Set([expression.node, .not(expression.node)]))
    }

    @Test("wire IDs are opaque and independent of Swift property names")
    func opaqueWireIDs() {
        #expect(ModelID.pane.rawValue == "tmux.model.001")
        #expect(FieldID.paneCommand.rawValue == "tmux.model.001.field.001")
        #expect(FieldID.paneTitle.rawValue == "tmux.model.001.field.002")
        #expect(FieldID.paneWidth.rawValue == "tmux.model.001.field.003")
        #expect(FieldID.paneAlternateTitle.rawValue == "tmux.model.001.field.004")
        #expect(FieldID.paneSessionName.rawValue == "tmux.model.002.field.001")
        #expect(FieldID.relatedPaneCommand.rawValue == "tmux.model.003.field.001")
        #expect(RelationID.paneSession.rawValue == "tmux.model.001.relation.001")
        #expect(RelationID.paneRelatedPanes.rawValue == "tmux.model.001.relation.002")
        for rawValue in [
            FieldID.paneCommand.rawValue,
            FieldID.paneTitle.rawValue,
            FieldID.paneWidth.rawValue,
            FieldID.paneAlternateTitle.rawValue,
            FieldID.paneSessionName.rawValue,
            FieldID.relatedPaneCommand.rawValue,
            RelationID.paneSession.rawValue,
            RelationID.paneRelatedPanes.rawValue,
        ] {
            #expect(!rawValue.contains("command"))
            #expect(!rawValue.contains("title"))
            #expect(!rawValue.contains("width"))
            #expect(!rawValue.contains("session"))
            #expect(!rawValue.contains("relatedPanes"))
        }
    }

    @Test(
        "all contenders lower scalar operators identically", arguments: LoweringContender.allCases)
    func scalarLowering(_ contender: LoweringContender) throws {
        #expect(
            try contender.command(.iexact("NVIM"))
                == FilterExpr<Pane>(
                    node: .predicate(
                        model: .pane,
                        field: .paneCommand,
                        operation: .scalar(tag: .iexact, value: .string("NVIM"))
                    )
                )
        )
        #expect(
            try contender.width(.nin([80, 132]))
                == FilterExpr<Pane>(
                    node: .predicate(
                        model: .pane,
                        field: .paneWidth,
                        operation: .membership(
                            tag: .nin,
                            values: [.integer(80), .integer(132)]
                        )
                    )
                )
        )
        #expect(
            try contender.alternateTitle(.eq(nil))
                == FilterExpr<Pane>(
                    node: .predicate(
                        model: .pane,
                        field: .paneAlternateTitle,
                        operation: .scalar(tag: .eq, value: .null)
                    )
                )
        )
    }

    @Test("all contenders lower typed relations identically", arguments: LoweringContender.allCases)
    func relationLowering(_ contender: LoweringContender) throws {
        let sessionName = try contender.sessionName(.eq("work"))
        let childCommand = try contender.childCommand(.eq("nvim"))

        #expect(
            try contender.session(.is(sessionName)).node
                == .relation(
                    model: .pane,
                    relation: .paneSession,
                    quantifier: .is,
                    expression: sessionName.node
                )
        )
        #expect(
            try contender.children(.some(childCommand)).node
                == .relation(
                    model: .pane,
                    relation: .paneRelatedPanes,
                    quantifier: .some,
                    expression: childCommand.node
                )
        )
        #expect(
            try contender.children(.every(childCommand)).node
                == .relation(
                    model: .pane,
                    relation: .paneRelatedPanes,
                    quantifier: .every,
                    expression: childCommand.node
                )
        )
        #expect(
            try contender.children(.none(childCommand)).node
                == .relation(
                    model: .pane,
                    relation: .paneRelatedPanes,
                    quantifier: .none,
                    expression: childCommand.node
                )
        )
    }

    @Test(
        "all contenders preserve nested and scalar lowering through the wire",
        arguments: LoweringContender.allCases
    )
    func contenderWireRoundTrip(_ contender: LoweringContender) throws {
        let sessionName = try contender.sessionName(.eq("work"))
        let childCommand = try contender.childCommand(.eq("nvim"))
        let expression = FilterExpr<Pane>.all([
            try contender.title(.contains("logs")),
            try contender.session(.is(sessionName)),
            try contender.children(.some(childCommand)),
        ])
        let encoded = try JSONEncoder().encode(expression)
        let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: encoded)

        #expect(decoded == expression)
        #expect(
            try decoded.matches(
                Pane.fixture(
                    title: .value("logs"),
                    session: .value(PaneSession(name: .value("work"))),
                    relatedPanes: .value([RelatedPane(command: .value("nvim"))])
                )
            )
        )
    }

    @Test("conjunction and logical negation remain expression data")
    func conjunctionAndNegation() throws {
        let command = try FilterExpr<Pane>.where(\.command, .eq("nvim"))
        let title = try FilterExpr<Pane>.where(\.title, .contains("logs"))
        let expression = FilterExpr<Pane>.all([command, .not(title)])

        #expect(expression.node == .all([command.node, .not(title.node)]))
    }

    @Test("fixed lowercase uses the closed spike table without normalization")
    func fixedLowercaseAdaptation() throws {
        #expect(try FixedLowercaseV1.apply("CAFÉ") == "café")
        #expect(try FixedLowercaseV1.apply("Cafe\u{301}") == "cafe\u{301}")
        #expect(!FixedLowercaseV1.isProductionTableComplete)
        #expect(throws: FilterEvaluationError.unsupportedLowercaseScalar("Ω")) {
            try FixedLowercaseV1.apply("Ω")
        }
    }

    @Test("regex v1 is unanchored, carries flags, and rejects outside syntax")
    func regexSubsetAdaptation() throws {
        let search = try #require(RegexV1(pattern: "app", flags: []))
        let insensitive = try #require(RegexV1(pattern: "^app.*", flags: [.caseInsensitive]))

        #expect(try search.matches("red apple"))
        #expect(try insensitive.matches("APPLE"))
        #expect(RegexV1(pattern: #"v\d+-\d+$"#, flags: []) != nil)
        #expect(RegexV1(pattern: "n?vim", flags: []) != nil)
        #expect(RegexV1(pattern: "(app)", flags: []) == nil)
        #expect(RegexV1(pattern: "(?=app)", flags: []) == nil)
        #expect(RegexV1(pattern: #"(app)\1"#, flags: []) == nil)
        #expect(RegexV1(pattern: "app", flags: RegexFlags(rawValue: 2)) == nil)
    }

    @Test("missing projected relations fail distinctly from loaded nil")
    func missingProjectionIsTyped() throws {
        let nested = try FilterExpr<PaneSession>.where(\.name, .eq("work"))
        let expression = try FilterExpr<Pane>.where(\.session, .is(nested))
        let omitted = Pane.fixture(session: .missing)
        let loadedNil = Pane.fixture(session: .value(nil))

        #expect(throws: FilterEvaluationError.missingProjection(.paneSession)) {
            try expression.matches(omitted)
        }
        #expect(try !expression.matches(loadedNil))
    }
}
