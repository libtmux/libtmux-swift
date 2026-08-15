/// Builds a filter from a `field__operator=value` lookup written as text.
///
/// For a query that arrives as a string and so cannot be checked by the
/// compiler: a command-line flag, a config file, a request from another
/// process. The spelling is the one Django and Python libtmux both use, so a
/// lookup written for either reads the same here.
///
/// Swift callers write ``FilterExpr`` from key paths instead and have the
/// compiler check the field and its type; nothing inside the library routes
/// through this.
public enum FilterLookup {
    /// Builds an expression from one `field__operator=value` lookup.
    ///
    /// The model name selects the vocabulary: `"pane"`, `"session"`, and so on.
    /// A field can be named by wire id, Swift property, or tmux format name —
    /// whatever the schema lists as an alias.
    public static func parse<Root: Filterable>(
        _ lookup: String,
        as root: Root.Type,
        model: String
    ) throws(FilterLookupError) -> FilterExpr<Root> {
        guard let equals = lookup.firstIndex(of: "=") else {
            throw .missingValue
        }
        let key = String(lookup[lookup.startIndex..<equals])
        let value = String(lookup[lookup.index(after: equals)...])

        let (name, suffix) = splitLookupSuffix(key)
        guard let field = FilterSchema.current.field(named: name, in: model) else {
            throw .unknownField(name)
        }
        return .comparison(
            field: field.id,
            operation: try operation(suffix: suffix, value: value, type: field.type)
        )
    }

    private static func operation(
        suffix: String?,
        value: String,
        type: FilterSchema.ValueType
    ) throws(FilterLookupError) -> FilterOperation {
        switch suffix {
        case nil, "eq", "exact":
            return .equals(try literal(value, type: type))
        case "iexact":
            return .caseInsensitiveEquals(value)
        case "contains":
            return .contains(value)
        case "icontains":
            return .caseInsensitiveContains(value)
        case "startswith":
            return .hasPrefix(value)
        case "endswith":
            return .hasSuffix(value)
        case "in":
            // Python's lookup takes a sequence; as text that is a comma list.
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            var literals: [FilterValue] = []
            for part in parts {
                literals.append(try literal(String(part), type: type))
            }
            return .isIn(literals)
        case "regex":
            return .matches(pattern: value, caseInsensitive: false)
        case "iregex":
            return .matches(pattern: value, caseInsensitive: true)
        case let other?:
            throw .unknownOperator(other)
        }
    }

    private static func literal(
        _ value: String,
        type: FilterSchema.ValueType
    ) throws(FilterLookupError) -> FilterValue {
        switch type {
        case .text:
            return .text(value)
        case .integer:
            guard let number = Int(value) else {
                throw .valueNotOfFieldType(value)
            }
            return .integer(number)
        case .flag:
            switch value {
            case "1", "true", "True", "yes": return .flag(true)
            case "0", "false", "False", "no": return .flag(false)
            default: throw .valueNotOfFieldType(value)
            }
        }
    }
}

public enum FilterLookupError: Error, Sendable, Hashable {
    case missingValue
    case unknownField(String)
    case unknownOperator(String)
    case valueNotOfFieldType(String)
}

/// `name__contains` splits into `name` and `contains`. A field whose own name
/// contains `__` is not something tmux produces, so the last separator wins.
private func splitLookupSuffix(_ key: String) -> (String, String?) {
    guard let range = key.range(of: "__", options: .backwards) else {
        return (key, nil)
    }
    return (
        String(key[key.startIndex..<range.lowerBound]),
        String(key[range.upperBound...])
    )
}
