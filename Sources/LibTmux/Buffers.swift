extension Server {
    // MARK: Buffers

    /// The server's paste buffers, most recent first.
    public func buffers() async throws(TmuxError) -> [TmuxBuffer] {
        let reply = try await run(
            TmuxCommand(
                "list-buffers",
                ["-F", "#{buffer_name}\(FormatProjection.separator)#{buffer_size}"]
            )
        )
        guard reply.isSuccess else { return [] }
        let projection = FormatProjection([
            FormatField("buffer_name"), FormatField("buffer_size", .integer),
        ])
        do {
            return try projection.decode(reply.standardOutput).map { row in
                TmuxBuffer(
                    name: row.text(FormatField("buffer_name")),
                    size: row.integer(FormatField("buffer_size"))
                )
            }
        } catch {
            throw .decodingFailed(error)
        }
    }

    /// Puts text into a named buffer.
    public func setBuffer(
        _ contents: String,
        named name: String? = nil
    ) async throws(TmuxError) {
        var arguments: [String] = []
        if let name { arguments += ["-b", name] }
        try await expectSuccess(TmuxCommand("set-buffer", arguments + [contents]))
    }

    /// Reads a buffer's contents, or `nil` if no such buffer exists.
    ///
    /// Runs in a process of its own even on a connected server, so that the
    /// answer does not depend on which mode asked. A connection reports a
    /// command's output as *lines*, and `show-buffer` writes the buffer as
    /// bytes with a terminator after them — so a buffer ending in a newline and
    /// one that does not arrive in the same shape as a listing whose last row
    /// is empty. Nothing on the wire tells the two apart, and every supported
    /// tmux behaves this way, so the bytes are read from a process instead of
    /// guessed at.
    public func buffer(named name: String? = nil) async throws(TmuxError) -> String? {
        var arguments: [String] = []
        if let name { arguments += ["-b", name] }
        let reply = try await runInOwnProcess(
            rawArguments: TmuxCommand("show-buffer", arguments).argumentVector
        )
        guard reply.isSuccess else { return nil }
        var text = reply.text
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    public func deleteBuffer(named name: String) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("delete-buffer", ["-b", name]))
    }

    /// Fills a buffer from a file, letting tmux read it.
    ///
    /// ``setBuffer(_:named:)`` carries the text as an argument, which caps it at
    /// whatever the platform allows in an argument vector and — over
    /// ``connected(attachingTo:_:)`` — forbids a newline outright, because a
    /// connection sends a command *line*. A path has neither problem: it is
    /// short, and tmux opens the file itself. This is the way to put many lines
    /// into a buffer from a connected server.
    ///
    /// The path is resolved by the tmux server, which for a socket on this
    /// machine is this machine.
    public func loadBuffer(
        from path: String,
        named name: String? = nil
    ) async throws(TmuxError) {
        var arguments: [String] = []
        if let name { arguments += ["-b", name] }
        try await expectSuccess(TmuxCommand("load-buffer", arguments + [path]))
    }

    /// Writes a buffer to a file, letting tmux do the writing.
    ///
    /// The counterpart to ``loadBuffer(from:named:)``, and the way to get a
    /// buffer larger than a reply out of tmux: ``buffer(named:)`` hands back
    /// what one command printed, while this streams to a path.
    public func saveBuffer(
        named name: String? = nil,
        to path: String
    ) async throws(TmuxError) {
        var arguments: [String] = []
        if let name { arguments += ["-b", name] }
        try await expectSuccess(TmuxCommand("save-buffer", arguments + [path]))
    }

    /// Pastes a buffer into a pane.
    public func paste(
        buffer name: String? = nil,
        into pane: Pane
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id.rawValue]
        if let name { arguments += ["-b", name] }
        try await expectSuccess(
            TmuxCommand("paste-buffer", arguments),
            guardedBy: [.pane(pane)]
        )
    }
}

/// One of the server's paste buffers.
public struct TmuxBuffer: Sendable, Hashable, Codable, Identifiable {
    /// A buffer is addressed by name, so that is its identity.
    public var id: String { name }
    /// tmux's name for the buffer — `buffer0` unless one was chosen.
    public let name: String
    /// How many bytes it holds. Listed rather than the contents, because a
    /// listing of every buffer would otherwise carry every paste ever made.
    public let size: Int

    public init(name: String, size: Int) {
        self.name = name
        self.size = size
    }
}
