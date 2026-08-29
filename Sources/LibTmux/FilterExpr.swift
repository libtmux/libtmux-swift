import Foundation

/// A value a filter can compare against.
public enum FilterValue: Sendable, Hashable, Codable {
    case text(String)
    case integer(Int)
    case flag(Bool)
}

/// A model that can be filtered declaratively.
///
/// Key paths are lowered to stable ids inside a synchronous call and then
/// discarded. Nothing stores one: `AnyKeyPath` is a non-`Sendable` class, so
/// keeping it would make every expression that held it unsendable, and an
/// expression's whole purpose is to travel.
public protocol Filterable: Sendable {
    /// The stable wire id for a key path, or `nil` if the property is not
    /// filterable.
    static func filterFieldID(for keyPath: PartialKeyPath<Self>) -> String?

    /// Reads the field an id names, or `nil` if this model has no such field.
    static func filterValue(_ id: String, of root: Self) -> FilterValue?

    /// The value kind an id names, or `nil` when this model does not know it.
    static func filterFieldType(_ id: String) -> FilterSchema.ValueType?
}

/// Why a filter could not be built.
public enum QueryConstructionError: Error, Sendable, Hashable {
    /// The key path does not name a filterable field of this model.
    case unknownField
    /// The field and operator could not form a safe expression.
    case invalidOperation(FilterValidationError)
}

/// Why a decoded filter cannot be evaluated safely.
public enum FilterValidationError: Error, Sendable, Hashable {
    case unknownField(String)
    case incompatibleOperation(
        field: String,
        type: FilterSchema.ValueType,
        operation: FilterOperation
    )
}

/// Why selecting one result from a filter failed.
public enum FilterSelectionError: Error, Sendable, Hashable {
    case matching(RegexMatchError)
    case cardinality(CardinalityError)
}

/// How a filter compares one field.
///
/// Written as a wire value rather than a closure, so an expression can be
/// stored, sent, inspected, and later compiled to a tmux `-f` predicate.
/// A regular expression travels in compiled, bounded form.
public enum FilterOperation: Sendable, Hashable, Codable {
    case equals(FilterValue)
    case caseInsensitiveEquals(String)
    case contains(String)
    case caseInsensitiveContains(String)
    case hasPrefix(String)
    case hasSuffix(String)
    case isIn([FilterValue])
    case matches(pattern: RegexPattern)
}

/// A typed operator. The `Value` it is built for is the projected type of the
/// key path it is paired with, so pairing a text operator with an integer field
/// is a compile error rather than a runtime surprise.
public struct FilterOperator<Value>: Sendable {
    let operation: FilterOperation

    private init(_ operation: FilterOperation) {
        self.operation = operation
    }

    // MARK: Text

    public static func equals(_ value: String) -> Self where Value == String {
        Self(.equals(.text(value)))
    }

    public static func caseInsensitiveEquals(_ value: String) -> Self
    where Value == String {
        Self(.caseInsensitiveEquals(value))
    }

    public static func contains(_ value: String) -> Self where Value == String {
        Self(.contains(value))
    }

    public static func caseInsensitiveContains(_ value: String) -> Self
    where Value == String {
        Self(.caseInsensitiveContains(value))
    }

    public static func hasPrefix(_ value: String) -> Self where Value == String {
        Self(.hasPrefix(value))
    }

    public static func hasSuffix(_ value: String) -> Self where Value == String {
        Self(.hasSuffix(value))
    }

    public static func isIn(_ values: [String]) -> Self where Value == String {
        Self(.isIn(values.map(FilterValue.text)))
    }

    public static func matches(_ pattern: RegexPattern) -> Self where Value == String {
        Self(.matches(pattern: pattern))
    }

    // MARK: Typed identifiers

    public static func equals(_ value: SessionID) -> Self where Value == SessionID {
        Self(.equals(.text(value.rawValue)))
    }

    public static func isIn(_ values: [SessionID]) -> Self where Value == SessionID {
        Self(.isIn(values.map { .text($0.rawValue) }))
    }

    public static func equals(_ value: WindowID) -> Self where Value == WindowID {
        Self(.equals(.text(value.rawValue)))
    }

    public static func isIn(_ values: [WindowID]) -> Self where Value == WindowID {
        Self(.isIn(values.map { .text($0.rawValue) }))
    }

    public static func equals(_ value: PaneID) -> Self where Value == PaneID {
        Self(.equals(.text(value.rawValue)))
    }

    public static func isIn(_ values: [PaneID]) -> Self where Value == PaneID {
        Self(.isIn(values.map { .text($0.rawValue) }))
    }

    // MARK: Integer

    public static func equals(_ value: Int) -> Self where Value == Int {
        Self(.equals(.integer(value)))
    }

    public static func isIn(_ values: [Int]) -> Self where Value == Int {
        Self(.isIn(values.map(FilterValue.integer)))
    }

    // MARK: Flag

    public static func equals(_ value: Bool) -> Self where Value == Bool {
        Self(.equals(.flag(value)))
    }
}

/// A filter over one model, held as data.
///
/// `Sendable` and `Codable` because it is meant to outlive the call that built
/// it: stored in a config, sent to another process, or translated into a tmux
/// predicate. Closures deliberately have no place in it — they cannot be any of
/// those things.
public indirect enum FilterExpr<Root: Filterable>: Sendable, Hashable, Codable {
    case comparison(field: String, operation: FilterOperation)
    case and([FilterExpr<Root>])
    case or([FilterExpr<Root>])
    case not(FilterExpr<Root>)

    /// Builds a comparison from a key path.
    ///
    /// The key path is lowered to a stable field id here and then discarded —
    /// nothing downstream holds one, so an expression can cross a boundary a
    /// key path could not.
    public static func `where`<Value>(
        _ keyPath: KeyPath<Root, Value> & Sendable,
        _ operation: FilterOperator<Value>
    ) throws(QueryConstructionError) -> Self {
        guard let fieldID = Root.filterFieldID(for: keyPath) else {
            throw .unknownField
        }
        guard let type = Root.filterFieldType(fieldID) else { throw .unknownField }
        do {
            try operation.operation.validate(field: fieldID, type: type)
        } catch {
            throw .invalidOperation(error)
        }
        return .comparison(field: fieldID, operation: operation.operation)
    }

    /// Whether one value satisfies this filter.
    ///
    /// Evaluated against a value already in hand. Matching never reaches tmux,
    /// so iterating results cannot spawn a process.
    public func matches(_ root: Root) throws(RegexMatchError) -> Bool {
        switch self {
        case let .comparison(fieldID, operation):
            guard let value = Root.filterValue(fieldID, of: root) else {
                return false
            }
            return try operation.matches(value)
        case let .and(children):
            for child in children {
                if try !child.matches(root) { return false }
            }
            return true
        case let .or(children):
            for child in children {
                if try child.matches(root) { return true }
            }
            return false
        case let .not(child):
            return try !child.matches(root)
        }
    }

    /// Rejects field ids this build does not understand anywhere in the tree.
    public func validate() throws(FilterValidationError) {
        switch self {
        case let .comparison(fieldID, operation):
            guard let type = Root.filterFieldType(fieldID) else {
                throw .unknownField(fieldID)
            }
            try operation.validate(field: fieldID, type: type)
        case let .and(children), let .or(children):
            for child in children { try child.validate() }
        case let .not(child):
            try child.validate()
        }
    }
}

extension FilterOperation {
    func validate(
        field: String,
        type: FilterSchema.ValueType
    ) throws(FilterValidationError) {
        switch self {
        case let .equals(value):
            guard value.schemaType == type else {
                throw .incompatibleOperation(field: field, type: type, operation: self)
            }
        case let .isIn(values):
            guard values.allSatisfy({ $0.schemaType == type }) else {
                throw .incompatibleOperation(field: field, type: type, operation: self)
            }
        case .caseInsensitiveEquals, .contains, .caseInsensitiveContains, .hasPrefix,
            .hasSuffix:
            guard type == .text else {
                throw .incompatibleOperation(field: field, type: type, operation: self)
            }
        case .matches:
            guard type == .text else {
                throw .incompatibleOperation(field: field, type: type, operation: self)
            }
        }
    }

    func matches(_ value: FilterValue) throws(RegexMatchError) -> Bool {
        switch self {
        case let .equals(expected):
            return value == expected
        case let .caseInsensitiveEquals(expected):
            guard case let .text(text) = value else { return false }
            return text.lowercased() == expected.lowercased()
        case let .contains(expected):
            guard case let .text(text) = value else { return false }
            return text.contains(expected)
        case let .caseInsensitiveContains(expected):
            guard case let .text(text) = value else { return false }
            return text.lowercased().contains(expected.lowercased())
        case let .hasPrefix(expected):
            guard case let .text(text) = value else { return false }
            return text.hasPrefix(expected)
        case let .hasSuffix(expected):
            guard case let .text(text) = value else { return false }
            return text.hasSuffix(expected)
        case let .isIn(expected):
            return expected.contains(value)
        case let .matches(pattern):
            guard case let .text(text) = value else { return false }
            return try pattern.containsMatch(in: text)
        }
    }
}

extension FilterValue {
    fileprivate var schemaType: FilterSchema.ValueType {
        switch self {
        case .text: .text
        case .integer: .integer
        case .flag: .flag
        }
    }
}

// MARK: - Applying a filter

extension Sequence where Element: Filterable {
    /// Every element the filter matches, in order.
    ///
    /// Returns a plain array: ordered, replayable, and free of any live
    /// connection to tmux.
    public func filter(
        _ expression: FilterExpr<Element>
    ) throws(RegexMatchError) -> [Element] {
        var result: [Element] = []
        for element in self where try expression.matches(element) {
            result.append(element)
        }
        return result
    }

    /// The one element the filter matches.
    ///
    /// Distinguishes "nothing matched" from "several matched", because a caller
    /// that meant to address one object needs to know which mistake it made.
    public func exactlyOne(
        _ expression: FilterExpr<Element>
    ) throws(FilterSelectionError) -> Element {
        let matches: [Element]
        do {
            matches = try filter(expression)
        } catch {
            throw .matching(error)
        }
        switch matches.count {
        case 0: throw .cardinality(.noMatch)
        case 1: return matches[0]
        default: throw .cardinality(.multipleMatches(count: matches.count))
        }
    }

    /// The one element the filter matches, or `nil` if none did.
    ///
    /// Only ambiguity is an error here; absence is an ordinary answer.
    public func oneOrNil(
        _ expression: FilterExpr<Element>
    ) throws(FilterSelectionError) -> Element? {
        let matches: [Element]
        do {
            matches = try filter(expression)
        } catch {
            throw .matching(error)
        }
        switch matches.count {
        case 0: return nil
        case 1: return matches[0]
        default: throw .cardinality(.multipleMatches(count: matches.count))
        }
    }
}
