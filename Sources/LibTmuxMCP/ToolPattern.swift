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

extension ToolPattern {
    /// Refuses a format that would run a shell command.
    ///
    /// `read_format` and `watch_format` answer questions and are offered at
    /// the readonly tier, which promises nothing on the server changes. tmux
    /// runs `#(command)` in any format it expands, so a template arriving from
    /// a client reaches a shell that the tier says it cannot.
    static func checkedFormat(_ template: String, argument: String) throws -> String {
        guard !tmuxFormatRequestsShellJob(template) else {
            throw ToolError.refusedForSafety(
                "\(argument) runs a shell command with #(...), which this tool does not "
                    + "allow. Double the # to read it as text, or use run_shell."
            )
        }
        return template
    }
}
