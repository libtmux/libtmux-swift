import Foundation

/// Choosing what is active, moving objects around, and the server's paste
/// buffers.
///
/// Everything tmux offers that needs an attached client to mean anything —
/// menus, popups, prompts, copy mode, key bindings — is deliberately absent.
/// Those are terminal interactions, not server operations, and a library that
/// wraps them hands back an API that silently does nothing when nobody is
/// looking at the terminal.
extension Server {
    // MARK: Choosing what is active

    public func select(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("select-window", ["-t", window.id]))
    }

    public func select(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("select-pane", ["-t", pane.id]))
    }

    /// Moves to the next window of a session, wrapping at the end.
    public func selectNextWindow(in session: Session) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("next-window", ["-t", session.id]))
    }

    public func selectPreviousWindow(in session: Session) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("previous-window", ["-t", session.id]))
    }

    /// Returns to the window that was active before the current one.
    public func selectLastWindow(in session: Session) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("last-window", ["-t", session.id]))
    }

    /// Returns to the pane that was active before the current one.
    ///
    /// tmux remembers one previous pane per window, so this is the pane
    /// ``select(_:)-(Pane)`` moved away from, not a history to walk back
    /// through.
    public func selectLastPane(in window: Window) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("last-pane", ["-t", window.id]))
    }

    // MARK: Rearranging

    /// Swaps two windows' positions. Their ids do not change, so values you
    /// already hold stay valid — only their indices move.
    public func swap(_ window: Window, with other: Window) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("swap-window", ["-s", window.id, "-t", other.id])
        )
    }

    public func swap(_ pane: Pane, with other: Pane) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("swap-pane", ["-s", pane.id, "-t", other.id])
        )
    }

    /// Shifts every pane in a window one position around the layout.
    ///
    /// The layout itself is untouched: the panes move through its positions,
    /// each taking the size and place of its neighbour. Ids do not change, so
    /// panes you already hold stay valid — but their indices do, which is what
    /// makes this different from ``swap(_:with:)-(Pane,Pane)``.
    ///
    /// - Parameters:
    ///   - window: the window whose panes move.
    ///   - upward: each pane takes the next numerically lower position, which
    ///     is tmux's own default. `false` sends them the other way.
    public func rotate(
        _ window: Window,
        upward: Bool = true
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("rotate-window", [upward ? "-U" : "-D", "-t", window.id])
        )
    }

    /// Cycles a window through tmux's preset layouts.
    public func nextLayout(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("next-layout", ["-t", window.id]))
    }

    public func previousLayout(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("previous-layout", ["-t", window.id]))
    }

    /// Moves a pane out into a window of its own, and returns that window.
    public func breakPane(
        _ pane: Pane,
        named name: String? = nil
    ) async throws(TmuxError) -> Window {
        var arguments = ["-d", "-P", "-F", "#{window_id}", "-s", pane.id]
        if let name { arguments += ["-n", name] }
        let id = try await identifier(from: TmuxCommand("break-pane", arguments))
        guard var window = try await windows().first(where: { $0.id == id }) else {
            throw .serverRestarted
        }
        // Some releases ignore `-n` here and name the window after whatever is
        // running in it. Comparing the result rather than the version means
        // this corrects itself wherever the behaviour differs.
        if let name, window.name != name {
            try await rename(window, to: name)
            guard let renamed = try await windows().first(where: { $0.id == id })
            else {
                throw .serverRestarted
            }
            window = renamed
        }
        return window
    }

    /// Moves a pane into another window, splitting it.
    ///
    /// A split that moves a pane rather than starting one, so it says where the
    /// pane goes the same way ``Server/splitWindow(_:direction:size:startDirectory:)``
    /// does — and defaults the same way, to ``PaneDirection/below``.
    public func join(
        _ pane: Pane,
        into window: Window,
        direction: PaneDirection = .below,
        size: PaneSize? = nil
    ) async throws(TmuxError) {
        var arguments = ["-s", pane.id, "-t", window.id]
        arguments += direction.flags
        if let size { arguments += ["-l", size.argument] }
        try await expectSuccess(TmuxCommand("join-pane", arguments))
    }

    // MARK: Pane contents

    /// Clears a pane's visible screen and its scrollback.
    public func clearHistory(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("clear-history", ["-t", pane.id]))
    }

    /// Sets a pane's title. The title is only shown when tmux is configured to
    /// display it, but it is always readable through a format.
    public func setTitle(
        _ title: String,
        of pane: Pane
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("select-pane", ["-t", pane.id, "-T", title])
        )
    }

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
        var arguments = ["-t", pane.id]
        if let name { arguments += ["-b", name] }
        try await expectSuccess(TmuxCommand("paste-buffer", arguments))
    }

    // MARK: Clients

    /// Detaches a client from the server it is attached to.
    ///
    /// A server operation despite the name: it acts on a client the server
    /// already holds, so it needs no terminal of its own. The session the
    /// client was viewing is untouched.
    public func detach(_ client: Client) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("detach-client", ["-t", client.name])
        )
    }

    /// Detaches every client attached to a session.
    ///
    /// Built from ``detach(_:)`` rather than `detach-client -s`, which needs a
    /// current client to resolve its target and so fails from a process that
    /// is not itself attached — exactly the caller this library serves.
    /// Detaching nothing is success, so teardown need not check first.
    public func detachClients(from session: Session) async throws(TmuxError) {
        for client in try await clients() where client.sessionID == session.id {
            try await detach(client)
        }
    }

    // MARK: Server lifetime

    /// Starts the server if it is not already running.
    public func startServer() async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("start-server"))
    }

    public func killServer() async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("kill-server"))
    }

    /// Loads a tmux configuration file into the running server.
    public func sourceFile(_ path: String) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("source-file", [path]))
    }

    /// Throws unless a server is listening.
    ///
    /// The listing accessors answer an unreachable server with an empty array,
    /// which is the right default and the wrong answer when you need to know.
    public func requireRunning() async throws(TmuxError) {
        guard try await isRunning() else {
            throw .invocationFailed(reason: "no tmux server at this endpoint")
        }
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

extension Server {
    // MARK: Replacing what runs

    /// Restarts the command in a pane.
    ///
    /// - Parameters:
    ///   - pane: the pane to restart.
    ///   - command: what to run instead. Omitted, tmux repeats the command
    ///     the pane was created with.
    ///   - killingExisting: replaces whatever is still running, rather
    ///     than refusing while the pane is busy.
    public func respawn(
        _ pane: Pane,
        running command: [String] = [],
        killingExisting: Bool = true
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id]
        if killingExisting { arguments.append("-k") }
        try await expectSuccess(TmuxCommand("respawn-pane", arguments + command))
    }

    public func respawn(
        _ window: Window,
        running command: [String] = [],
        killingExisting: Bool = true
    ) async throws(TmuxError) {
        var arguments = ["-t", window.id]
        if killingExisting { arguments.append("-k") }
        try await expectSuccess(TmuxCommand("respawn-window", arguments + command))
    }

    /// Copies everything a pane outputs to a shell command, or stops doing so
    /// when `command` is omitted.
    public func pipe(
        _ pane: Pane,
        to command: String? = nil
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id]
        if let command { arguments.append(command) }
        try await expectSuccess(TmuxCommand("pipe-pane", arguments))
    }

    // MARK: Moving windows between sessions

    /// Moves a window to another index, or into another session.
    public func move(
        _ window: Window,
        to destination: String
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("move-window", ["-s", window.id, "-t", destination])
        )
    }

    /// Links a window into another session. The same window then appears in
    /// both, sharing one id — which is tmux's model, not a copy.
    public func link(
        _ window: Window,
        into session: Session
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("link-window", ["-d", "-s", window.id, "-t", session.id])
        )
    }

    /// Removes one of a linked window's appearances. The window survives while
    /// any session still holds it.
    public func unlink(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("unlink-window", ["-t", window.id]))
    }

    // MARK: Options on one object

    /// Sets an option on one window, rather than on the window table as a
    /// whole.
    public func setOption(
        _ name: String,
        to value: String,
        of window: Window
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("set-option", ["-w", "-t", window.id, name, value])
        )
    }

    /// Reads an option from one window.
    public func option(
        _ name: String,
        of window: Window
    ) async throws(TmuxError) -> String? {
        let reply = try await run(
            TmuxCommand("show-options", ["-w", "-t", window.id, "-v", name])
        )
        guard reply.isSuccess else { return nil }
        var value = reply.text
        if value.hasSuffix("\n") { value.removeLast() }
        return value.isEmpty ? nil : value
    }
}
