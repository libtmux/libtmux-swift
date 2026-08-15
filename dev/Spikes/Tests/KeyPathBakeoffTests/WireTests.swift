import Foundation
import Testing

@testable import KeyPathBakeoff

private let canonicalExpressionJSON = Data(
    #"""
    {
      "documentKind": "libtmux.filter-expression",
      "schemaVersion": 1,
      "model": "tmux.model.001",
      "expression": {
        "kind": "all",
        "expressions": [
          {
            "kind": "predicate",
            "model": "tmux.model.001",
            "field": "tmux.model.001.field.001",
            "operator": {
              "tag": "in",
              "values": [
                {"type": "string", "value": "nvim"},
                {"type": "string", "value": "vim"}
              ]
            }
          },
          {
            "kind": "not",
            "expression": {
              "kind": "predicate",
              "model": "tmux.model.001",
              "field": "tmux.model.001.field.002",
              "operator": {
                "tag": "contains",
                "value": {"type": "string", "value": "debug"}
              }
            }
          }
        ]
      }
    }
    """#.utf8
)

@Suite("query wire format")
struct WireTests {
    @Test("hand-authored versioned JSON decodes and re-encodes canonically")
    func handAuthoredWireRoundTrip() throws {
        let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: canonicalExpressionJSON)
        let command = try FilterExpr<Pane>.where(\.command, .in(["nvim", "vim"]))
        let title = try FilterExpr<Pane>.where(\.title, .contains("debug"))
        let expected = FilterExpr<Pane>.all([command, .not(title)])

        #expect(decoded == expected)
        let encoded = try JSONEncoder().encode(decoded)
        #expect(try jsonObjectsEqual(encoded, canonicalExpressionJSON))
    }

    @Test("relations encode stable IDs and all explicit quantifiers")
    func relationWireValue() throws {
        let session = try FilterExpr<PaneSession>.where(\.name, .eq("work"))
        let child = try FilterExpr<RelatedPane>.where(\.command, .eq("nvim"))
        let expressions = [
            try FilterExpr<Pane>.where(\.session, .is(session)),
            try FilterExpr<Pane>.where(\.relatedPanes, .some(child)),
            try FilterExpr<Pane>.where(\.relatedPanes, .every(child)),
            try FilterExpr<Pane>.where(\.relatedPanes, .none(child)),
        ]
        let expected: [(String, String)] = [
            ("tmux.model.001.relation.001", "is"),
            ("tmux.model.001.relation.002", "some"),
            ("tmux.model.001.relation.002", "every"),
            ("tmux.model.001.relation.002", "none"),
        ]

        for (expression, expectedWire) in zip(expressions, expected) {
            let object = try #require(
                try jsonObject(JSONEncoder().encode(expression)) as? [String: Any]
            )
            let node = try #require(object["expression"] as? [String: Any])
            #expect(node["kind"] as? String == "relation")
            #expect(node["relation"] as? String == expectedWire.0)
            #expect(node["quantifier"] as? String == expectedWire.1)
        }
    }

    @Test("unknown schema versions are rejected")
    func unknownVersion() {
        let data = replacing(
            in: canonicalExpressionJSON, "\"schemaVersion\": 1", with: "\"schemaVersion\": 99")
        #expect(throws: QueryWireError.unsupportedSchemaVersion(99)) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
        }
    }

    @Test("unknown additive document members are ignored and dropped")
    func unknownMember() throws {
        let data = replacing(
            in: canonicalExpressionJSON,
            "\"schemaVersion\": 1,",
            with: "\"schemaVersion\": 1, \"futureMember\": true,"
        )
        let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
        let canonical = try JSONDecoder().decode(
            FilterExpr<Pane>.self, from: canonicalExpressionJSON)
        #expect(decoded == canonical)
        let reencoded = try #require(
            try jsonObject(JSONEncoder().encode(decoded)) as? [String: Any]
        )
        #expect(reencoded["futureMember"] == nil)

        let nested = replacing(
            in: data,
            "\"kind\": \"all\",",
            with: "\"kind\": \"all\", \"futureNode\": true,"
        )
        let nestedAndOperator = replacing(
            in: nested,
            "\"tag\": \"contains\",",
            with: "\"tag\": \"contains\", \"futureOperator\": true,"
        )
        let nestedDecoded = try JSONDecoder().decode(
            FilterExpr<Pane>.self,
            from: nestedAndOperator
        )
        #expect(nestedDecoded == canonical)
        let normalized = String(
            decoding: try JSONEncoder().encode(nestedDecoded),
            as: UTF8.self
        )
        #expect(!normalized.contains("futureNode"))
        #expect(!normalized.contains("futureOperator"))
    }

    @Test("unknown operator tags are rejected")
    func unknownOperatorTag() {
        let data = replacing(in: canonicalExpressionJSON, "\"contains\"", with: "\"future\"")
        #expect(throws: QueryWireError.unknownOperator("future")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
        }
    }

    @Test("wrong document kind is rejected")
    func wrongDocumentKind() {
        let data = replacing(
            in: canonicalExpressionJSON,
            "libtmux.filter-expression",
            with: "libtmux.future-expression"
        )
        #expect(throws: QueryWireError.unsupportedDocumentKind("libtmux.future-expression")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: data)
        }
    }

    @Test("unknown root, field, and relation IDs are rejected")
    func unknownStableIDs() throws {
        let wrongRoot = replacing(
            in: canonicalExpressionJSON,
            "\"model\": \"tmux.model.001\"",
            with: "\"model\": \"tmux.model.999\""
        )
        #expect(throws: QueryWireError.unknownModel("tmux.model.999")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongRoot)
        }

        let mismatchedRoot = replacing(
            in: canonicalExpressionJSON,
            "\"model\": \"tmux.model.001\"",
            with: "\"model\": \"tmux.model.002\"",
            count: 1
        )
        #expect(
            throws: QueryWireError.rootModelMismatch(
                expected: "tmux.model.001",
                actual: "tmux.model.002"
            )
        ) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: mismatchedRoot)
        }

        let wrongField = replacing(
            in: canonicalExpressionJSON,
            "tmux.model.001.field.001",
            with: "tmux.model.001.field.999"
        )
        #expect(throws: QueryWireError.unknownField("tmux.model.001.field.999")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongField)
        }

        let nested = try FilterExpr<PaneSession>.where(\.name, .eq("work"))
        let relation = try FilterExpr<Pane>.where(\.session, .is(nested))
        let wrongRelation = replacing(
            in: try JSONEncoder().encode(relation),
            "tmux.model.001.relation.001",
            with: "tmux.model.001.relation.999"
        )
        #expect(throws: QueryWireError.unknownRelation("tmux.model.001.relation.999")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongRelation)
        }
    }

    @Test("known IDs cannot cross model boundaries")
    func crossModelStableIDs() throws {
        let wrongField = replacing(
            in: canonicalExpressionJSON,
            "tmux.model.001.field.001",
            with: "tmux.model.002.field.001"
        )
        #expect(throws: QueryWireError.unknownField("tmux.model.002.field.001")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongField)
        }

        let nested = try FilterExpr<PaneSession>.where(\.name, .eq("work"))
        let relation = try FilterExpr<Pane>.where(\.session, .is(nested))
        let wrongNestedField = replacing(
            in: try JSONEncoder().encode(relation),
            "tmux.model.002.field.001",
            with: "tmux.model.003.field.001"
        )
        #expect(throws: QueryWireError.unknownField("tmux.model.003.field.001")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongNestedField)
        }
    }

    @Test("operator literals and relation cardinality remain schema typed")
    func schemaTypedNodes() throws {
        let wrongLiteral = replacing(
            in: canonicalExpressionJSON,
            #"{"type": "string", "value": "debug"}"#,
            with: #"{"type": "integer", "value": 8}"#
        )
        #expect(throws: QueryWireError.invalidLiteral("operator/value type mismatch")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongLiteral)
        }

        let nested = try FilterExpr<PaneSession>.where(\.name, .eq("work"))
        let relation = try FilterExpr<Pane>.where(\.session, .is(nested))
        let wrongCardinality = replacing(
            in: try JSONEncoder().encode(relation),
            #""quantifier":"is""#,
            with: #""quantifier":"some""#
        )
        #expect(
            throws: QueryWireError.invalidRelationQuantifier(
                relation: RelationID.paneSession.rawValue,
                quantifier: "some"
            )
        ) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongCardinality)
        }

        let unknownQuantifier = replacing(
            in: try JSONEncoder().encode(relation),
            #""quantifier":"is""#,
            with: #""quantifier":"future""#
        )
        #expect(throws: QueryWireError.unknownQuantifier("future")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: unknownQuantifier)
        }
    }

    @Test("known schema members cannot move across typed positions")
    func isolatedSchemaMutations() throws {
        let session = try FilterExpr<PaneSession>.where(\.name, .eq("work"))
        let relation = try FilterExpr<Pane>.where(\.session, .is(session))
        var wrongTarget = try expressionObject(relation)
        var relationNode = try #require(wrongTarget["expression"] as? [String: Any])
        var nestedNode = try #require(relationNode["expression"] as? [String: Any])
        nestedNode["model"] = ModelID.relatedPane.rawValue
        nestedNode["field"] = FieldID.relatedPaneCommand.rawValue
        relationNode["expression"] = nestedNode
        wrongTarget["expression"] = relationNode
        #expect(
            throws: QueryWireError.rootModelMismatch(
                expected: ModelID.paneSession.rawValue,
                actual: ModelID.relatedPane.rawValue
            )
        ) {
            try JSONDecoder().decode(
                FilterExpr<Pane>.self,
                from: JSONSerialization.data(withJSONObject: wrongTarget)
            )
        }

        let wrongFieldOperator = replacing(
            in: canonicalExpressionJSON,
            FieldID.paneTitle.rawValue,
            with: FieldID.paneWidth.rawValue
        )
        #expect(throws: QueryWireError.invalidLiteral("operator/value type mismatch")) {
            try JSONDecoder().decode(FilterExpr<Pane>.self, from: wrongFieldOperator)
        }

        var wrongRelationModel = try expressionObject(relation)
        var wrongRelationNode = try #require(
            wrongRelationModel["expression"] as? [String: Any]
        )
        wrongRelationNode["model"] = ModelID.paneSession.rawValue
        wrongRelationModel["expression"] = wrongRelationNode
        #expect(
            throws: QueryWireError.rootModelMismatch(
                expected: ModelID.pane.rawValue,
                actual: ModelID.paneSession.rawValue
            )
        ) {
            try JSONDecoder().decode(
                FilterExpr<Pane>.self,
                from: JSONSerialization.data(withJSONObject: wrongRelationModel)
            )
        }
    }

    @Test("empty conjunctions encode their explicit generic root")
    func emptyConjunctionRoot() throws {
        let empty = FilterExpr<RelatedPane>.all([])
        let object = try #require(
            try jsonObject(JSONEncoder().encode(empty)) as? [String: Any]
        )
        #expect(object["model"] as? String == ModelID.relatedPane.rawValue)
        #expect(
            try JSONDecoder().decode(
                FilterExpr<RelatedPane>.self, from: JSONEncoder().encode(empty)) == empty)
    }

    @Test("exact decodes as the canonical eq operator")
    func exactDecodeAlias() throws {
        let exactJSON = Data(
            #"""
            {
              "documentKind": "libtmux.filter-expression",
              "schemaVersion": 1,
              "model": "tmux.model.001",
              "expression": {
                "kind": "predicate",
                "model": "tmux.model.001",
                "field": "tmux.model.001.field.002",
                "operator": {
                  "tag": "exact",
                  "value": {"type": "string", "value": "logs"}
                }
              }
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(FilterExpr<Pane>.self, from: exactJSON)
        let object = try #require(
            try jsonObject(JSONEncoder().encode(decoded)) as? [String: Any]
        )
        let expression = try #require(object["expression"] as? [String: Any])
        let operation = try #require(expression["operator"] as? [String: Any])
        #expect(operation["tag"] as? String == "eq")
    }

    @Test("regex wire data includes its dialect and explicit flags")
    func regexWireValue() throws {
        let expression = try FilterExpr<Pane>.where(
            \.title,
            .regex(try #require(RegexV1(pattern: "^app.*", flags: [.caseInsensitive])))
        )
        let object = try #require(
            try jsonObject(JSONEncoder().encode(expression)) as? [String: Any]
        )
        let node = try #require(object["expression"] as? [String: Any])
        let operation = try #require(node["operator"] as? [String: Any])
        let regex = try #require(operation["regex"] as? [String: Any])
        #expect(regex["dialect"] as? String == "libtmux-regex-v1")
        #expect(regex["pattern"] as? String == "^app.*")
        #expect(regex["flags"] as? [String] == ["caseInsensitive"])

        var unknownFlag = object
        var unknownNode = try #require(unknownFlag["expression"] as? [String: Any])
        var unknownOperation = try #require(unknownNode["operator"] as? [String: Any])
        var unknownRegex = try #require(unknownOperation["regex"] as? [String: Any])
        unknownRegex["flags"] = ["future"]
        unknownOperation["regex"] = unknownRegex
        unknownNode["operator"] = unknownOperation
        unknownFlag["expression"] = unknownNode
        #expect(throws: QueryWireError.unknownRegexFlag("future")) {
            try JSONDecoder().decode(
                FilterExpr<Pane>.self,
                from: JSONSerialization.data(withJSONObject: unknownFlag)
            )
        }
    }
}

private func jsonObject(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data)
}

private func jsonObjectsEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
    let lhsObject = try #require(try jsonObject(lhs) as? NSDictionary)
    let rhsObject = try #require(try jsonObject(rhs) as? NSDictionary)
    return lhsObject.isEqual(rhsObject)
}

private func expressionObject<Root: WireQueryRoot>(
    _ expression: FilterExpr<Root>
) throws -> [String: Any] {
    try #require(
        try jsonObject(JSONEncoder().encode(expression)) as? [String: Any]
    )
}

private func replacing(
    in data: Data,
    _ old: String,
    with new: String,
    count: Int = .max
) -> Data {
    let source = String(decoding: data, as: UTF8.self)
    guard count != .max else {
        return Data(source.replacingOccurrences(of: old, with: new).utf8)
    }
    var result = source
    for _ in 0..<count {
        guard let range = result.range(of: old) else { break }
        result.replaceSubrange(range, with: new)
    }
    return Data(result.utf8)
}
