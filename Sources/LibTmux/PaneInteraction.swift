import Foundation

extension Server {
    // MARK: Talking to a pane

    /// Sends keys to a pane.
    ///
    /// - Parameters:
    ///   - keys: what to send, one argument per key or literal string.
    ///   - pane: the pane to send them to.
    ///   - literally: sends the text as characters rather than letting tmux
    ///     read names like `Enter` or `C-c` out of it. Use it for anything
    ///     that came from a user.
    public func sendKeys(
        _ keys: [String],
        to pane: Pane,
        literally: Bool = false
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id.rawValue]
        if literally { arguments.append("-l") }
        try await expectSuccess(
            TmuxCommand("send-keys", arguments + keys),
            guardedBy: [.pane(pane)]
        )
    }

    /// Runs a shell command line in a pane, as if typed.
    public func run(
        _ commandLine: String,
        in pane: Pane
    ) async throws(TmuxError) {
        try await sendKeys([commandLine, "Enter"], to: pane)
    }

    /// How a command running *inside* a pane spells a tmux that reaches this
    /// server.
    ///
    /// A bare `tmux` there is whichever one is on the pane's `PATH`, which is
    /// not necessarily this one — and a client whose protocol version differs
    /// from the server's is refused with `server exited unexpectedly` rather
    /// than anything that names the cause. Composing a command with this
    /// instead removes both the `PATH` lookup and the guess about which server
    /// `$TMUX` refers to:
    ///
    /// ```swift
    /// try await server.run(
    ///     "make; \(server.shellInvocation) wait-for -S built",
    ///     in: pane
    /// )
    /// try await server.wait(for: "built")
    /// ```
    ///
    /// Quoted for a POSIX shell, so a path containing spaces survives being
    /// typed into one.
    public var shellInvocation: String {
        ([tmuxExecutablePath] + endpoint.addressArguments)
            .map(shellQuoted)
            .joined(separator: " ")
    }

    /// The pane's visible contents, one line per row.
    ///
    /// - Parameters:
    ///   - pane: the pane to read.
    ///   - includingHistory: reads the scrollback too, from its start.
    public func capture(
        _ pane: Pane,
        includingHistory: Bool = false
    ) async throws(TmuxError) -> [String] {
        try await capture(pane, startingAt: includingHistory ? .start : nil)
    }

    /// The pane's contents from `start` rows above the visible region.
    ///
    /// A reader that only takes the visible rows loses anything that scrolled
    /// past between two reads, which for a pane producing output quickly is
    /// most of it. A bounded lookback keeps that from depending on how fast the
    /// reader happened to be, without paying for a whole scrollback each time.
    func capture(
        _ pane: Pane,
        startingAt start: CaptureStart?
    ) async throws(TmuxError) -> [String] {
        var arguments = ["-p", "-t", pane.id.rawValue]
        switch start {
        case .none: break
        case .start: arguments += ["-S", "-"]
        case let .line(row): arguments += ["-S", "\(row)"]
        }
        let reply = try await runGuarded(
            TmuxCommand("capture-pane", arguments),
            by: [.pane(pane)],
            checkingTargets: false
        )
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        var text = reply.text
        // tmux terminates the last row; that newline is not an extra row.
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    // MARK: Reading a pane

    /// Where a capture begins, relative to the visible region.
    enum CaptureStart: Sendable, Hashable {
        /// The start of the pane's retained history.
        case start
        /// A row, counted as tmux counts them: `0` is the top of the visible
        /// region and negative goes back into the scrollback.
        case line(Int)
    }
}
