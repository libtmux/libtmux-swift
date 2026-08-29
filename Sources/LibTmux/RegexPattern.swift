import Foundation

/// A regular-expression feature this package deliberately does not execute.
public enum RegexUnsupportedConstruct: String, Sendable, Hashable {
    case backreference
    case escape
    case inlineOptions
    case lookaround
    case namedCapture
}

/// Why a ``RegexPattern`` could not be compiled.
///
/// Token offsets count UTF-8 bytes in ``RegexPattern/source``.
public enum RegexCompileError: Error, Sendable, Hashable {
    case sourceTooLong(maximumUTF8Bytes: Int, actualUTF8Bytes: Int)
    case unsupportedOptions(rawValue: UInt8)
    case nestingTooDeep(offset: Int, maximum: Int)
    case unexpectedToken(offset: Int)
    case unterminatedGroup(offset: Int)
    case unterminatedCharacterClass(offset: Int)
    case emptyCharacterClass(offset: Int)
    case invalidCharacterRange(offset: Int)
    case invalidRepetition(offset: Int)
    case repetitionTooLarge(offset: Int, maximum: Int)
    case unsupportedConstruct(offset: Int, construct: RegexUnsupportedConstruct)
    case stateLimitExceeded(offset: Int, maximum: Int)
}

/// Why a compiled ``RegexPattern`` could not finish matching.
public enum RegexMatchError: Error, Sendable, Hashable {
    case invalidWorkLimit(Int)
    case inputTooLong(maximumUTF8Bytes: Int, actualUTF8Bytes: Int)
    case workLimitExceeded(maximum: Int)
}

/// A compiled regular expression with bounded memory and matching work.
///
/// The supported dialect has literals, escaped punctuation, `.`, `^`, `$`,
/// grouping, noncapturing grouping, alternation, `*`, `+`, `?`, counted
/// repetitions, character classes and ranges, and ASCII `\d`, `\s`, and
/// `\w` shorthands. Lookaround and backreferences are rejected.
///
/// Matching consumes Swift extended grapheme clusters. Literal equality uses
/// Swift `Character` equality, including canonical equivalence. With
/// ``Options/caseInsensitive``, each character is compared through
/// locale-independent `lowercased()` values; full multi-character case folding
/// is not performed, so `ss` does not match `ß`. Dot excludes line terminators.
public struct RegexPattern: Sendable, Hashable, Codable {
    /// Matching options encoded with the pattern.
    public struct Options: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Compares literals and ranges without case distinctions.
        public static let caseInsensitive = Self(rawValue: 1 << 0)
    }

    public static let maximumSourceUTF8Bytes = 4_096
    public static let maximumNesting = 64
    public static let maximumCompiledStates = 2_048
    public static let maximumRepetition = 1_024
    public static let maximumInputUTF8Bytes = 1_048_576
    public static let defaultMaximumWork = 8_000_000

    /// The source form preserved for encoding and diagnostics.
    public let source: String
    /// Options applied during matching.
    public let options: Options

    private let program: RegexProgram

    /// Compiles a bounded regular expression.
    public init(
        _ source: String,
        options: Options = []
    ) throws(RegexCompileError) {
        let sourceBytes = source.utf8.count
        guard sourceBytes <= Self.maximumSourceUTF8Bytes else {
            throw .sourceTooLong(
                maximumUTF8Bytes: Self.maximumSourceUTF8Bytes,
                actualUTF8Bytes: sourceBytes
            )
        }
        let unknownOptions = options.rawValue & ~Options.caseInsensitive.rawValue
        guard unknownOptions == 0 else {
            throw .unsupportedOptions(rawValue: options.rawValue)
        }

        var parser = RegexParser(source)
        let syntax = try parser.parse()
        var compiler = RegexCompiler(maximumStates: Self.maximumCompiledStates)

        self.source = source
        self.options = options
        self.program = try compiler.finish(syntax, endOffset: sourceBytes)
    }

    /// Returns whether the expression occurs in `input` before its positive work budget.
    public func containsMatch(
        in input: String,
        maximumWork: Int = Self.defaultMaximumWork
    ) throws(RegexMatchError) -> Bool {
        guard maximumWork > 0 else { throw .invalidWorkLimit(maximumWork) }
        let inputBytes = input.utf8.count
        guard inputBytes <= Self.maximumInputUTF8Bytes else {
            throw .inputTooLong(
                maximumUTF8Bytes: Self.maximumInputUTF8Bytes,
                actualUTF8Bytes: inputBytes
            )
        }
        var meter = RegexWorkMeter(maximum: maximumWork)
        return try program.containsMatch(in: input, options: options, meter: &meter)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source && lhs.options == rhs.options
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(options)
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case options
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let source = try values.decode(String.self, forKey: .source)
        let options = try values.decode(Options.self, forKey: .options)
        do {
            try self.init(source, options: options)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .source,
                in: values,
                debugDescription: "invalid bounded regular expression: \(error)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(source, forKey: .source)
        try values.encode(options, forKey: .options)
    }
}
