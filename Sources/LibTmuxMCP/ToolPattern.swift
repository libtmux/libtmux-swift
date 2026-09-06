import Foundation
import LibTmux

enum ToolPattern {
    static let maximumListCount = 32
    static let maximumAggregateSourceBytes = 16_384

    static func compile(
        _ source: String,
        argument: String,
        caseInsensitive: Bool = false
    ) throws -> RegexPattern {
        do {
            return try RegexPattern(
                source,
                options: caseInsensitive ? [.caseInsensitive] : []
            )
        } catch {
            throw ToolError.wrongArgumentType(
                argument,
                expected: "a regular expression in LibTmux's bounded dialect (\(error))"
            )
        }
    }

    static func compileLiteral(
        _ source: String,
        argument: String,
        caseInsensitive: Bool = false
    ) throws -> RegexPattern {
        try validateSources([source], argument: argument)
        let escaped = NSRegularExpression.escapedPattern(for: source)
        do {
            return try RegexPattern(
                escaped,
                options: caseInsensitive ? [.caseInsensitive] : [],
                maximumSourceUTF8Bytes: RegexPattern.maximumSourceUTF8Bytes * 2,
                maximumCompiledStates: RegexPattern.maximumSourceUTF8Bytes * 2
            )
        } catch {
            throw ToolError.wrongArgumentType(
                argument,
                expected: "bounded literal text (\(error))"
            )
        }
    }

    static func compileLiteral(
        _ sources: [String],
        argument: String,
        caseInsensitive: Bool = false
    ) throws -> [RegexPattern] {
        try validateSources(sources, argument: argument)
        return try sources.enumerated().map { index, source in
            try compileLiteral(
                source,
                argument: "\(argument)[\(index)]",
                caseInsensitive: caseInsensitive
            )
        }
    }

    static func compile(
        _ sources: [String],
        argument: String,
        caseInsensitive: Bool = false
    ) throws -> [RegexPattern] {
        try validateSources(sources, argument: argument)
        return try sources.enumerated().map { index, source in
            try compile(
                source,
                argument: "\(argument)[\(index)]",
                caseInsensitive: caseInsensitive
            )
        }
    }

    private static func validateSources(_ sources: [String], argument: String) throws {
        guard sources.count <= maximumListCount else {
            throw ToolError.wrongArgumentType(
                argument,
                expected: "at most \(maximumListCount) bounded regular expressions"
            )
        }
        let aggregateBytes = try sources.reduce(0) { total, source in
            let (sum, overflowed) = total.addingReportingOverflow(source.utf8.count)
            guard !overflowed else {
                throw ToolError.wrongArgumentType(
                    argument,
                    expected: "at most \(maximumAggregateSourceBytes) UTF-8 bytes of patterns"
                )
            }
            return sum
        }
        guard aggregateBytes <= maximumAggregateSourceBytes else {
            throw ToolError.wrongArgumentType(
                argument,
                expected: "at most \(maximumAggregateSourceBytes) UTF-8 bytes of patterns"
            )
        }
        for (index, source) in sources.enumerated() {
            guard source.utf8.count <= RegexPattern.maximumSourceUTF8Bytes else {
                throw ToolError.wrongArgumentType(
                    "\(argument)[\(index)]",
                    expected: "at most \(RegexPattern.maximumSourceUTF8Bytes) UTF-8 bytes"
                )
            }
        }
    }

    static func matches(
        _ pattern: RegexPattern,
        in text: String,
        argument: String,
        budget: RegexMatchBudget? = nil
    ) throws -> Bool {
        do {
            guard let budget else { return try pattern.containsMatch(in: text) }
            return try pattern.containsMatch(in: text, budget: budget)
        } catch {
            throw matchingFailure(error, argument: argument)
        }
    }

    static func evaluate<Result>(
        argument: String,
        _ operation: () throws(RegexMatchError) -> Result
    ) throws -> Result {
        do {
            return try operation()
        } catch {
            throw matchingFailure(error, argument: argument)
        }
    }

    static func matchingFailure(
        _ error: RegexMatchError,
        argument: String
    ) -> ToolError {
        .refusedForSafety("bounded matching for \(argument) could not finish: \(error)")
    }
}
