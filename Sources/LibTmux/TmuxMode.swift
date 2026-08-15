/// How work reaches tmux.
///
/// One dial with two settings. Choosing one never changes the call you write or
/// the type you get back — ``Server/sessions()`` returns `[Session]` either way.
/// What changes is whether that crossed a process boundary or a connection that
/// was already open.
///
/// | Mode | What it does | When it wins |
/// | --- | --- | --- |
/// | ``direct`` | A tmux process per call | One call, or calls far apart |
/// | ``connected(to:)`` | One live connection for the scope | More than one call, and anything that wants to be told what changed |
///
/// ``Server/using(_:_:)`` takes one of these, so a program that decides at
/// runtime — a flag, a config file, a benchmark measuring both — writes the
/// choice as data instead of branching around two shapes of call.
public enum TmuxMode: Sendable, Hashable {
    /// A tmux process per call. The default, and the one nothing has to say.
    case direct

    /// One control-mode connection carrying every call in the scope.
    ///
    /// The session is part of the mode rather than a separate argument, because
    /// a connection is a client and tmux has no client attached to nothing: one
    /// with no target runs tmux's default command and *creates* a session. The
    /// session named here must already exist.
    case connected(to: String)
}
