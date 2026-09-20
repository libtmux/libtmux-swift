import Foundation

extension TmuxError: CustomStringConvertible, LocalizedError {
    /// A readable diagnostic using the information retained by this case.
    ///
    /// Command arguments and raw decoded values are not included. Transport
    /// reasons and tmux's stderr remain diagnostic text, not a redacted log.
    public var description: String {
        switch self {
        case let .processLaunchFailed(reason):
            "Could not start the tmux client: \(reason)"
        case .requestNotSubmitted:
            "The control connection closed before the request was submitted."
        case let .invocationFailed(reason):
            "The tmux invocation failed: \(reason)"
        case let .rejectedLocally(reason):
            "Refused without invoking tmux: \(reason)"
        case let .commandTooLarge(actualBytes, maximumBytes):
            "The tmux command needs \(actualBytes) bytes; the limit is \(maximumBytes)."
        case let .commandFailed(command, exitCode, reason):
            "tmux \(command) exited with status \(exitCode): \(reason)"
        case let .outputLimitExceeded(perStreamBytes):
            "tmux output exceeded the per-stream limit of \(perStreamBytes) bytes."
        case let .timedOut(after):
            "tmux did not answer within \(after)."
        case .invalidEndpoint(.empty):
            "The tmux endpoint is empty."
        case let .invalidEndpoint(.socketPathTooLong(actualBytes, maximumBytes)):
            "The socket path needs \(actualBytes) bytes; the limit is \(maximumBytes)."
        case let .decodingFailed(error):
            error.description
        case .serverRestarted:
            "The tmux server restarted before the operation completed."
        case .foreignServerValue:
            "The value belongs to a different tmux endpoint."
        case .foreignPaneValue:
            "The value belongs to a different pane on this server."
        case .staleServerValue:
            "The tmux target no longer identifies the captured object."
        case .cancelled:
            "The tmux operation was cancelled."
        case .connectionClosed:
            "The tmux control connection closed while a command was waiting."
        case let .notificationBufferOverflow(limit):
            "The control notification buffer exceeded its limit of \(limit) events."
        case .outputContinuityLost:
            "Pane output changed beyond the retained checkpoint."
        }
    }

    public var errorDescription: String? { description }
}

extension FormatDecodingError: CustomStringConvertible, LocalizedError {
    /// The failed row and field, without the raw reply value.
    public var description: String {
        switch self {
        case let .fieldCountMismatch(rowIndex, expected, actual):
            "tmux reply row \(rowIndex) has \(actual) fields; expected \(expected)."
        case let .invalidEncoding(rowIndex):
            "tmux reply row \(rowIndex) has invalid text encoding."
        case let .invalidValue(rowIndex, field, _):
            "tmux reply row \(rowIndex) has an invalid value for \(field)."
        }
    }

    public var errorDescription: String? { description }
}

extension CardinalityError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .noMatch:
            "No objects matched the query."
        case let .multipleMatches(count):
            "The query matched \(count) objects; expected one."
        }
    }

    public var errorDescription: String? { description }
}

extension QueryConstructionError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .unknownField: "The key path does not identify a supported filter field."
        case let .invalidOperation(error): error.description
        }
    }

    public var errorDescription: String? { description }
}

extension FilterValidationError: CustomStringConvertible, LocalizedError {
    /// The invalid field or operation, without predicate values.
    public var description: String {
        switch self {
        case let .unknownField(field):
            "Unknown filter field: \(field)."
        case let .incompatibleOperation(field, type, _):
            "The filter operation is incompatible with \(field) (\(type.rawValue))."
        }
    }

    public var errorDescription: String? { description }
}

extension FilterLookupError: CustomStringConvertible, LocalizedError {
    /// The lookup failure, without the supplied value or regex source.
    public var description: String {
        switch self {
        case .missingValue: "The filter lookup needs a value after '='."
        case let .unknownField(field): "Unknown filter field: \(field)."
        case let .unknownOperator(operation): "Unknown filter operator: \(operation)."
        case let .operatorNotSupported(operation):
            "The filter field does not support the \(operation) operator."
        case .invalidRegularExpression: "The filter regular expression is invalid."
        case .valueNotOfFieldType: "The filter value does not match the field's type."
        }
    }

    public var errorDescription: String? { description }
}

extension RegexCompileError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .sourceTooLong(maximumUTF8Bytes, actualUTF8Bytes):
            "The regex source has \(actualUTF8Bytes) UTF-8 bytes; the limit is \(maximumUTF8Bytes)."
        case let .unsupportedOptions(rawValue):
            "The regex options contain unsupported bits: \(rawValue)."
        case let .nestingTooDeep(offset, maximum):
            "Regex nesting exceeds \(maximum) levels at UTF-8 byte \(offset)."
        case let .unexpectedToken(offset):
            "Unexpected regex token at UTF-8 byte \(offset)."
        case let .unterminatedGroup(offset):
            "Unterminated regex group at UTF-8 byte \(offset)."
        case let .unterminatedCharacterClass(offset):
            "Unterminated regex character class at UTF-8 byte \(offset)."
        case let .emptyCharacterClass(offset):
            "Empty regex character class at UTF-8 byte \(offset)."
        case let .invalidCharacterRange(offset):
            "Invalid regex character range at UTF-8 byte \(offset)."
        case let .invalidRepetition(offset):
            "Invalid regex repetition at UTF-8 byte \(offset)."
        case let .repetitionTooLarge(offset, maximum):
            "Regex repetition exceeds \(maximum) at UTF-8 byte \(offset)."
        case let .unsupportedConstruct(offset, construct):
            "Unsupported regex construct \(construct.rawValue) at UTF-8 byte \(offset)."
        case let .stateLimitExceeded(offset, maximum):
            "The regex exceeds \(maximum) compiled states at UTF-8 byte \(offset)."
        }
    }

    public var errorDescription: String? { description }
}

extension RegexMatchError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .invalidWorkLimit(limit):
            "The regex work limit must be positive; received \(limit)."
        case let .inputTooLong(maximumUTF8Bytes, actualUTF8Bytes):
            "The regex input has \(actualUTF8Bytes) UTF-8 bytes; the limit is \(maximumUTF8Bytes)."
        case let .workLimitExceeded(maximum):
            "Regex matching exceeded the work limit of \(maximum)."
        }
    }

    public var errorDescription: String? { description }
}

extension FilterSelectionError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .matching(error): error.description
        case let .cardinality(error): error.description
        }
    }

    public var errorDescription: String? { description }
}

extension FilteredListingError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .tmux(error): error.description
        case let .matching(error): error.description
        }
    }

    public var errorDescription: String? { description }
}

extension OutputWaitError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .tmux(error): error.description
        case let .matching(error): error.description
        }
    }

    public var errorDescription: String? { description }
}
