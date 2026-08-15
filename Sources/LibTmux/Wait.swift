/// Synchronising with work tmux is running for you.
///
/// A pane runs a shell, and a shell says nothing about when it is finished.
/// Watching the pane for a prompt guesses; a channel does not. The command you
/// start signals when it is done, and ``Server/wait(for:)`` returns at that
/// point rather than on a timer.
///
/// ```swift
/// try await server.run("make && tmux wait-for -S built", in: pane)
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
    /// - Throws: ``TmuxError/serverRestarted`` if the server went away while
    ///   this was waiting. tmux releases its waiters when it shuts down, with
    ///   the same silent success a real signal produces, so the server's
    ///   identity before and after is what tells a release from a departure.
    ///   ``TmuxError/cancelled`` if the task was cancelled, which ends the
    ///   wait without a signal.
    public func wait(for channel: String) async throws(TmuxError) {
        let before = try await serverProcessID()
        let reply = try await runInOwnProcess(
            rawArguments: TmuxCommand("wait-for", [channel]).argumentVector
        )
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let after = try await serverProcessID()
        guard let before, let after, before == after else {
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
    public func signal(_ channel: String) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("wait-for", ["-S", channel]))
    }
}
