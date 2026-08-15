import Foundation
import Testing

@testable import KeyPathBakeoff

private enum LedgerFixtureError: Error {
    case malformed(String)
}

private indirect enum JSONValue: Decodable, Equatable, Sendable {
    case array([JSONValue])
    case boolean(Bool)
    case null
    case number(Int)
    case object([String: JSONValue])
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

private struct LedgerDocument: Decodable {
    let documentKind: String
    let schemaVersion: Int
    let entries: [LedgerEntry]
}

private struct LedgerEntry: Decodable {
    let contractId: String
    let defaultValue: String?
    let expectedOutcome: JSONValue?
    let inputRows: [[String: JSONValue]]
    let query: [String: JSONValue]
    let expectedMatchIds: [String]?
}

private struct LedgerRecord: Equatable, QueryRecord, Sendable {
    static let queryModel = LedgerSchema.model
    let id: String
    let querySnapshot: QuerySnapshot
}

private enum LedgerSchema {
    static let model = ModelID(rawValue: "parity.fixture.model.001")
    static let food = RelationID(rawValue: "parity.fixture.relation.001")
    static let panes = RelationID(rawValue: "parity.fixture.relation.002")
    static let session = RelationID(rawValue: "parity.fixture.relation.003")

    static let fields: [String: FieldID] = [
        "active": FieldID(rawValue: "parity.fixture.field.001"),
        "breakfast": FieldID(rawValue: "parity.fixture.field.002"),
        "city": FieldID(rawValue: "parity.fixture.field.003"),
        "command": FieldID(rawValue: "parity.fixture.field.004"),
        "missing": FieldID(rawValue: "parity.fixture.field.005"),
        "name": FieldID(rawValue: "parity.fixture.field.006"),
        "state": FieldID(rawValue: "parity.fixture.field.007"),
    ]

    static func descriptor(_ name: String) throws -> FieldDescriptor<LedgerRecord, String> {
        guard let field = fields[name] else { throw LedgerFixtureError.malformed(name) }
        return FieldDescriptor(model: model, field: field)
    }

    static let foodDescriptor = ToOneRelationDescriptor<LedgerRecord, LedgerRecord>(
        model: model,
        relation: food
    )
    static let panesDescriptor = ToManyRelationDescriptor<LedgerRecord, LedgerRecord>(
        model: model,
        relation: panes
    )
    static let sessionDescriptor = ToOneRelationDescriptor<LedgerRecord, LedgerRecord>(
        model: model,
        relation: session
    )
}

@Suite("frozen Python query differential")
struct DifferentialTests {
    @Test("all 25 frozen ledger rows normalize into typed snapshots")
    func frozenLedger() throws {
        let document = try loadLedger()
        #expect(document.documentKind == "libtmux.python-query-contracts")
        #expect(document.schemaVersion == 1)
        #expect(document.entries.count == 25)
        #expect(Set(document.entries.map(\.contractId)) == expectedContractIDs)

        for entry in document.entries {
            let records = try entry.inputRows.map(normalize)
            let expression = try ledgerExpression(entry.query)
            let matches = try records.filter { try expression.matches($0) }
            if let expected = entry.expectedMatchIds {
                #expect(matches.map(\.id) == expected, "contract: \(entry.contractId)")
            }
            try assertCardinality(entry, records: records, matches: matches)
        }
    }

    @Test("local adaptations cover null equality and logical negation")
    func localAdaptations() throws {
        let nullTitle = try FilterExpr<Pane>.where(\.alternateTitle, .eq(nil))
        let logs = try FilterExpr<Pane>.where(\.title, .contains("logs"))
        let notLogs = FilterExpr<Pane>.not(logs)

        #expect(try nullTitle.matches(Pane.fixture(alternateTitle: .value(nil))))
        #expect(try !nullTitle.matches(Pane.fixture(alternateTitle: .value("named"))))
        #expect(try notLogs.matches(Pane.fixture(title: .value("shell"))))
        #expect(try !notLogs.matches(Pane.fixture(title: .value("logs"))))
    }

    @Test("evaluation-only roots retain explicit model identity")
    func explicitRootIdentity() throws {
        let field = try LedgerSchema.descriptor("command")
        let expression = TypedDescriptorLowering.where(field, .eq("nvim"))
        let record = LedgerRecord(
            id: "a",
            querySnapshot: .record(
                model: LedgerSchema.model,
                fields: [field.field: .value(.string("nvim"))],
                relations: [:]
            )
        )

        #expect(try expression.matches(record))
    }

    @Test("cardinality helpers expose exact typed errors")
    func typedCardinalityErrors() {
        let requireExactlyOne: ([LedgerRecord]) throws(CardinalityError) -> LedgerRecord =
            exactlyOne
        let allowNoMatch: ([LedgerRecord]) throws(MultipleMatchesError) -> LedgerRecord? =
            oneOrNil

        _ = requireExactlyOne
        _ = allowNoMatch
    }
}

private func loadLedger() throws -> LedgerDocument {
    let swiftDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(
        contentsOf: swiftDirectory.appending(path: "Parity/python-query-contracts.json"))
    return try JSONDecoder().decode(LedgerDocument.self, from: data)
}

private func normalize(_ row: [String: JSONValue]) throws -> LedgerRecord {
    guard case let .string(id)? = row["id"] else {
        throw LedgerFixtureError.malformed("id")
    }
    let fields = Dictionary(
        uniqueKeysWithValues: LedgerSchema.fields.map { name, field in
            (field, projectedLiteral(row[name]))
        })
    let food = try normalizedToOne(row["food"])
    let panes = try normalizedToMany(row["panes"])
    let session = try normalizedToOne(row["session"])
    return LedgerRecord(
        id: id,
        querySnapshot: .record(
            model: LedgerSchema.model,
            fields: fields,
            relations: [
                LedgerSchema.food: .one(food),
                LedgerSchema.panes: .many(panes),
                LedgerSchema.session: .one(session),
            ]
        )
    )
}

private func normalizedToOne(_ value: JSONValue?) throws -> QuerySnapshot? {
    guard let value else { return nil }
    switch value {
    case .null:
        return nil
    case let .object(row):
        let fields = Dictionary(
            uniqueKeysWithValues: LedgerSchema.fields.map { name, field in
                (field, projectedLiteral(row[name]))
            })
        return .record(model: LedgerSchema.model, fields: fields, relations: [:])
    default:
        throw LedgerFixtureError.malformed("to-one relation")
    }
}

private func normalizedToMany(_ value: JSONValue?) throws -> [QuerySnapshot] {
    guard let value else { return [] }
    guard case let .array(values) = value else {
        throw LedgerFixtureError.malformed("to-many relation")
    }
    return try values.map { value in
        guard case let .object(row) = value else {
            throw LedgerFixtureError.malformed("to-many row")
        }
        let fields = Dictionary(
            uniqueKeysWithValues: LedgerSchema.fields.map { name, field in
                (field, projectedLiteral(row[name]))
            })
        return .record(model: LedgerSchema.model, fields: fields, relations: [:])
    }
}

private func projectedLiteral(_ value: JSONValue?) -> ProjectedLiteral {
    switch value {
    case let .some(.string(value)): .value(.string(value))
    case let .some(.number(value)): .value(.integer(value))
    case let .some(.boolean(value)): .value(.boolean(value))
    case .some(.null), .none, .some(.array(_)), .some(.object(_)): .value(.null)
    }
}

private func ledgerExpression(
    _ query: [String: JSONValue]
) throws -> FilterExpr<LedgerRecord> {
    let expressions = try query.keys.sorted().map { key -> FilterExpr<LedgerRecord> in
        guard let value = query[key] else { throw LedgerFixtureError.malformed(key) }
        switch key {
        case "panes":
            return try toManyExpression(value)
        case "session":
            return try toOneExpression(value, descriptor: LedgerSchema.sessionDescriptor)
        case "food__breakfast":
            let nested = TypedDescriptorLowering.where(
                try LedgerSchema.descriptor("breakfast"),
                .eq(try string(value))
            )
            return TypedDescriptorLowering.where(LedgerSchema.foodDescriptor, .is(nested))
        default:
            return try scalarExpression(key: key, value: value)
        }
    }
    return FilterExpr<LedgerRecord>.all(expressions)
}

private func scalarExpression(
    key: String,
    value: JSONValue
) throws -> FilterExpr<LedgerRecord> {
    let components = key.split(separator: "__", omittingEmptySubsequences: false).map(String.init)
    let field = try LedgerSchema.descriptor(components[0])
    let lookup = components.count == 1 ? "eq" : components[1]
    let operation: FilterOperator<String>
    switch lookup {
    case "contains": operation = .contains(try string(value))
    case "endswith": operation = .endsWith(try string(value))
    case "eq", "exact": operation = .eq(try string(value))
    case "icontains": operation = .icontains(try string(value))
    case "iendswith": operation = .iendsWith(try string(value))
    case "iexact": operation = .iexact(try string(value))
    case "in": operation = .in(try strings(value))
    case "iregex":
        operation = .regex(
            try #require(RegexV1(pattern: try string(value), flags: [.caseInsensitive]))
        )
    case "istartswith": operation = .istartsWith(try string(value))
    case "nin": operation = .nin(try strings(value))
    case "regex":
        operation = .regex(try #require(RegexV1(pattern: try string(value), flags: [])))
    case "startswith": operation = .startsWith(try string(value))
    default: throw LedgerFixtureError.malformed(lookup)
    }
    return TypedDescriptorLowering.where(field, operation)
}

private func toManyExpression(_ value: JSONValue) throws -> FilterExpr<LedgerRecord> {
    guard case let .object(quantifiers) = value, quantifiers.count == 1,
        let quantifier = quantifiers.keys.first, let nestedValue = quantifiers[quantifier],
        case let .object(nestedQuery) = nestedValue
    else {
        throw LedgerFixtureError.malformed("to-many query")
    }
    let nested = try ledgerExpression(nestedQuery)
    let operation: ToManyFilterOperator<LedgerRecord>
    switch quantifier {
    case "some": operation = .some(nested)
    case "every": operation = .every(nested)
    case "none": operation = .none(nested)
    default: throw LedgerFixtureError.malformed(quantifier)
    }
    return TypedDescriptorLowering.where(LedgerSchema.panesDescriptor, operation)
}

private func toOneExpression(
    _ value: JSONValue,
    descriptor: ToOneRelationDescriptor<LedgerRecord, LedgerRecord>
) throws -> FilterExpr<LedgerRecord> {
    guard case let .object(quantifiers) = value,
        case let .object(nestedQuery)? = quantifiers["is"]
    else {
        throw LedgerFixtureError.malformed("to-one query")
    }
    return TypedDescriptorLowering.where(descriptor, .is(try ledgerExpression(nestedQuery)))
}

private func string(_ value: JSONValue) throws -> String {
    guard case let .string(value) = value else {
        throw LedgerFixtureError.malformed("string")
    }
    return value
}

private func strings(_ value: JSONValue) throws -> [String] {
    guard case let .array(values) = value else {
        throw LedgerFixtureError.malformed("strings")
    }
    return try values.map(string)
}

private func assertCardinality(
    _ entry: LedgerEntry,
    records: [LedgerRecord],
    matches: [LedgerRecord]
) throws {
    switch entry.contractId {
    case "python-get-ambiguity":
        #expect(
            entry.expectedOutcome
                == .object(["kind": .string("error"), "name": .string("MultipleObjectsReturned")]))
        #expect(throws: CardinalityError.multipleMatches(2)) {
            try exactlyOne(matches)
        }
    case "swift-exactly-one-outcomes":
        #expect(
            entry.expectedOutcome
                == .object([
                    "multiple": .string("CardinalityError.multipleMatches"),
                    "none": .string("CardinalityError.noMatch"),
                    "one": .string("value"),
                ])
        )
        #expect(throws: CardinalityError.multipleMatches(2)) {
            try exactlyOne(matches)
        }
        #expect(throws: CardinalityError.noMatch) {
            try exactlyOne([LedgerRecord]())
        }
        #expect(try exactlyOne(Array(matches.prefix(1))).id == "a")
    case "python-get-default":
        #expect(entry.defaultValue == "fallback")
        #expect(
            entry.expectedOutcome
                == .object(["kind": .string("value"), "value": .string("fallback")]))
        #expect((try oneOrNil(matches)?.id) ?? entry.defaultValue == "fallback")
    case "python-get-no-match":
        #expect(
            entry.expectedOutcome
                == .object(["kind": .string("error"), "name": .string("ObjectDoesNotExist")]))
        #expect(try oneOrNil(matches) == nil)
    case "swift-one-or-nil-outcomes":
        #expect(
            entry.expectedOutcome
                == .object([
                    "multiple": .string("MultipleMatchesError"),
                    "none": .null,
                    "one": .string("value"),
                ])
        )
        #expect(throws: MultipleMatchesError(count: 2)) {
            try oneOrNil(matches)
        }
        #expect(try oneOrNil([LedgerRecord]()) == nil)
        #expect(try oneOrNil(Array(records.prefix(1)))?.id == "a")
    default:
        break
    }
}

private let expectedContractIDs: Set<String> = [
    "all-predicates-must-match",
    "contains-string",
    "endswith-string",
    "eq-scalar",
    "exact-alias",
    "icontains-fixed-unicode-lowercase",
    "iendswith-fixed-unicode-lowercase",
    "iexact-fixed-unicode-lowercase",
    "in-membership",
    "iregex-subset-search",
    "istartswith-fixed-unicode-lowercase",
    "missing-path-no-match",
    "nested-path",
    "nin-membership",
    "python-get-ambiguity",
    "python-get-default",
    "python-get-no-match",
    "regex-subset-search",
    "relation-every-empty-is-true",
    "relation-is",
    "relation-none",
    "relation-some",
    "startswith-string",
    "swift-exactly-one-outcomes",
    "swift-one-or-nil-outcomes",
]
