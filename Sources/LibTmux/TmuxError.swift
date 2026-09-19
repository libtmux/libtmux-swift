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

    /// The command did not answer within the time allowed for it.
    ///
    /// Distinct from ``cancelled``, which is the caller's own task ending:
    /// this is a bound the caller asked for, through
    /// ``Server/withTimeout(_:)`` or a `timeout` argument. The action may have
    /// reached tmux — a daemon that stopped answering may still have run it —
    /// so a retry is not free of consequence.
    case timedOut(after: Duration)

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

    /// A value from another pane on the *same* server cannot stand in for
    /// this one.
    ///
    /// Distinct from ``foreignServerValue``: a cursor captured from a
    /// different pane on the server being asked is a mismatched argument, not
    /// evidence of a different daemon.
    case foreignPaneValue

    /// A command was refused before tmux ever saw it.
    ///
    /// Raised by a guard that rejects the argument outright -- a layout
    /// spelling tmux's own preset lookup does not resolve, for instance --
    /// so ``description`` never claims tmux was invoked.
    /// A rejection tmux itself made after receiving the command throws
    /// ``invocationFailed(reason:)`` with tmux's own text instead.
    case rejectedLocally(reason: String)

    /// A session-local target no longer names the object the value described.
    ///
    /// Raised by a guarded call that checks the target before dispatching the
    /// command, so it never carries tmux's own text -- tmux is never asked.
    /// Every mutating call and read on a captured object goes through this
    /// same atomic pre-check, so a gone pane, window, or session raises this
    /// case consistently rather than surfacing tmux's own "can't find ..."
    /// text from some methods and not others.
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
