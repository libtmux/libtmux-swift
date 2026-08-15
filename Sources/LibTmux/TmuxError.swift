/// Everything a tmux operation can fail with.
///
/// A tmux command that runs and reports a nonzero status is a *reply*, not an
/// error — ``Server/run(_:)-(TmuxCommand)`` hands it back as ``TmuxReply`` so a caller can
/// read the diagnostic tmux wrote. This type covers the cases where no usable
/// reply exists at all.
public enum TmuxError: Error, Sendable, Hashable {
    /// tmux could not be started: it is missing, not executable, or the
    /// endpoint is unusable.
    case invocationFailed(reason: String)

    /// The endpoint is not addressable. A UNIX socket path has a hard length
    /// limit far shorter than the filesystem's, and exceeding it fails at bind
    /// time rather than at construction.
    case invalidEndpoint(InvalidEndpoint)

    /// tmux replied, but the reply did not match the requested projection.
    case decodingFailed(FormatDecodingError)

    /// The reply arrived from a different server than the one the request was
    /// prepared against.
    case serverRestarted

    /// The task was cancelled. A cancelled request never reports an empty
    /// listing — that would be indistinguishable from a server with no
    /// sessions.
    case cancelled

    /// A control-mode connection ended while a command was still waiting.
    ///
    /// Distinct from ``serverRestarted``: tmux says `%exit` when it is
    /// closing this client — because the session it was attached to went
    /// away, or the server is shutting down — which says nothing about a
    /// replacement daemon having appeared.
    case connectionClosed

    public enum InvalidEndpoint: Sendable, Hashable {
        case empty
        case socketPathTooLong(actualBytes: Int, maximumBytes: Int)
    }
}

/// A tmux reply that did not match its projection.
///
/// Each case names the row it failed on, so a caller can attribute a failure to
/// one object rather than discarding the whole listing.
public enum FormatDecodingError: Error, Sendable, Hashable {
    case fieldCountMismatch(rowIndex: Int, expected: Int, actual: Int)
    case invalidEncoding(rowIndex: Int)
    case invalidValue(rowIndex: Int, field: String, raw: String)
}

/// Why a lookup that expected exactly one match did not get one.
public enum CardinalityError: Error, Sendable, Hashable {
    case noMatch
    case multipleMatches(count: Int)
}
