/// Lowering a ``FilterExpr`` to a tmux `-f` predicate.
///
/// The lowering is a *sound over-approximation*: every element the expression
/// matches survives the predicate, but the predicate may let extra elements
/// through. A node this build cannot lower becomes "true" rather than failing
/// the whole compilation, so an expression is never rejected for containing one.
/// Callers re-apply the expression to whatever comes back, which is what makes
/// the imprecision invisible — tmux narrows, Swift decides.
///
/// That is the whole reason a regular expression can sit inside an otherwise
/// lowerable tree: `matches` runs on tmux's engine, not this package's bounded
/// one, so it is left out of the predicate and evaluated at home.
enum FilterLowering {
    /// Escapes a string so tmux reads it as a literal inside a format.
    ///
    /// tmux splits a comparison's arguments on commas and ends the expansion at
    /// the first unescaped `}`, so a literal carrying either silently changes
    /// what is being asked — `#{==:a,b,a,b}` compares `a` with `b`. `#` is the
    /// escape character and therefore has to go first.
    static func escaped(_ literal: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(literal.unicodeScalars.count)
        // Over scalars, not characters. A `}` carrying a combining mark is one
        // Character and compares equal to neither `}` nor anything else, so a
        // switch over characters walks straight past a brace tmux still reads
        // as the end of the expansion.
        for scalar in literal.unicodeScalars {
            switch scalar {
            case "#": out.append(contentsOf: "##".unicodeScalars)
            case ",": out.append(contentsOf: "#,".unicodeScalars)
            case "}": out.append(contentsOf: "#}".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whether tmux comparing this literal byte for byte asks the same question
    /// Swift does.
    ///
    /// Two reasons it may not, and both silently drop rows rather than failing:
    ///
    /// Swift's `==` is canonical equivalence, so `caf\u{e9}` and `cafe\u{301}`
    /// are one string in Swift and two different byte sequences to tmux. A
    /// pure-ASCII literal cannot be canonically equal to anything but itself,
    /// which is what makes the two agree.
    ///
    /// A `#` is excluded as well. It is tmux's escape character, but the escape
    /// has an exception: in `##[` the run is kept rather than collapsed,
    /// because `#[` opens a style. No single encoding of a literal `#` is
    /// therefore right in every position, so a literal carrying one is matched
    /// at home instead.
    static func comparableAsBytes(_ literal: String) -> Bool {
        literal.unicodeScalars.allSatisfy { $0.isASCII && $0 != "#" }
    }

    /// Escapes a string so tmux's `m` modifier matches it literally, or `nil`
    /// when this build cannot promise that.
    ///
    /// `m` is glob(7), so a `*` a caller typed as data would otherwise match
    /// anything. A bracket expression is the portable way to say "this one
    /// character": `[*]` is a literal asterisk everywhere fnmatch is, and the
    /// same holds for `?`, `[` and `]`.
    ///
    /// A backslash is the exception and gets no bracket. fnmatch reads it as
    /// its own escape character, inside a bracket expression as well as
    /// outside, so `[\\]` is an unterminated bracket rather than a literal
    /// backslash — verified against tmux 3.2a, where every spelling of it
    /// failed to match a name that contained one. Rather than ship an escape
    /// that silently drops rows, a pattern carrying a backslash does not lower
    /// at all and is matched at home.
    static func globLiteral(_ literal: String) -> String? {
        guard !literal.contains("\\") else { return nil }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(literal.unicodeScalars.count)
        for scalar in literal.unicodeScalars {
            switch scalar {
            case "*", "?", "[", "]":
                out.append(contentsOf: "[\(scalar)]".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// A predicate that is always true, used wherever a node cannot lower.
    static let alwaysTrue = "1"

    /// Negation, spelled so it works at the supported floor.
    ///
    /// `#{!:...}` does not exist in tmux 3.2a — it expands to nothing rather
    /// than to a boolean. Comparing against `0` is the same question and is
    /// understood by every supported version.
    static func negated(_ predicate: String) -> String {
        predicate == alwaysTrue ? alwaysTrue : "#{==:\(predicate),0}"
    }

    static func all(_ predicates: [String]) -> String {
        let meaningful = predicates.filter { $0 != alwaysTrue }
        guard let first = meaningful.first else { return alwaysTrue }
        guard meaningful.count > 1 else { return first }
        return meaningful.dropFirst().reduce(first) { "#{&&:\($0),\($1)}" }
    }

    /// A predicate nothing satisfies.
    ///
    /// `.or([])` matches nothing, so an empty disjunction must lower to this
    /// rather than to ``alwaysTrue``. Spelling it "true" was sound on its own —
    /// a wider predicate only costs bandwidth — but it also made the branch
    /// look exactly lowered, which let a wrapping `not` negate it and exclude
    /// rows that genuinely matched.
    static let alwaysFalse = "0"

    static func any(_ predicates: [String]) -> String {
        guard !predicates.contains(alwaysTrue) else { return alwaysTrue }
        guard let first = predicates.first else { return alwaysFalse }
        guard predicates.count > 1 else { return first }
        return predicates.dropFirst().reduce(first) { "#{||:\($0),\($1)}" }
    }
}

extension FilterValue {
    /// This value as tmux prints it, before format escaping, or `nil` for a
    /// value that a plain comparison cannot express.
    ///
    /// A flag is the exception. Several of the fields this library reads as
    /// booleans are counts in tmux — `session_attached` is the number of
    /// attached clients — so `#{==:#{session_attached},1}` excludes a session
    /// two clients are looking at. The decoder already knows this and reads
    /// attachment as "not zero"; the predicate has to agree, and a comparison
    /// against a literal cannot say that. ``FilterOperation`` spells flags out
    /// separately instead.
    fileprivate var tmuxText: String? {
        switch self {
        case let .text(text): text
        case let .integer(number): String(number)
        case .flag: nil
        }
    }
}

extension FilterLowering {
    /// A predicate for a boolean field, phrased as tmux reports it.
    ///
    /// "Not zero" rather than "equals one", because tmux answers several of
    /// these with a count. This is exactly how the row decoder reads them, so
    /// the two cannot disagree.
    static func flag(_ expected: Bool, of field: String) -> String {
        expected ? "#{!=:\(field),0}" : "#{==:\(field),0}"
    }

}

/// A tmux predicate, and whether it asks exactly the question the expression
/// does.
///
/// The two travel together on purpose. They were computed apart once — the
/// predicate by lowering, the exactness by walking the tree a second time — and
/// the two walks disagreed about an empty branch, which was enough to let a
/// `not` negate an approximation and drop rows that matched. Deriving both from
/// one pass makes that class of bug unrepresentable.
struct LoweredPredicate {
    let text: String
    /// `true` only when tmux and this package cannot answer differently.
    /// An inexact predicate may still be used — it can only ever admit extra
    /// rows — but it must never be negated.
    let isExact: Bool

    /// Admits everything, and promises nothing.
    static let anything = LoweredPredicate(text: FilterLowering.alwaysTrue, isExact: false)
    /// Admits nothing, exactly.
    static let nothing = LoweredPredicate(text: FilterLowering.alwaysFalse, isExact: true)
}

extension FilterOperation {
    /// A predicate testing this operation against `field`, or `nil` when this
    /// build cannot express it at all.
    ///
    /// `field` is already a `#{...}` expansion; literals arrive raw and are
    /// escaped here so no caller has to remember to.
    func lowered(comparing field: String) -> LoweredPredicate? {
        func exactly(_ text: String) -> LoweredPredicate {
            LoweredPredicate(text: text, isExact: true)
        }
        /// A glob is never exact even on an ASCII pattern. tmux matches bytes
        /// where Swift matches characters, so `e*` finds the `e` inside a
        /// decomposed `é` and `hasPrefix("e")` does not. tmux therefore admits
        /// rows Swift rejects — harmless while the result is filtered again,
        /// and wrong the moment it is negated.
        func approximately(_ text: String) -> LoweredPredicate {
            LoweredPredicate(text: text, isExact: false)
        }
        func glob(_ pattern: String) -> String? {
            guard FilterLowering.comparableAsBytes(pattern) else { return nil }
            return FilterLowering.globLiteral(pattern).map(FilterLowering.escaped)
        }

        switch self {
        case let .equals(value):
            if case let .flag(expected) = value {
                return exactly(FilterLowering.flag(expected, of: field))
            }
            guard let text = value.tmuxText,
                FilterLowering.comparableAsBytes(text)
            else { return nil }
            return exactly("#{==:\(field),\(FilterLowering.escaped(text))}")
        case let .isIn(values):
            guard !values.isEmpty else { return .nothing }
            var comparisons: [String] = []
            for value in values {
                if case let .flag(expected) = value {
                    comparisons.append(FilterLowering.flag(expected, of: field))
                    continue
                }
                guard let text = value.tmuxText,
                    FilterLowering.comparableAsBytes(text)
                else { return nil }
                comparisons.append("#{==:\(field),\(FilterLowering.escaped(text))}")
            }
            return exactly(FilterLowering.any(comparisons))
        case let .caseInsensitiveEquals(text):
            return glob(text).map { approximately("#{m/i:\($0),\(field)}") }
        case let .contains(text):
            return glob(text).map { approximately("#{m:*\($0)*,\(field)}") }
        case let .caseInsensitiveContains(text):
            return glob(text).map { approximately("#{m/i:*\($0)*,\(field)}") }
        case let .hasPrefix(text):
            return glob(text).map { approximately("#{m:\($0)*,\(field)}") }
        case let .hasSuffix(text):
            return glob(text).map { approximately("#{m:*\($0),\(field)}") }
        case .matches:
            // tmux's regular expression engine is not this package's bounded
            // one. Leaving it out keeps the predicate sound.
            return nil
        }
    }
}

extension FilterExpr {
    /// This expression as a tmux predicate, with its exactness.
    ///
    /// Never fails: a node that cannot be lowered becomes
    /// ``LoweredPredicate/anything``, and the caller filters the result anyway.
    var lowered: LoweredPredicate {
        switch self {
        case let .comparison(fieldID, operation):
            guard let field = Root.filterFormatField(fieldID),
                let lowered = operation.lowered(comparing: "#{\(field)}")
            else { return .anything }
            return lowered
        case let .and(children):
            // An empty conjunction is vacuously true, which `all` already
            // spells, and it is exactly true.
            let parts = children.map(\.lowered)
            return LoweredPredicate(
                text: FilterLowering.all(parts.map(\.text)),
                isExact: parts.allSatisfy(\.isExact)
            )
        case let .or(children):
            guard !children.isEmpty else { return .nothing }
            let parts = children.map(\.lowered)
            return LoweredPredicate(
                text: FilterLowering.any(parts.map(\.text)),
                isExact: parts.allSatisfy(\.isExact)
            )
        case let .not(child):
            // Negating an over-approximation under-approximates, which drops
            // real matches for good — the second pass only sees rows tmux
            // already returned.
            let child = child.lowered
            guard child.isExact else { return .anything }
            return LoweredPredicate(
                text: FilterLowering.negated(child.text),
                isExact: true
            )
        }
    }

    /// A tmux `-f` predicate admitting everything this expression matches.
    var tmuxPredicate: String { lowered.text }

    /// Whether ``tmuxPredicate`` is exact rather than an over-approximation.
    var isFullyLowered: Bool { lowered.isExact }
}
