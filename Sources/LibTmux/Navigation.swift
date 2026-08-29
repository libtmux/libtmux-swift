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

    public func select(_ link: WindowLink) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("select-window", ["-t", link.target]),
            guardedBy: [.windowLink(link)]
        )
    }

    public func select(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("select-pane", ["-t", pane.id.rawValue]),
            guardedBy: [.pane(pane)]
        )
    }

    /// Moves to the next window of a session, wrapping at the end.
    public func selectNextWindow(in session: Session) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("next-window", ["-t", session.id.rawValue]),
            guardedBy: [.session(session)]
        )
    }

    public func selectPreviousWindow(in session: Session) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("previous-window", ["-t", session.id.rawValue]),
            guardedBy: [.session(session)]
        )
    }

    /// Returns to the window that was active before the current one.
    public func selectLastWindow(in session: Session) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("last-window", ["-t", session.id.rawValue]),
            guardedBy: [.session(session)]
        )
    }

    /// Returns to the pane that was active before the current one.
    ///
    /// tmux remembers one previous pane per window, so this is the pane
    /// ``select(_:)-(Pane)`` moved away from, not a history to walk back
    /// through.
    public func selectLastPane(in window: Window) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("last-pane", ["-t", window.id.rawValue]),
            guardedBy: [.window(window)]
        )
    }

    // MARK: Rearranging

    /// Swaps two window appearances. Their underlying window ids do not
    /// change, but both links move to new indices.
    public func swap(_ link: WindowLink, with other: WindowLink) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("swap-window", ["-s", link.target, "-t", other.target]),
            guardedBy: [.windowLink(link), .windowLink(other)]
        )
    }

    public func swap(_ pane: Pane, with other: Pane) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("swap-pane", ["-s", pane.id.rawValue, "-t", other.id.rawValue]),
            guardedBy: [.pane(pane), .pane(other)]
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
            TmuxCommand("rotate-window", [upward ? "-U" : "-D", "-t", window.id.rawValue]),
            guardedBy: [.window(window)]
        )
    }

    /// Cycles a window through tmux's preset layouts.
    public func nextLayout(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("next-layout", ["-t", window.id.rawValue]),
            guardedBy: [.window(window)]
        )
    }

    public func previousLayout(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("previous-layout", ["-t", window.id.rawValue]),
            guardedBy: [.window(window)]
        )
    }

    /// Moves a pane out into a window of its own, and returns its appearance.
    public func breakPane(
        _ pane: Pane,
        from source: WindowLink,
        named name: String? = nil
    ) async throws(TmuxError) -> WindowAppearance {
        _ = try expectedIncarnation([pane.incarnation, source.incarnation])
        guard pane.windowID == source.windowID else { throw .staleServerValue }
        let target = "\(source.target).\(pane.id.rawValue)"
        var arguments = [
            "-d", "-P", "-F", WindowAppearance.projection.template, "-s", target,
        ]
        if let name { arguments += ["-n", name] }
        var appearance = try await windowAppearance(
            from: TmuxCommand("break-pane", arguments),
            guardedBy: [.pane(pane), .windowLink(source)]
        )
        // Some releases ignore `-n` here and name the window after whatever is
        // running in it. Comparing the result rather than the version means
        // this corrects itself wherever the behaviour differs.
        if let name, appearance.window.name != name {
            try await rename(appearance.window, to: name)
            appearance = WindowAppearance(
                window: Window(
                    id: appearance.window.id,
                    name: name,
                    paneCount: appearance.window.paneCount,
                    width: appearance.window.width,
                    height: appearance.window.height,
                    incarnation: appearance.window.incarnation
                ),
                link: appearance.link
            )
        }
        return appearance
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
        var arguments = ["-s", pane.id.rawValue, "-t", window.id.rawValue]
        arguments += direction.flags
        if let size { arguments += ["-l", size.argument] }
        try await expectSuccess(
            TmuxCommand("join-pane", arguments),
            guardedBy: [.pane(pane), .window(window)]
        )
    }

    // MARK: Pane contents

    /// Clears a pane's visible screen and its scrollback.
    public func clearHistory(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("clear-history", ["-t", pane.id.rawValue]),
            guardedBy: [.pane(pane)]
        )
    }

    /// Sets a pane's title. The title is only shown when tmux is configured to
    /// display it, but it is always readable through a format.
    public func setTitle(
        _ title: String,
        of pane: Pane
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("select-pane", ["-t", pane.id.rawValue, "-T", title]),
            guardedBy: [.pane(pane)]
        )
    }

    // MARK: Clients

    /// Detaches a client from the server it is attached to.
    ///
    /// A server operation despite the name: it acts on a client the server
    /// already holds, so it needs no terminal of its own. The session the
    /// client was viewing is untouched. The daemon incarnation is guarded,
    /// but tmux cannot atomically compare `client_pid`; this detaches whichever
    /// current client has ``Client/name``.
    public func detach(_ client: Client) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("detach-client", ["-t", client.name]),
            guardedBy: [.client(client)]
        )
    }

    /// Detaches every client attached to a session.
    ///
    /// The session target and detach run in one guarded tmux queue item, so a
    /// client name cannot be reused between a listing and this operation.
    /// Detaching nothing is success.
    public func detachClients(from session: Session) async throws(TmuxError) {
        let reply = try await runGuarded(
            TmuxCommand("detach-client", ["-s", session.id.rawValue]),
            by: [.session(session)]
        )
        guard reply.isSuccess || reply.errorText == "no current client" else {
            throw .invocationFailed(reason: reply.errorText)
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

    package func killServer(
        expecting incarnation: ServerIncarnation
    ) async throws(TmuxError) {
        let reply = try await runTerminatingIsolated(
            TmuxCommand("kill-server"),
            expecting: incarnation,
            perStreamOutputLimit: 4_096
        )
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
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
        var arguments = ["-t", pane.id.rawValue]
        if killingExisting { arguments.append("-k") }
        try await expectSuccess(
            TmuxCommand("respawn-pane", arguments + command),
            guardedBy: [.pane(pane)]
        )
    }

    public func respawn(
        _ window: Window,
        running command: [String] = [],
        killingExisting: Bool = true
    ) async throws(TmuxError) {
        var arguments = ["-t", window.id.rawValue]
        if killingExisting { arguments.append("-k") }
        try await expectSuccess(
            TmuxCommand("respawn-window", arguments + command),
            guardedBy: [.window(window)]
        )
    }

    /// Copies everything a pane outputs to a shell command, or stops doing so
    /// when `command` is omitted.
    public func pipe(
        _ pane: Pane,
        to command: String? = nil
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id.rawValue]
        if let command { arguments.append(command) }
        try await expectSuccess(
            TmuxCommand("pipe-pane", arguments),
            guardedBy: [.pane(pane)]
        )
    }

}
