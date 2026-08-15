import Foundation

package struct ModelID: Hashable, Sendable, RawRepresentable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let pane = Self(rawValue: "tmux.model.001")
    package static let paneSession = Self(rawValue: "tmux.model.002")
    package static let relatedPane = Self(rawValue: "tmux.model.003")
}

package struct FieldID: Hashable, Sendable, RawRepresentable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let paneCommand = Self(rawValue: "tmux.model.001.field.001")
    package static let paneTitle = Self(rawValue: "tmux.model.001.field.002")
    package static let paneWidth = Self(rawValue: "tmux.model.001.field.003")
    package static let paneAlternateTitle = Self(rawValue: "tmux.model.001.field.004")
    package static let paneSessionName = Self(rawValue: "tmux.model.002.field.001")
    package static let relatedPaneCommand = Self(rawValue: "tmux.model.003.field.001")
}

package struct RelationID: Hashable, Sendable, RawRepresentable {
    package let rawValue: String

    package init(rawValue: String) {
        self.rawValue = rawValue
    }

    package static let paneSession = Self(rawValue: "tmux.model.001.relation.001")
    package static let paneRelatedPanes = Self(rawValue: "tmux.model.001.relation.002")
}

package enum Projected<Value: Sendable>: Sendable {
    case missing
    case value(Value)
}

extension Projected: Equatable where Value: Equatable {}

package enum QueryLiteral: Hashable, Sendable {
    case null
    case string(String)
    case integer(Int)
    case boolean(Bool)
}

package enum OperatorTag: String, Hashable, Sendable {
    case contains
    case endsWith = "endswith"
    case eq
    case icontains
    case iendsWith = "iendswith"
    case iexact
    case `in`
    case istartsWith = "istartswith"
    case nin
    case regex
    case startsWith = "startswith"
}

package enum FilterOperation: Hashable, Sendable {
    case scalar(tag: OperatorTag, value: QueryLiteral)
    case membership(tag: OperatorTag, values: [QueryLiteral])
    case regex(tag: OperatorTag, regex: RegexV1)
}

package enum RelationQuantifier: String, Hashable, Sendable {
    case `is`
    case some
    case every
    case none
}

package indirect enum FilterNode: Hashable, Sendable {
    case predicate(model: ModelID, field: FieldID, operation: FilterOperation)
    case all([FilterNode])
    case not(FilterNode)
    case relation(
        model: ModelID,
        relation: RelationID,
        quantifier: RelationQuantifier,
        expression: FilterNode
    )
}

package protocol QueryRoot: Sendable {
    static var queryModel: ModelID { get }
}

package protocol WireQueryRoot: QueryRoot {}

package struct FilterExpr<Root: QueryRoot>: Hashable, Sendable {
    private let model: ModelID
    package let node: FilterNode

    package init(node: FilterNode) {
        model = Root.queryModel
        self.node = node
    }

    private init(model: ModelID, node: FilterNode) {
        self.model = model
        self.node = node
    }

    package static func all(_ expressions: [Self]) -> Self {
        return Self(
            model: Root.queryModel,
            node: .all(expressions.map(\.node))
        )
    }

    package static func not(_ expression: Self) -> Self {
        Self(model: expression.model, node: .not(expression.node))
    }

}

extension FilterExpr where Root: QueryRecord {
    package func matches(_ record: Root) throws -> Bool {
        try node.matches(record.querySnapshot)
    }
}

package protocol QueryLiteralConvertible: Sendable {
    var queryLiteral: QueryLiteral { get }
}

extension String: QueryLiteralConvertible {
    package var queryLiteral: QueryLiteral { .string(self) }
}

extension Int: QueryLiteralConvertible {
    package var queryLiteral: QueryLiteral { .integer(self) }
}

extension Bool: QueryLiteralConvertible {
    package var queryLiteral: QueryLiteral { .boolean(self) }
}

extension Optional: QueryLiteralConvertible where Wrapped: QueryLiteralConvertible {
    package var queryLiteral: QueryLiteral {
        switch self {
        case let .some(value): value.queryLiteral
        case .none: .null
        }
    }
}

package struct FilterOperator<Value>: Hashable, Sendable {
    package let operation: FilterOperation

    private init(_ operation: FilterOperation) {
        self.operation = operation
    }
}

extension FilterOperator where Value: QueryLiteralConvertible {
    package static func eq(_ value: Value) -> Self {
        Self(.scalar(tag: .eq, value: value.queryLiteral))
    }

    package static func `in`(_ values: [Value]) -> Self {
        Self(.membership(tag: .in, values: values.map(\.queryLiteral)))
    }

    package static func nin(_ values: [Value]) -> Self {
        Self(.membership(tag: .nin, values: values.map(\.queryLiteral)))
    }
}

extension FilterOperator where Value == String {
    package static func contains(_ value: String) -> Self {
        Self(.scalar(tag: .contains, value: .string(value)))
    }

    package static func endsWith(_ value: String) -> Self {
        Self(.scalar(tag: .endsWith, value: .string(value)))
    }

    package static func icontains(_ value: String) -> Self {
        Self(.scalar(tag: .icontains, value: .string(value)))
    }

    package static func iendsWith(_ value: String) -> Self {
        Self(.scalar(tag: .iendsWith, value: .string(value)))
    }

    package static func iexact(_ value: String) -> Self {
        Self(.scalar(tag: .iexact, value: .string(value)))
    }

    package static func istartsWith(_ value: String) -> Self {
        Self(.scalar(tag: .istartsWith, value: .string(value)))
    }

    package static func startsWith(_ value: String) -> Self {
        Self(.scalar(tag: .startsWith, value: .string(value)))
    }

    package static func regex(_ regex: RegexV1) -> Self {
        Self(.regex(tag: .regex, regex: regex))
    }
}

package struct ToOneFilterOperator<Related: QueryRoot>: Hashable, Sendable {
    package let expression: FilterNode

    private init(_ expression: FilterNode) {
        self.expression = expression
    }

    package static func `is`(_ expression: FilterExpr<Related>) -> Self {
        Self(expression.node)
    }
}

package struct ToManyFilterOperator<Related: QueryRoot>: Hashable, Sendable {
    package let quantifier: RelationQuantifier
    package let expression: FilterNode

    private init(_ quantifier: RelationQuantifier, _ expression: FilterNode) {
        self.quantifier = quantifier
        self.expression = expression
    }

    package static func some(_ expression: FilterExpr<Related>) -> Self {
        Self(.some, expression.node)
    }

    package static func every(_ expression: FilterExpr<Related>) -> Self {
        Self(.every, expression.node)
    }

    package static func none(_ expression: FilterExpr<Related>) -> Self {
        Self(.none, expression.node)
    }
}

package enum QueryConstructionError: Error, Equatable {
    case unsupportedField
    case unsupportedRelation
}

package enum FilterEvaluationError: Error, Equatable {
    case missingField(FieldID)
    case missingProjection(RelationID)
    case unsupportedLowercaseScalar(String)
    case invalidRegex(String)
}

package enum QueryWireError: Error, Equatable {
    case unsupportedDocumentKind(String)
    case unsupportedSchemaVersion(Int)
    case unknownModel(String)
    case rootModelMismatch(expected: String, actual: String)
    case unknownField(String)
    case unknownRelation(String)
    case unknownOperator(String)
    case unknownQuantifier(String)
    case invalidRelationQuantifier(relation: String, quantifier: String)
    case unknownRegexFlag(String)
    case unknownNode(String)
    case invalidLiteral(String)
    case invalidRegexDialect(String)
}

package struct RegexFlags: OptionSet, Hashable, Sendable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let caseInsensitive = Self(rawValue: 1 << 0)
}

package struct RegexV1: Hashable, Sendable {
    package static let dialect = "libtmux-regex-v1"

    package let pattern: String
    package let flags: RegexFlags

    package init?(pattern: String, flags: RegexFlags) {
        guard flags.rawValue & ~RegexFlags.caseInsensitive.rawValue == 0,
            Self.accepts(pattern)
        else { return nil }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            return nil
        }
        self.pattern = pattern
        self.flags = flags
    }

    package func matches(_ value: String) throws -> Bool {
        let options: NSRegularExpression.Options =
            flags.contains(.caseInsensitive)
            ? [.caseInsensitive]
            : []
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            throw FilterEvaluationError.invalidRegex(pattern)
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }

    private static func accepts(_ pattern: String) -> Bool {
        guard !pattern.isEmpty, !pattern.contains("("), !pattern.contains(")") else {
            return false
        }
        var escaped = false
        for character in pattern {
            if escaped {
                guard character == "d" || character == "\\" || character == "." else {
                    return false
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character.isLetter || character.isNumber
                || character == " " || character == "-" || character == "_"
                || character == "^" || character == "$" || character == "."
                || character == "*" || character == "+" || character == "?"
            {
                continue
            } else {
                return false
            }
        }
        return !escaped
    }
}

package enum FixedLowercaseV1 {
    package static let isProductionTableComplete = false

    package static func apply(_ value: String) throws -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A:
                scalars.append(UnicodeScalar(scalar.value + 0x20)!)
            case 0xC9:
                scalars.append(UnicodeScalar(0xE9)!)
            case 0x00...0x7F, 0xE9, 0x301:
                scalars.append(scalar)
            default:
                throw FilterEvaluationError.unsupportedLowercaseScalar(String(scalar))
            }
        }
        return String(scalars)
    }
}

package enum ProjectedLiteral: Equatable, Sendable {
    case missing
    case value(QueryLiteral)
}

package indirect enum ProjectedRelation: Equatable, Sendable {
    case missing
    case one(QuerySnapshot?)
    case many([QuerySnapshot])
}

package struct QuerySnapshot: Equatable, Sendable {
    package let model: ModelID
    package let fields: [FieldID: ProjectedLiteral]
    package let relations: [RelationID: ProjectedRelation]

    package static func record(
        model: ModelID,
        fields: [FieldID: ProjectedLiteral],
        relations: [RelationID: ProjectedRelation]
    ) -> Self {
        Self(model: model, fields: fields, relations: relations)
    }
}

package protocol QueryRecord: QueryRoot {
    var querySnapshot: QuerySnapshot { get }
}

package struct PaneSession: Equatable, Sendable, QueryRecord, WireQueryRoot {
    package static let queryModel = ModelID.paneSession
    package let name: Projected<String>

    package init(name: Projected<String> = .value("work")) {
        self.name = name
    }

    package var querySnapshot: QuerySnapshot {
        .record(
            model: .paneSession,
            fields: [.paneSessionName: name.projectedLiteral],
            relations: [:]
        )
    }
}

package struct RelatedPane: Equatable, Sendable, QueryRecord, WireQueryRoot {
    package static let queryModel = ModelID.relatedPane
    package let command: Projected<String>

    package init(command: Projected<String> = .value("nvim")) {
        self.command = command
    }

    package var querySnapshot: QuerySnapshot {
        .record(
            model: .relatedPane,
            fields: [.relatedPaneCommand: command.projectedLiteral],
            relations: [:]
        )
    }
}

package struct Pane: Equatable, Sendable, QueryRecord, WireQueryRoot {
    package static let queryModel = ModelID.pane
    package let command: Projected<String>
    package let title: Projected<String>
    package let width: Projected<Int>
    package let alternateTitle: Projected<String?>
    package let session: Projected<PaneSession?>
    package let relatedPanes: Projected<[RelatedPane]>

    package static func fixture(
        command: Projected<String> = .value("nvim"),
        title: Projected<String> = .value("shell"),
        width: Projected<Int> = .value(80),
        alternateTitle: Projected<String?> = .value(nil),
        session: Projected<PaneSession?> = .value(PaneSession()),
        relatedPanes: Projected<[RelatedPane]> = .value([])
    ) -> Self {
        Self(
            command: command,
            title: title,
            width: width,
            alternateTitle: alternateTitle,
            session: session,
            relatedPanes: relatedPanes
        )
    }

    package var querySnapshot: QuerySnapshot {
        .record(
            model: .pane,
            fields: [
                .paneCommand: command.projectedLiteral,
                .paneTitle: title.projectedLiteral,
                .paneWidth: width.projectedLiteral,
                .paneAlternateTitle: alternateTitle.projectedOptionalLiteral,
            ],
            relations: [
                .paneSession: session.projectedRelation,
                .paneRelatedPanes: relatedPanes.projectedRelation,
            ]
        )
    }
}

package enum CardinalityError: Error, Equatable {
    case noMatch
    case multipleMatches(Int)
}

package struct MultipleMatchesError: Error, Equatable {
    package let count: Int

    package init(count: Int) {
        self.count = count
    }
}

package func exactlyOne<Value>(_ values: [Value]) throws(CardinalityError) -> Value {
    guard let value = values.first else { throw CardinalityError.noMatch }
    guard values.count == 1 else { throw CardinalityError.multipleMatches(values.count) }
    return value
}

package func oneOrNil<Value>(_ values: [Value]) throws(MultipleMatchesError) -> Value? {
    guard values.count <= 1 else { throw MultipleMatchesError(count: values.count) }
    return values.first
}

private extension Projected where Value == String {
    var projectedLiteral: ProjectedLiteral {
        switch self {
        case .missing: .missing
        case let .value(value): .value(.string(value))
        }
    }
}

private extension Projected where Value == Int {
    var projectedLiteral: ProjectedLiteral {
        switch self {
        case .missing: .missing
        case let .value(value): .value(.integer(value))
        }
    }
}

private extension Projected where Value == String? {
    var projectedOptionalLiteral: ProjectedLiteral {
        switch self {
        case .missing: .missing
        case let .value(value): .value(value.map(QueryLiteral.string) ?? .null)
        }
    }
}

private extension Projected where Value == PaneSession? {
    var projectedRelation: ProjectedRelation {
        switch self {
        case .missing: .missing
        case let .value(value): .one(value?.querySnapshot)
        }
    }
}

private extension Projected where Value == [RelatedPane] {
    var projectedRelation: ProjectedRelation {
        switch self {
        case .missing: .missing
        case let .value(value): .many(value.map(\.querySnapshot))
        }
    }
}

private extension FilterNode {
    func matches(_ snapshot: QuerySnapshot) throws -> Bool {
        switch self {
        case let .predicate(model, field, operation):
            guard snapshot.model == model else { return false }
            guard let projected = snapshot.fields[field] else {
                throw FilterEvaluationError.missingField(field)
            }
            guard case let .value(value) = projected else {
                throw FilterEvaluationError.missingField(field)
            }
            return try operation.matches(value)
        case let .all(expressions):
            for expression in expressions where try !expression.matches(snapshot) {
                return false
            }
            return true
        case let .not(expression):
            return try !expression.matches(snapshot)
        case let .relation(model, relation, quantifier, expression):
            guard snapshot.model == model else { return false }
            guard let projected = snapshot.relations[relation] else {
                throw FilterEvaluationError.missingProjection(relation)
            }
            switch projected {
            case .missing:
                throw FilterEvaluationError.missingProjection(relation)
            case let .one(value):
                guard quantifier == .is, let value else { return false }
                return try expression.matches(value)
            case let .many(values):
                switch quantifier {
                case .is: return false
                case .some: return try values.contains { try expression.matches($0) }
                case .every: return try values.allSatisfy { try expression.matches($0) }
                case .none: return try !values.contains { try expression.matches($0) }
                }
            }
        }
    }
}

private extension FilterOperation {
    func matches(_ candidate: QueryLiteral) throws -> Bool {
        switch self {
        case let .scalar(tag, expected):
            switch tag {
            case .eq: return candidate == expected
            case .contains:
                return try strings(candidate, expected) { $0.contains($1) }
            case .endsWith:
                return try strings(candidate, expected) { $0.hasSuffix($1) }
            case .startsWith:
                return try strings(candidate, expected) { $0.hasPrefix($1) }
            case .iexact:
                return try strings(candidate, expected) {
                    try FixedLowercaseV1.apply($0) == FixedLowercaseV1.apply($1)
                }
            case .icontains:
                return try strings(candidate, expected) {
                    try FixedLowercaseV1.apply($0).contains(FixedLowercaseV1.apply($1))
                }
            case .iendsWith:
                return try strings(candidate, expected) {
                    try FixedLowercaseV1.apply($0).hasSuffix(FixedLowercaseV1.apply($1))
                }
            case .istartsWith:
                return try strings(candidate, expected) {
                    try FixedLowercaseV1.apply($0).hasPrefix(FixedLowercaseV1.apply($1))
                }
            case .in, .nin, .regex:
                return false
            }
        case let .membership(tag, values):
            let contains = values.contains(candidate)
            return tag == .nin ? !contains : contains
        case let .regex(_, regex):
            guard case let .string(value) = candidate else { return false }
            return try regex.matches(value)
        }
    }

    func strings(
        _ candidate: QueryLiteral,
        _ expected: QueryLiteral,
        operation: (String, String) throws -> Bool
    ) throws -> Bool {
        guard case let .string(candidate) = candidate,
            case let .string(expected) = expected
        else { return false }
        return try operation(candidate, expected)
    }
}

extension FilterExpr: Codable where Root: WireQueryRoot {
    private enum CodingKeys: String, CodingKey {
        case documentKind
        case schemaVersion
        case model
        case expression
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let documentKind = try container.decode(String.self, forKey: .documentKind)
        guard documentKind == "libtmux.filter-expression" else {
            throw QueryWireError.unsupportedDocumentKind(documentKind)
        }
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else {
            throw QueryWireError.unsupportedSchemaVersion(schemaVersion)
        }
        let rawModel = try container.decode(String.self, forKey: .model)
        guard let model = knownModel(rawModel) else {
            throw QueryWireError.unknownModel(rawModel)
        }
        let expected = Root.queryModel
        if model != expected {
            throw QueryWireError.rootModelMismatch(
                expected: expected.rawValue,
                actual: model.rawValue
            )
        }
        let node = try container.decode(FilterNode.self, forKey: .expression)
        try node.validate(as: model)
        self.init(model: model, node: node)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("libtmux.filter-expression", forKey: .documentKind)
        try container.encode(1, forKey: .schemaVersion)
        try node.validate(as: model)
        try container.encode(model.rawValue, forKey: .model)
        try container.encode(node, forKey: .expression)
    }
}

extension FilterNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case model
        case field
        case `operator`
        case expressions
        case expression
        case relation
        case quantifier
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "predicate":
            let model = try decodeModel(container, key: .model)
            let rawField = try container.decode(String.self, forKey: .field)
            guard knownFields.contains(FieldID(rawValue: rawField)) else {
                throw QueryWireError.unknownField(rawField)
            }
            self = .predicate(
                model: model,
                field: FieldID(rawValue: rawField),
                operation: try container.decode(FilterOperation.self, forKey: .operator)
            )
        case "all":
            self = .all(try container.decode([FilterNode].self, forKey: .expressions))
        case "not":
            self = .not(try container.decode(FilterNode.self, forKey: .expression))
        case "relation":
            let model = try decodeModel(container, key: .model)
            let rawRelation = try container.decode(String.self, forKey: .relation)
            guard knownRelations.contains(RelationID(rawValue: rawRelation)) else {
                throw QueryWireError.unknownRelation(rawRelation)
            }
            self = .relation(
                model: model,
                relation: RelationID(rawValue: rawRelation),
                quantifier: try decodeQuantifier(container, key: .quantifier),
                expression: try container.decode(FilterNode.self, forKey: .expression)
            )
        default:
            throw QueryWireError.unknownNode(kind)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .predicate(model, field, operation):
            try container.encode("predicate", forKey: .kind)
            try container.encode(model.rawValue, forKey: .model)
            try container.encode(field.rawValue, forKey: .field)
            try container.encode(operation, forKey: .operator)
        case let .all(expressions):
            try container.encode("all", forKey: .kind)
            try container.encode(expressions, forKey: .expressions)
        case let .not(expression):
            try container.encode("not", forKey: .kind)
            try container.encode(expression, forKey: .expression)
        case let .relation(model, relation, quantifier, expression):
            try container.encode("relation", forKey: .kind)
            try container.encode(model.rawValue, forKey: .model)
            try container.encode(relation.rawValue, forKey: .relation)
            try container.encode(quantifier.rawValue, forKey: .quantifier)
            try container.encode(expression, forKey: .expression)
        }
    }

}

extension FilterOperation: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case value
        case values
        case regex
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTag = try container.decode(String.self, forKey: .tag)
        let canonicalTag = rawTag == "exact" ? "eq" : rawTag
        guard let tag = OperatorTag(rawValue: canonicalTag) else {
            throw QueryWireError.unknownOperator(rawTag)
        }
        if tag == .in || tag == .nin {
            self = .membership(
                tag: tag,
                values: try container.decode([QueryLiteral].self, forKey: .values)
            )
        } else if tag == .regex {
            self = .regex(
                tag: tag,
                regex: try container.decode(RegexV1.self, forKey: .regex)
            )
        } else {
            self = .scalar(
                tag: tag,
                value: try container.decode(QueryLiteral.self, forKey: .value)
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .scalar(tag, value):
            try container.encode(tag.rawValue, forKey: .tag)
            try container.encode(value, forKey: .value)
        case let .membership(tag, values):
            try container.encode(tag.rawValue, forKey: .tag)
            try container.encode(values, forKey: .values)
        case let .regex(tag, regex):
            try container.encode(tag.rawValue, forKey: .tag)
            try container.encode(regex, forKey: .regex)
        }
    }
}

extension QueryLiteral: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "null": self = .null
        case "string": self = .string(try container.decode(String.self, forKey: .value))
        case "integer": self = .integer(try container.decode(Int.self, forKey: .value))
        case "boolean": self = .boolean(try container.decode(Bool.self, forKey: .value))
        default: throw QueryWireError.invalidLiteral(type)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .null:
            try container.encode("null", forKey: .type)
        case let .string(value):
            try container.encode("string", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .integer(value):
            try container.encode("integer", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode("boolean", forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

extension RegexV1: Codable {
    private enum CodingKeys: String, CodingKey {
        case dialect
        case pattern
        case flags
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let dialect = try container.decode(String.self, forKey: .dialect)
        guard dialect == Self.dialect else {
            throw QueryWireError.invalidRegexDialect(dialect)
        }
        let pattern = try container.decode(String.self, forKey: .pattern)
        let rawFlags = try container.decode([String].self, forKey: .flags)
        var flags: RegexFlags = []
        for flag in rawFlags {
            guard flag == "caseInsensitive" else {
                throw QueryWireError.unknownRegexFlag(flag)
            }
            flags.insert(.caseInsensitive)
        }
        guard let value = Self(pattern: pattern, flags: flags) else {
            throw QueryWireError.invalidLiteral(pattern)
        }
        self = value
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.dialect, forKey: .dialect)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(
            flags.contains(.caseInsensitive) ? ["caseInsensitive"] : [],
            forKey: .flags
        )
    }
}

private let knownFields: Set<FieldID> = [
    .paneCommand,
    .paneTitle,
    .paneWidth,
    .paneAlternateTitle,
    .paneSessionName,
    .relatedPaneCommand,
]

private let knownRelations: Set<RelationID> = [
    .paneSession,
    .paneRelatedPanes,
]

private enum WireFieldKind {
    case string
    case integer
    case optionalString
}

private extension FilterNode {
    func validate(as expectedModel: ModelID) throws {
        switch self {
        case let .predicate(model, field, operation):
            guard model == expectedModel else {
                throw QueryWireError.rootModelMismatch(
                    expected: expectedModel.rawValue,
                    actual: model.rawValue
                )
            }
            guard let kind = wireFieldKind(model: model, field: field) else {
                throw QueryWireError.unknownField(field.rawValue)
            }
            try operation.validate(as: kind)
        case let .all(expressions):
            for expression in expressions {
                try expression.validate(as: expectedModel)
            }
        case let .not(expression):
            try expression.validate(as: expectedModel)
        case let .relation(model, relation, quantifier, expression):
            guard model == expectedModel else {
                throw QueryWireError.rootModelMismatch(
                    expected: expectedModel.rawValue,
                    actual: model.rawValue
                )
            }
            let target: ModelID
            switch (model, relation) {
            case (.pane, .paneSession):
                guard quantifier == .is else {
                    throw QueryWireError.invalidRelationQuantifier(
                        relation: relation.rawValue,
                        quantifier: quantifier.rawValue
                    )
                }
                target = .paneSession
            case (.pane, .paneRelatedPanes):
                guard quantifier != .is else {
                    throw QueryWireError.invalidRelationQuantifier(
                        relation: relation.rawValue,
                        quantifier: quantifier.rawValue
                    )
                }
                target = .relatedPane
            default:
                throw QueryWireError.unknownRelation(relation.rawValue)
            }
            try expression.validate(as: target)
        }
    }
}

private extension FilterOperation {
    func validate(as kind: WireFieldKind) throws {
        switch (kind, self) {
        case (.string, let .scalar(tag, .string))
        where [
            .eq, .contains, .endsWith, .icontains, .iendsWith, .iexact,
            .istartsWith, .startsWith,
        ].contains(tag):
            return
        case (.optionalString, let .scalar(.eq, value))
        where value == .null
            || {
                if case .string = value { return true }
                return false
            }():
            return
        case (.integer, .scalar(.eq, .integer)):
            return
        case (.string, let .membership(tag, values))
        where (tag == .in || tag == .nin)
            && values.allSatisfy({
                if case .string = $0 { return true }
                return false
            }):
            return
        case (.optionalString, let .membership(tag, values))
        where (tag == .in || tag == .nin)
            && values.allSatisfy({
                if case .string = $0 { return true }
                return $0 == .null
            }):
            return
        case (.integer, let .membership(tag, values))
        where (tag == .in || tag == .nin)
            && values.allSatisfy({
                if case .integer = $0 { return true }
                return false
            }):
            return
        case (.string, .regex(.regex, _)):
            return
        default:
            throw QueryWireError.invalidLiteral("operator/value type mismatch")
        }
    }
}

private func wireFieldKind(model: ModelID, field: FieldID) -> WireFieldKind? {
    switch (model, field) {
    case (.pane, .paneCommand), (.pane, .paneTitle),
        (.paneSession, .paneSessionName), (.relatedPane, .relatedPaneCommand):
        .string
    case (.pane, .paneWidth):
        .integer
    case (.pane, .paneAlternateTitle):
        .optionalString
    default:
        nil
    }
}

private func knownModel(_ rawValue: String) -> ModelID? {
    let model = ModelID(rawValue: rawValue)
    return [.pane, .paneSession, .relatedPane].contains(model) ? model : nil
}

private func decodeModel<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    key: Key
) throws -> ModelID {
    let rawValue = try container.decode(String.self, forKey: key)
    guard let model = knownModel(rawValue) else {
        throw QueryWireError.unknownModel(rawValue)
    }
    return model
}

private func decodeQuantifier<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    key: Key
) throws -> RelationQuantifier {
    let rawValue = try container.decode(String.self, forKey: key)
    guard let quantifier = RelationQuantifier(rawValue: rawValue) else {
        throw QueryWireError.unknownQuantifier(rawValue)
    }
    return quantifier
}
