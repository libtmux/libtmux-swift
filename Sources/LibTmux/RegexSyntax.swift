import Foundation

private struct RegexToken: Sendable {
    let character: Character
    let offset: Int
}

struct RegexSyntax: Sendable {
    let kind: Kind
    let offset: Int

    indirect enum Kind: Sendable {
        case empty
        case predicate(RegexPredicate)
        case start
        case end
        case concatenation([RegexSyntax])
        case alternation([RegexSyntax])
        case repetition(RegexSyntax, minimum: Int, maximum: Int?)
    }
}

struct RegexLiteral: Sendable {
    fileprivate let character: Character
    fileprivate let utf8Bytes: Int

    fileprivate init(_ character: Character) {
        self.character = character
        self.utf8Bytes = String(character).utf8.count
    }
}

enum RegexClassMember: Sendable {
    case literal(RegexLiteral)
    case scalarRange(UInt32, UInt32)
    case asciiDigit
    case asciiWhitespace
    case asciiWord
    case notAsciiDigit
    case notAsciiWhitespace
    case notAsciiWord
}

enum RegexPredicate: Sendable {
    case any
    case characterClass([RegexClassMember], negated: Bool)

    func matches(
        _ character: Character,
        characterUTF8Bytes: Int,
        options: RegexPattern.Options,
        meter: inout RegexWorkMeter
    ) throws(RegexMatchError) -> Bool {
        switch self {
        case .any:
            return !character.isRegexLineTerminator
        case let .characterClass(members, negated):
            for member in members {
                try meter.charge(
                    member.matchWork(
                        characterUTF8Bytes: characterUTF8Bytes,
                        options: options
                    )
                )
                if member.matches(character, options: options) {
                    return !negated
                }
            }
            return negated
        }
    }
}

private extension RegexClassMember {
    func matchWork(
        characterUTF8Bytes: Int,
        options: RegexPattern.Options
    ) -> Int {
        switch self {
        case let .literal(literal):
            return characterUTF8Bytes + literal.utf8Bytes
        case .scalarRange where options.contains(.caseInsensitive):
            return characterUTF8Bytes * 3
        default:
            return characterUTF8Bytes
        }
    }

    func matches(_ character: Character, options: RegexPattern.Options) -> Bool {
        switch self {
        case let .literal(literal):
            return literal.character.regexEquals(character, options: options)
        case let .scalarRange(lower, upper):
            return character.regexScalarVariants(options: options).contains {
                lower <= $0 && $0 <= upper
            }
        case .asciiDigit:
            return character.regexASCIIValue.map { 48...57 ~= $0 } ?? false
        case .asciiWhitespace:
            return character.regexASCIIValue.map { $0 == 32 || 9...13 ~= $0 } ?? false
        case .asciiWord:
            return character.regexASCIIValue.map {
                48...57 ~= $0 || 65...90 ~= $0 || 97...122 ~= $0 || $0 == 95
            } ?? false
        case .notAsciiDigit:
            return !RegexClassMember.asciiDigit.matches(character, options: options)
        case .notAsciiWhitespace:
            return !RegexClassMember.asciiWhitespace.matches(character, options: options)
        case .notAsciiWord:
            return !RegexClassMember.asciiWord.matches(character, options: options)
        }
    }
}

private extension Character {
    var regexSingleScalar: UInt32? {
        var scalars = unicodeScalars.makeIterator()
        guard let first = scalars.next(), scalars.next() == nil else { return nil }
        return first.value
    }

    var regexASCIIValue: UInt32? {
        guard let value = regexSingleScalar, value < 128 else { return nil }
        return value
    }

    var isRegexLineTerminator: Bool {
        unicodeScalars.contains { scalar in
            let value = scalar.value
            return value == 0x0A || value == 0x0B || value == 0x0C || value == 0x0D
                || value == 0x85 || value == 0x2028 || value == 0x2029
        }
    }

    func regexEquals(_ other: Character, options: RegexPattern.Options) -> Bool {
        guard options.contains(.caseInsensitive) else { return self == other }
        return String(self).lowercased() == String(other).lowercased()
    }

    func regexScalarVariants(options: RegexPattern.Options) -> [UInt32] {
        guard options.contains(.caseInsensitive) else {
            return regexSingleScalar.map { [$0] } ?? []
        }
        return [String(self), String(self).lowercased(), String(self).uppercased()]
            .compactMap { text in
                guard text.count == 1, let character = text.first else { return nil }
                return character.regexSingleScalar
            }
    }

    var regexASCIIDigit: Int? {
        guard let value = regexASCIIValue, 48...57 ~= value else { return nil }
        return Int(value - 48)
    }
}

struct RegexParser {
    private let tokens: [RegexToken]
    private let endOffset: Int
    private var index = 0

    init(_ source: String) {
        var offset = 0
        var tokens: [RegexToken] = []
        tokens.reserveCapacity(source.count)
        for character in source {
            tokens.append(RegexToken(character: character, offset: offset))
            offset += String(character).utf8.count
        }
        self.tokens = tokens
        self.endOffset = offset
    }

    mutating func parse() throws(RegexCompileError) -> RegexSyntax {
        let syntax = try parseAlternation(depth: 0)
        if let token = peek() {
            throw .unexpectedToken(offset: token.offset)
        }
        return syntax
    }

    private mutating func parseAlternation(
        depth: Int
    ) throws(RegexCompileError) -> RegexSyntax {
        var choices = [try parseConcatenation(depth: depth)]
        while take("|") != nil {
            choices.append(try parseConcatenation(depth: depth))
        }
        guard choices.count > 1 else { return choices[0] }
        return RegexSyntax(kind: .alternation(choices), offset: choices[0].offset)
    }

    private mutating func parseConcatenation(
        depth: Int
    ) throws(RegexCompileError) -> RegexSyntax {
        let offset = peek()?.offset ?? endOffset
        var parts: [RegexSyntax] = []
        while let token = peek(), token.character != ")", token.character != "|" {
            parts.append(try parseRepetition(depth: depth))
        }
        if parts.isEmpty { return RegexSyntax(kind: .empty, offset: offset) }
        if parts.count == 1 { return parts[0] }
        return RegexSyntax(kind: .concatenation(parts), offset: parts[0].offset)
    }

    private mutating func parseRepetition(
        depth: Int
    ) throws(RegexCompileError) -> RegexSyntax {
        var syntax = try parseAtom(depth: depth)
        if let token = peek() {
            switch token.character {
            case "*":
                advance()
                syntax = RegexSyntax(
                    kind: .repetition(syntax, minimum: 0, maximum: nil),
                    offset: token.offset
                )
            case "+":
                advance()
                syntax = RegexSyntax(
                    kind: .repetition(syntax, minimum: 1, maximum: nil),
                    offset: token.offset
                )
            case "?":
                advance()
                syntax = RegexSyntax(
                    kind: .repetition(syntax, minimum: 0, maximum: 1),
                    offset: token.offset
                )
            case "{":
                syntax = try parseCountedRepetition(of: syntax)
            default:
                break
            }
        }
        if let token = peek(), "*+?{".contains(token.character) {
            throw .invalidRepetition(offset: token.offset)
        }
        return syntax
    }

    private mutating func parseCountedRepetition(
        of syntax: RegexSyntax
    ) throws(RegexCompileError) -> RegexSyntax {
        guard let opening = take("{") else { return syntax }
        let minimum = try parseCount(at: opening.offset)
        let maximum: Int?
        if take("}") != nil {
            maximum = minimum
        } else if take(",") != nil {
            if take("}") != nil {
                maximum = nil
            } else {
                let parsedMaximum = try parseCount(at: opening.offset)
                guard take("}") != nil, parsedMaximum >= minimum else {
                    throw .invalidRepetition(offset: opening.offset)
                }
                maximum = parsedMaximum
            }
        } else {
            throw .invalidRepetition(offset: opening.offset)
        }
        return RegexSyntax(
            kind: .repetition(syntax, minimum: minimum, maximum: maximum),
            offset: opening.offset
        )
    }

    private mutating func parseCount(at offset: Int) throws(RegexCompileError) -> Int {
        var value = 0
        var sawDigit = false
        while let token = peek(), let digit = token.character.regexASCIIDigit {
            sawDigit = true
            guard value <= (RegexPattern.maximumRepetition - digit) / 10 else {
                throw .repetitionTooLarge(
                    offset: offset,
                    maximum: RegexPattern.maximumRepetition
                )
            }
            value = value * 10 + digit
            advance()
        }
        guard sawDigit else { throw .invalidRepetition(offset: offset) }
        return value
    }

    private mutating func parseAtom(depth: Int) throws(RegexCompileError) -> RegexSyntax {
        guard let token = advance() else {
            throw .unexpectedToken(offset: endOffset)
        }
        switch token.character {
        case "(":
            return try parseGroup(opening: token, depth: depth)
        case "[":
            return try parseCharacterClass(opening: token)
        case "\\":
            return try RegexSyntax(
                kind: .predicate(parseEscape(at: token.offset)),
                offset: token.offset
            )
        case ".":
            return RegexSyntax(kind: .predicate(.any), offset: token.offset)
        case "^":
            return RegexSyntax(kind: .start, offset: token.offset)
        case "$":
            return RegexSyntax(kind: .end, offset: token.offset)
        case "*", "+", "?", "{":
            throw .invalidRepetition(offset: token.offset)
        case ")", "|", "}":
            throw .unexpectedToken(offset: token.offset)
        default:
            return RegexSyntax(
                kind: .predicate(
                    .characterClass([.literal(RegexLiteral(token.character))], negated: false)
                ),
                offset: token.offset
            )
        }
    }

    private mutating func parseGroup(
        opening: RegexToken,
        depth: Int
    ) throws(RegexCompileError) -> RegexSyntax {
        guard depth < RegexPattern.maximumNesting else {
            throw .nestingTooDeep(offset: opening.offset, maximum: RegexPattern.maximumNesting)
        }
        if take("?") != nil {
            guard take(":") != nil else {
                throw .unsupportedConstruct(
                    offset: opening.offset,
                    construct: unsupportedGroupConstruct()
                )
            }
        }
        let body = try parseAlternation(depth: depth + 1)
        guard take(")") != nil else {
            throw .unterminatedGroup(offset: opening.offset)
        }
        return RegexSyntax(kind: body.kind, offset: opening.offset)
    }

    private func unsupportedGroupConstruct() -> RegexUnsupportedConstruct {
        guard let token = peek() else { return .inlineOptions }
        if token.character == "=" || token.character == "!" { return .lookaround }
        if token.character == "<" {
            let next = peek(ahead: 1)?.character
            return next == "=" || next == "!" ? .lookaround : .namedCapture
        }
        return .inlineOptions
    }

    private mutating func parseCharacterClass(
        opening: RegexToken
    ) throws(RegexCompileError) -> RegexSyntax {
        let negated = take("^") != nil
        var members: [RegexClassMember] = []
        while let token = peek() {
            if token.character == "]" {
                advance()
                guard !members.isEmpty else {
                    throw .emptyCharacterClass(offset: opening.offset)
                }
                return RegexSyntax(
                    kind: .predicate(.characterClass(members, negated: negated)),
                    offset: opening.offset
                )
            }

            let first = try parseClassMember()
            if case let .literal(lowerLiteral) = first,
                let hyphen = peek(), hyphen.character == "-",
                peek(ahead: 1)?.character != "]"
            {
                advance()
                guard let next = peek(), next.character != "]" else {
                    throw .invalidCharacterRange(offset: hyphen.offset)
                }
                let upper = try parseClassMember()
                guard case let .literal(upperLiteral) = upper,
                    let lowerScalar = lowerLiteral.character.regexSingleScalar,
                    let upperScalar = upperLiteral.character.regexSingleScalar,
                    lowerScalar <= upperScalar
                else {
                    throw .invalidCharacterRange(offset: hyphen.offset)
                }
                members.append(.scalarRange(lowerScalar, upperScalar))
            } else {
                members.append(first)
            }
        }
        throw .unterminatedCharacterClass(offset: opening.offset)
    }

    private mutating func parseClassMember() throws(RegexCompileError) -> RegexClassMember {
        guard let token = advance() else { throw .unexpectedToken(offset: endOffset) }
        guard token.character == "\\" else {
            return .literal(RegexLiteral(token.character))
        }
        return try parseEscapedClassMember(at: token.offset)
    }

    private mutating func parseEscape(at offset: Int) throws(RegexCompileError) -> RegexPredicate {
        .characterClass([try parseEscapedClassMember(at: offset)], negated: false)
    }

    private mutating func parseEscapedClassMember(
        at offset: Int
    ) throws(RegexCompileError) -> RegexClassMember {
        guard let token = advance() else {
            throw .unsupportedConstruct(offset: offset, construct: .escape)
        }
        if token.character.regexASCIIDigit != nil {
            throw .unsupportedConstruct(offset: offset, construct: .backreference)
        }
        switch token.character {
        case "d": return .asciiDigit
        case "D": return .notAsciiDigit
        case "s": return .asciiWhitespace
        case "S": return .notAsciiWhitespace
        case "w": return .asciiWord
        case "W": return .notAsciiWord
        case "n": return .literal(RegexLiteral("\n"))
        case "r": return .literal(RegexLiteral("\r"))
        case "t": return .literal(RegexLiteral("\t"))
        default:
            if token.character.regexASCIIValue.map({ 65...90 ~= $0 || 97...122 ~= $0 })
                == true
            {
                throw .unsupportedConstruct(offset: offset, construct: .escape)
            }
            return .literal(RegexLiteral(token.character))
        }
    }

    private func peek(ahead: Int = 0) -> RegexToken? {
        let target = index + ahead
        return target < tokens.count ? tokens[target] : nil
    }

    @discardableResult
    private mutating func advance() -> RegexToken? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func take(_ expected: Character) -> RegexToken? {
        guard peek()?.character == expected else { return nil }
        return advance()
    }
}
