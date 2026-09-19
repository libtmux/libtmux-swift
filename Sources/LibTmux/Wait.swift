/// Synchronising with work tmux is running for you.
///
/// A pane runs a shell, and a shell says nothing about when it is finished.
/// Watching the pane for a prompt guesses; a channel does not. The command you
/// start signals when it is done, and ``Server/wait(for:timeout:)`` returns at that
/// point rather than on a timer.
///
/// ```swift
/// try await server.run(
///     "make; \(server.shellInvocation) wait-for -S built",
///     in: pane
/// )
/// try await server.wait(for: "built")
/// ```
///
/// Channels are named by whoever uses them and are shared across the whole
/// server, so a name wants to be specific enough that two unrelated pieces of
/// work do not pick the same one.
extension Server {
    /// Blocks until something signals `channel`.
    ///
    /// Runs in a process of its own even on a connected server, because a
    /// control client runs one command at a time: carried over the connection
    /// this would hold back every call beside it, ``Server/signal(_:)``
    /// included, and nothing would ever release it.
    ///
    /// This has no `-L` (lock) counterpart on purpose. `wait-for -L` blocks
    /// every later locker of the same channel until it is unlocked, and tmux
    /// hands a released lock to whichever locker has been queued longest --
    /// including one whose client is long gone. Bounding a wait with Task
    /// cancellation, the only bound this method or ``Server/run(_:)-(TmuxCommand)`` offers,
    /// stops the caller from waiting forever; it does not and cannot remove
    /// that caller's place in tmux's own queue, so a timed-out lock wait can
    /// wedge the channel for every locker after it, permanently, for the life
    /// of the server. A caller that needs `-L` anyway reaches it through the
    /// raw escape hatch (``Server/run(_:)-(TmuxCommand)`` or ``ControlSession/send(_:)``
    /// with `TmuxCommand("wait-for", ["-L", channel])`) and accepts that risk
    /// explicitly, with no bound this library can add back.
    ///
    /// - Throws: ``TmuxError/serverRestarted`` if the server went away while
    ///   this was waiting. tmux releases its waiters when it shuts down, with
    ///   the same silent success a real signal produces, so the server's
    ///   identity before and after is what tells a release from a departure.
    ///   ``TmuxError/cancelled`` if the task was cancelled, which ends the
    ///   wait without a signal. ``TmuxError/timedOut(after:)`` if `timeout`
    ///   was given and elapsed first.
    ///
    /// - Parameters:
    ///   - channel: the channel to wait on.
    ///   - timeout: how long to wait before giving up. `nil`, the default,
    ///     waits for the signal however long it takes. This is asked for here
    ///     rather than taken from ``Server/commandTimeout`` because a wait is
    ///     *meant* to be slow: a server-wide bound on ordinary commands should
    ///     not turn every wait into a failure.
    public func wait(
        for channel: String,
        timeout: Duration? = nil
    ) async throws(TmuxError) {
        let before = try await serverProcessID()
        let arguments = TmuxCommand("wait-for", ["--", channel]).argumentVector
        let reply = try await withCommandDeadline(timeout) {
            try await self.runUnbounded(rawArguments: arguments)
        }
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let after = try await serverProcessID()
        guard before == after else {
            throw .serverRestarted
        }
    }

    /// Releases one waiter on `channel`.
    ///
    /// Signalling a channel nobody is waiting on does not queue: it leaves the
    /// channel ready, so the next wait returns at once and spends it. A second
    /// signal puts the channel back rather than storing a second release, so
    /// an unpaired signal is worth avoiding — what a later wait does depends
    /// on how many went unmatched, not how many were sent.
    ///
    /// Signalling never wedges a channel the way a lock (`-L`) can; see
    /// ``wait(for:timeout:)`` for that hazard, which is specific to the raw `-L`
    /// escape hatch and does not apply here.
    public func signal(_ channel: String) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("wait-for", ["-S", "--", channel]))
    }
}
