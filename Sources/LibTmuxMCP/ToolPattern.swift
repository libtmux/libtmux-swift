import LibTmux

enum ToolPattern {
    static let maximumListCount = 32

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

    static func compile(
        _ sources: [String],
        argument: String,
        caseInsensitive: Bool = false
    ) throws -> [RegexPattern] {
        guard sources.count <= maximumListCount else {
            throw ToolError.wrongArgumentType(
                argument,
                expected: "at most \(maximumListCount) bounded regular expressions"
            )
        }
        return try sources.enumerated().map { index, source in
            try compile(
                source,
                argument: "\(argument)[\(index)]",
                caseInsensitive: caseInsensitive
            )
        }
    }

    static func matches(
        _ pattern: RegexPattern,
        in text: String,
        argument: String
    ) throws -> Bool {
        do {
            return try pattern.containsMatch(in: text)
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
