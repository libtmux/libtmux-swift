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
}

/// Why a filter could not be built.
public enum QueryConstructionError: Error, Sendable, Hashable {
    /// The key path does not name a filterable field of this model.
    case unknownField
}

/// How a filter compares one field.
///
/// Written as a wire value rather than a closure, so an expression can be
/// stored, sent, inspected, and later compiled to a tmux `-f` predicate.
/// A regular expression travels as its pattern and flags; compiling one is the
/// evaluator's business and never crosses a boundary.
public enum FilterOperation: Sendable, Hashable, Codable {
    case equals(FilterValue)
    case caseInsensitiveEquals(String)
    case contains(String)
    case caseInsensitiveContains(String)
    case hasPrefix(String)
    case hasSuffix(String)
    case isIn([FilterValue])
    case matches(pattern: String, caseInsensitive: Bool)
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

    /// Pattern and flags, never a compiled `Regex`: the expression has to stay
    /// `Codable`, and the dialect is decided where it is evaluated.
    public static func matches(
        _ pattern: String,
        caseInsensitive: Bool = false
    ) -> Self where Value == String {
        Self(.matches(pattern: pattern, caseInsensitive: caseInsensitive))
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
        return .comparison(field: fieldID, operation: operation.operation)
    }

    /// Whether one value satisfies this filter.
    ///
    /// Evaluated against a value already in hand. Matching never reaches tmux,
    /// so iterating results cannot spawn a process.
    public func matches(_ root: Root) -> Bool {
        switch self {
        case let .comparison(fieldID, operation):
            guard let value = Root.filterValue(fieldID, of: root) else {
                return false
            }
            return operation.matches(value)
        case let .and(children):
            return children.allSatisfy { $0.matches(root) }
        case let .or(children):
            return children.contains { $0.matches(root) }
        case let .not(child):
            return !child.matches(root)
        }
    }
}

extension FilterOperation {
    func matches(_ value: FilterValue) -> Bool {
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
        case let .matches(pattern, caseInsensitive):
            guard case let .text(text) = value else { return false }
            return text.range(
                of: pattern,
                options: caseInsensitive
                    ? [.regularExpression, .caseInsensitive]
                    : [.regularExpression]
            ) != nil
        }
    }
}

// MARK: - Applying a filter

extension Sequence where Element: Filterable {
    /// Every element the filter matches, in order.
    ///
    /// Returns a plain array: ordered, replayable, and free of any live
    /// connection to tmux.
    public func filter(_ expression: FilterExpr<Element>) -> [Element] {
        filter { expression.matches($0) }
    }

    /// The one element the filter matches.
    ///
    /// Distinguishes "nothing matched" from "several matched", because a caller
    /// that meant to address one object needs to know which mistake it made.
    public func exactlyOne(
        _ expression: FilterExpr<Element>
    ) throws(CardinalityError) -> Element {
        let matches = filter(expression)
        switch matches.count {
        case 0: throw .noMatch
        case 1: return matches[0]
        default: throw .multipleMatches(count: matches.count)
        }
    }

    /// The one element the filter matches, or `nil` if none did.
    ///
    /// Only ambiguity is an error here; absence is an ordinary answer.
    public func oneOrNil(
        _ expression: FilterExpr<Element>
    ) throws(CardinalityError) -> Element? {
        let matches = filter(expression)
        switch matches.count {
        case 0: return nil
        case 1: return matches[0]
        default: throw .multipleMatches(count: matches.count)
        }
    }
}
