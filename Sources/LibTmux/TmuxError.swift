/// Everything a tmux operation can fail with.
///
/// ``Server/run(_:)-(TmuxCommand)`` hands every tmux status back as a
/// ``TmuxReply``. Higher-level operations that promise a decoded value throw
/// ``commandFailed(command:exitCode:reason:)`` when tmux rejects that read.
public enum TmuxError: Error, Sendable, Hashable {
    /// The tmux client process was never started, so the requested command
    /// cannot have reached a daemon.
    case processLaunchFailed(reason: String)

    /// A control connection closed before the command was enqueued. Retrying
    /// cannot duplicate the requested action because tmux never received it.
    case requestNotSubmitted

    /// No usable reply was obtained after submission. Unless a narrower error
    /// says otherwise, the action may have reached tmux.
    case invocationFailed(reason: String)

    /// A direct tmux client cannot encode the command, so it was not submitted.
    case commandTooLarge(actualBytes: Int, maximumBytes: Int)

    /// tmux received a typed command but rejected it.
    ///
    /// Only the command name is retained; arguments may contain pane text,
    /// environment values, or other caller data that does not belong in an error.
    case commandFailed(command: String, exitCode: Int32, reason: String)

    /// A reply exceeded its finite per-stream memory boundary.
    case outputLimitExceeded(perStreamBytes: Int)

    /// The endpoint is not addressable. A UNIX socket path has a hard length
    /// limit far shorter than the filesystem's, and exceeding it fails at bind
    /// time rather than at construction.
    case invalidEndpoint(InvalidEndpoint)

    /// tmux replied, but the reply did not match the requested projection.
    case decodingFailed(FormatDecodingError)

    /// The reply arrived from a different server than the one the request was
    /// prepared against.
    case serverRestarted

    /// A value from another endpoint cannot target this server.
    case foreignServerValue

    /// A target no longer names the object or context the value described.
    case staleServerValue

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

    /// An observer did not drain control notifications before its finite
    /// buffer filled. Earlier buffered notifications remain readable.
    case notificationBufferOverflow(limit: Int)

    /// A pane changed beyond the retained checkpoint while output was being
    /// watched, so new rows cannot be separated from rows already seen.
    case outputContinuityLost

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
