import Foundation
import Testing

@testable import LibTmux

@Suite("bounded regular expressions")
struct RegexPatternTests {
    @Test("the supported dialect covers pane and filter patterns")
    func supportedDialectMatches() throws {
        let cases: [(String, String, Bool)] = [
            ("^n?vim$", "nvim", true),
            ("^n?vim$", "vim", true),
            ("^n?vim$", "xnvim", false),
            ("^n.im$", "nvim", true),
            ("ROW(?:0000|4999)", "prefix ROW4999 suffix", true),
            ("^(ab|cd)*e$", "abcdabe", true),
            (#"^a\+b$"#, "a+b", true),
            (#"^\[\]$"#, "[]", true),
        ]

        for (source, input, expected) in cases {
            let pattern = try RegexPattern(source)
            #expect(try pattern.containsMatch(in: input) == expected)
        }
    }

    @Test("classes, shorthands, and counted repetitions compose")
    func classesAndCountsCompose() throws {
        let cases: [(String, String, Bool)] = [
            (#"^[a-c]+[0-9]?$"#, "abcc7", true),
            (#"^[^0-9]+$"#, "tmux", true),
            (#"^[^0-9]+$"#, "tmux3", false),
            (#"^\d{2,4}$"#, "123", true),
            (#"^\d{2,4}$"#, "1", false),
            (#"^\w+\s\w+$"#, "two words", true),
            (#"^a{2,}$"#, "aaaa", true),
            (#"^[-a]+$"#, "a--a", true),
        ]

        for (source, input, expected) in cases {
            #expect(try RegexPattern(source).containsMatch(in: input) == expected)
        }
    }

    @Test("compile failures identify the unsupported token")
    func compileFailuresCarryOffsets() {
        let cases: [(String, RegexCompileError)] = [
            (
                "(?=x)",
                .unsupportedConstruct(offset: 0, construct: .lookaround)
            ),
            (
                "(?<=x)",
                .unsupportedConstruct(offset: 0, construct: .lookaround)
            ),
            (
                "(a)\\1",
                .unsupportedConstruct(offset: 3, construct: .backreference)
            ),
            (
                "(?<name>x)",
                .unsupportedConstruct(offset: 0, construct: .namedCapture)
            ),
            (
                "(?i:x)",
                .unsupportedConstruct(offset: 0, construct: .inlineOptions)
            ),
            (
                "\\q",
                .unsupportedConstruct(offset: 0, construct: .escape)
            ),
            ("(ab", .unterminatedGroup(offset: 0)),
            ("[ab", .unterminatedCharacterClass(offset: 0)),
            ("[]", .emptyCharacterClass(offset: 0)),
            ("[z-a]", .invalidCharacterRange(offset: 2)),
            ("a++", .invalidRepetition(offset: 2)),
        ]

        for (source, expected) in cases {
            #expect(throws: expected) { try RegexPattern(source) }
        }
    }

    @Test("case-insensitive matching follows Swift Character lowercasing")
    func caseInsensitiveMatchingIsCharacterBased() throws {
        let options: RegexPattern.Options = [.caseInsensitive]

        #expect(try RegexPattern("^nvim$", options: options).containsMatch(in: "NVIM"))
        #expect(try RegexPattern("^[A-Z]+$", options: options).containsMatch(in: "nvim"))
        #expect(
            try RegexPattern("^É$", options: options)
                .containsMatch(in: "e\u{301}")
        )
        #expect(
            try !RegexPattern("^ss$", options: options)
                .containsMatch(in: "ß")
        )
    }

    @Test("matching treats one extended grapheme cluster as one character")
    func unicodeMatchingUsesCharacters() throws {
        let one = try RegexPattern("^.$")
        #expect(try one.containsMatch(in: "e\u{301}"))
        #expect(try one.containsMatch(in: "👨‍👩‍👧‍👦"))
        #expect(try RegexPattern("^é$").containsMatch(in: "e\u{301}"))
        #expect(try !one.containsMatch(in: "\n"))
        #expect(try !one.containsMatch(in: "\r\n"))

        #expect(try !RegexPattern(#"^\d$"#).containsMatch(in: "١"))
        #expect(try !RegexPattern(#"^\w$"#).containsMatch(in: "é"))
    }

    @Test("encoding preserves the compiled pattern's value semantics")
    func codableRoundTripPreservesBehavior() throws {
        let pattern = try RegexPattern(
            "^[a-z]+$",
            options: [.caseInsensitive]
        )
        let decoded = try JSONDecoder().decode(
            RegexPattern.self,
            from: JSONEncoder().encode(pattern)
        )

        #expect(decoded == pattern)
        #expect(Set([pattern]).contains(decoded))
        #expect(try decoded.containsMatch(in: "TMUX"))
    }

    @Test("compile and input limits fail explicitly")
    func structuralLimitsThrowTypedErrors() throws {
        let oversized = String(
            repeating: "a",
            count: RegexPattern.maximumSourceUTF8Bytes + 1
        )
        #expect(
            throws: RegexCompileError.sourceTooLong(
                maximumUTF8Bytes: RegexPattern.maximumSourceUTF8Bytes,
                actualUTF8Bytes: RegexPattern.maximumSourceUTF8Bytes + 1
            )
        ) {
            try RegexPattern(oversized)
        }

        let nested =
            String(repeating: "(", count: RegexPattern.maximumNesting + 1)
            + "a"
            + String(repeating: ")", count: RegexPattern.maximumNesting + 1)
        #expect(
            throws: RegexCompileError.nestingTooDeep(
                offset: RegexPattern.maximumNesting,
                maximum: RegexPattern.maximumNesting
            )
        ) {
            try RegexPattern(nested)
        }

        let tooManyStates = String(
            repeating: "a",
            count: RegexPattern.maximumCompiledStates
        )
        #expect(
            throws: RegexCompileError.stateLimitExceeded(
                offset: RegexPattern.maximumCompiledStates,
                maximum: RegexPattern.maximumCompiledStates
            )
        ) {
            try RegexPattern(tooManyStates)
        }

        let pattern = try RegexPattern("a")
        let longInput = String(
            repeating: "a",
            count: RegexPattern.maximumInputUTF8Bytes + 1
        )
        #expect(
            throws: RegexMatchError.inputTooLong(
                maximumUTF8Bytes: RegexPattern.maximumInputUTF8Bytes,
                actualUTF8Bytes: RegexPattern.maximumInputUTF8Bytes + 1
            )
        ) {
            try pattern.containsMatch(in: longInput)
        }
    }

    @Test("nested quantifiers consume linear work")
    func nestedQuantifiersStayWithinLinearWork() throws {
        let pattern = try RegexPattern("(A+)+B")
        let input = String(repeating: "A", count: 10_000)

        #expect(try !pattern.containsMatch(in: input, maximumWork: 400_000))
        #expect(throws: RegexMatchError.workLimitExceeded(maximum: 100)) {
            try pattern.containsMatch(in: input, maximumWork: 100)
        }
    }

    @Test("work limits include character-class scans")
    func characterClassScansConsumeWork() throws {
        let members = String(repeating: "a", count: 4_000)
        let pattern = try RegexPattern("[\(members)]")

        #expect(throws: RegexMatchError.workLimitExceeded(maximum: 100)) {
            try pattern.containsMatch(in: "z", maximumWork: 100)
        }
        #expect(throws: RegexMatchError.invalidWorkLimit(0)) {
            try pattern.containsMatch(in: "z", maximumWork: 0)
        }
    }
}
