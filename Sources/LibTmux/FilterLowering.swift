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
        var out = ""
        out.reserveCapacity(literal.count)
        for character in literal {
            switch character {
            case "#": out += "##"
            case ",": out += "#,"
            case "}": out += "#}"
            default: out.append(character)
            }
        }
        return out
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
        var out = ""
        out.reserveCapacity(literal.count)
        for character in literal {
            switch character {
            case "*", "?", "[", "]": out += "[\(character)]"
            default: out.append(character)
            }
        }
        return out
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

    static func any(_ predicates: [String]) -> String {
        // One unlowerable branch makes the whole disjunction unlowerable: the
        // others cannot exclude what that branch might have admitted.
        guard !predicates.contains(alwaysTrue) else { return alwaysTrue }
        guard let first = predicates.first else { return alwaysTrue }
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

    /// Whether a case-insensitive match may be handed to tmux.
    ///
    /// `m/i` folds case with fnmatch's `FNM_CASEFOLD`, which follows the
    /// server's locale, while this package folds with Swift's Unicode-correct
    /// `lowercased()`. For ASCII the two agree everywhere; beyond it they need
    /// not, and a server running under `LC_ALL=C` would fold nothing at all.
    /// Rather than let the answer depend on the daemon's environment, anything
    /// non-ASCII is matched at home.
    static func foldsIdenticallyToTmux(_ literal: String) -> Bool {
        literal.unicodeScalars.allSatisfy(\.isASCII)
    }
}

extension FilterOperation {
    /// A tmux predicate testing this operation against `field`, or `nil` when
    /// this build cannot express it.
    ///
    /// `field` is already a `#{...}` expansion; literals arrive raw and are
    /// escaped here so no caller has to remember to.
    func tmuxPredicate(comparing field: String) -> String? {
        func literal(_ value: String) -> String { FilterLowering.escaped(value) }
        func glob(_ pattern: String) -> String? {
            FilterLowering.globLiteral(pattern).map(FilterLowering.escaped)
        }
        func foldedGlob(_ pattern: String) -> String? {
            FilterLowering.foldsIdenticallyToTmux(pattern) ? glob(pattern) : nil
        }
        switch self {
        case let .equals(value):
            if case let .flag(expected) = value {
                return FilterLowering.flag(expected, of: field)
            }
            return value.tmuxText.map { "#{==:\(field),\(literal($0))}" }
        case let .caseInsensitiveEquals(text):
            return foldedGlob(text).map { "#{m/i:\($0),\(field)}" }
        case let .contains(text):
            return glob(text).map { "#{m:*\($0)*,\(field)}" }
        case let .caseInsensitiveContains(text):
            return foldedGlob(text).map { "#{m/i:*\($0)*,\(field)}" }
        case let .hasPrefix(text):
            return glob(text).map { "#{m:\($0)*,\(field)}" }
        case let .hasSuffix(text):
            return glob(text).map { "#{m:*\($0),\(field)}" }
        case let .isIn(values):
            guard !values.isEmpty else { return "0" }
            let comparisons = values.map { value -> String in
                if case let .flag(expected) = value {
                    return FilterLowering.flag(expected, of: field)
                }
                return value.tmuxText.map { "#{==:\(field),\(literal($0))}" }
                    ?? FilterLowering.alwaysTrue
            }
            return FilterLowering.any(comparisons)
        case .matches:
            // tmux's regex engine is not this package's bounded one. Leaving it
            // out keeps the predicate sound; the caller still evaluates it.
            return nil
        }
    }
}

extension FilterExpr {
    /// A tmux `-f` predicate that admits everything this expression matches.
    ///
    /// Never `nil`: an expression that lowers to nothing lowers to "true", and
    /// the caller filters the result anyway. ``isFullyLowered`` says whether
    /// that second pass can actually change the answer.
    var tmuxPredicate: String {
        switch self {
        case let .comparison(fieldID, operation):
            guard let field = Root.filterFormatField(fieldID) else {
                return FilterLowering.alwaysTrue
            }
            return operation.tmuxPredicate(comparing: "#{\(field)}")
                ?? FilterLowering.alwaysTrue
        case let .and(children):
            return FilterLowering.all(children.map(\.tmuxPredicate))
        case let .or(children):
            return FilterLowering.any(children.map(\.tmuxPredicate))
        case let .not(child):
            // A negated over-approximation is an under-approximation, which
            // would drop real matches. Only an exact child may be negated.
            guard child.isFullyLowered else { return FilterLowering.alwaysTrue }
            return FilterLowering.negated(child.tmuxPredicate)
        }
    }

    /// Whether ``tmuxPredicate`` is exact rather than an over-approximation.
    var isFullyLowered: Bool {
        switch self {
        case let .comparison(fieldID, operation):
            guard Root.filterFormatField(fieldID) != nil else { return false }
            return operation.tmuxPredicate(comparing: "#{x}") != nil
        case let .and(children), let .or(children):
            return children.allSatisfy(\.isFullyLowered)
        case let .not(child):
            return child.isFullyLowered
        }
    }
}
