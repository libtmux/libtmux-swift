import Foundation

/// Where a split puts the pane it creates.
///
/// Named for where the new pane ends up, not for the axis it divides: `.left`
/// and `.right` both split side by side, and which one you get is the whole
/// question a caller has. tmux spells the other two as one flag and a modifier,
/// which is why "vertical" alone cannot say whether the pane appears above or
/// below.
public enum PaneDirection: Sendable, Hashable, Codable {
    /// Beside the existing pane, on its right. `split-window -h`.
    case right
    /// Beside the existing pane, on its left. `split-window -h -b`.
    case left
    /// Stacked over the existing pane. `split-window -v -b`.
    case above
    /// Stacked under the existing pane, which is tmux's own default.
    case below

    var flags: [String] {
        switch self {
        case .right: ["-h"]
        case .left: ["-h", "-b"]
        // `-v` is tmux's default and passing it changes nothing, but a reader
        // comparing these four lines should not have to know that.
        case .above: ["-v", "-b"]
        case .below: ["-v"]
        }
    }
}

/// How big a split makes the pane it creates.
///
/// Both spellings are one tmux flag, `-l`, which reads a percentage when the
/// value ends in `%`. Modelling them as separate cases keeps a caller from
/// building that string, and from having to remember which of the two a bare
/// number means.
public enum PaneSize: Sendable, Hashable, Codable {
    /// Columns for a side-by-side split, rows for a stacked one — the axis
    /// follows the direction, because that is the one the split divides.
    case cells(Int)
    /// A share of what the pane being split has, rounded down by tmux.
    case percentage(Int)

    var argument: String {
        switch self {
        case let .cells(count): "\(count)"
        case let .percentage(share): "\(share)%"
        }
    }
}

/// Where a new window goes relative to one that is already there.
///
/// Windows are ordered by index, and tmux renumbers on insert, so this says
/// what a caller means — next to *that* window — rather than an index that is
/// only correct until the next insertion.
public enum WindowPlacement: Sendable, Hashable, Codable {
    /// Takes the neighbour's index, pushing it and everything after it up.
    case before
    /// Goes immediately after the neighbour.
    case after

    var flag: String {
        switch self {
        case .before: "-b"
        case .after: "-a"
        }
    }
}

/// Which way a resize moves the boundary a pane shares with its neighbour.
///
/// Named for the boundary rather than for the pane, because that is what tmux
/// moves: a pane gains the space when the boundary moves away from it and loses
/// it when the boundary moves in. So resizing the lower of two stacked panes
/// `toward: .up` makes it taller, and resizing the upper one the same way makes
/// it shorter.
public enum ResizeDirection: Sendable, Hashable, Codable {
    case up
    case down
    case left
    case right

    var flag: String {
        switch self {
        case .up: "-U"
        case .down: "-D"
        case .left: "-L"
        case .right: "-R"
        }
    }
}

/// Creating, changing, and destroying tmux objects.
///
/// Every call addresses its target by the id tmux minted — `$0`, `@1`, `%2` —
/// never by index. Indices renumber when a sibling closes and `base-index`
/// makes even the first one configurable, so an index is a display value and an
/// id is identity.
///
/// Anything that creates an object returns it, read back through the same
/// projection a listing uses, so the caller never has to go looking for what it
/// just made.
extension Server {
    // MARK: Creating

    /// Creates a detached session.
    public func newSession(
        named name: String,
        startDirectory: String? = nil,
        windowName: String? = nil
    ) async throws(TmuxError) -> Session {
        var arguments = ["-d", "-P", "-F", Session.projection.template, "-s", name]
        if let windowName { arguments += ["-n", windowName] }
        if let startDirectory { arguments += ["-c", startDirectory] }
        let reply = try await run(TmuxCommand("new-session", arguments))
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let rows: [FormatRow]
        do {
            rows = try Session.projection.decode(reply.standardOutput)
        } catch {
            throw .decodingFailed(error)
        }
        guard rows.count == 1 else {
            throw .invocationFailed(reason: "tmux printed \(rows.count) sessions")
        }
        return Session(row: rows[0], endpoint: endpoint)
    }

    /// Creates a window in a session and returns its exact appearance.
    ///
    /// The appearance is read from the creation reply, after the windows
    /// already in the session when no relative placement is given.
    public func newWindow(
        in session: Session,
        named name: String? = nil,
        startDirectory: String? = nil
    ) async throws(TmuxError) -> WindowAppearance {
        try await newWindow(
            target: session.id.rawValue,
            placement: nil,
            named: name,
            startDirectory: startDirectory,
            guardedBy: [.session(session)]
        )
    }

    /// Creates a window next to one that already exists and returns its exact
    /// appearance.
    ///
    /// - Parameters:
    ///   - placement: which side of `neighbour` to take.
    ///   - neighbour: the session-local window link to sit next to. Its session
    ///     is the one the new window joins.
    ///   - name: what to call it. Left out, tmux names it after what runs in it.
    ///   - startDirectory: where the window's first pane starts.
    public func newWindow(
        _ placement: WindowPlacement,
        _ neighbour: WindowLink,
        named name: String? = nil,
        startDirectory: String? = nil
    ) async throws(TmuxError) -> WindowAppearance {
        try await newWindow(
            target: neighbour.target,
            placement: placement,
            named: name,
            startDirectory: startDirectory,
            guardedBy: [.windowLink(neighbour)]
        )
    }

    private func newWindow(
        target: String,
        placement: WindowPlacement?,
        named name: String?,
        startDirectory: String?,
        guardedBy values: [GuardedValue]
    ) async throws(TmuxError) -> WindowAppearance {
        var arguments = [
            "-d", "-P", "-F", WindowAppearance.projection.template, "-t", target,
        ]
        if let placement { arguments.append(placement.flag) }
        if let name { arguments += ["-n", name] }
        if let startDirectory { arguments += ["-c", startDirectory] }
        return try await windowAppearance(
            from: TmuxCommand("new-window", arguments),
            guardedBy: values
        )
    }

    /// Splits a window's active pane, returning the pane that appeared.
    ///
    /// - Parameters:
    ///   - window: the window to split. tmux splits whichever of its panes is
    ///     active; name a pane instead with ``split(_:direction:size:startDirectory:)``.
    ///   - direction: which side of that pane the new one takes. Defaults to
    ///     ``PaneDirection/below``, so that this and `tmux split-window` with
    ///     no flags do the same thing.
    ///   - size: how much of the pane being split to give the new one. Omitted,
    ///     tmux halves it.
    ///   - startDirectory: where the new pane starts. Omitted, tmux uses
    ///     the pane's own.
    public func splitWindow(
        _ window: Window,
        direction: PaneDirection = .below,
        size: PaneSize? = nil,
        startDirectory: String? = nil
    ) async throws(TmuxError) -> Pane {
        try await split(
            target: window.id.rawValue,
            direction: direction,
            size: size,
            startDirectory: startDirectory,
            guardedBy: [.window(window)]
        )
    }

    /// Splits one pane, returning the pane that appeared.
    ///
    /// The same call as ``splitWindow(_:direction:size:startDirectory:)`` with
    /// the ambiguity removed: a window has an active pane and tmux splits that
    /// one, which is what you want interactively and rarely what you want when
    /// building a layout.
    public func split(
        _ pane: Pane,
        direction: PaneDirection = .below,
        size: PaneSize? = nil,
        startDirectory: String? = nil
    ) async throws(TmuxError) -> Pane {
        try await split(
            target: pane.id.rawValue,
            direction: direction,
            size: size,
            startDirectory: startDirectory,
            guardedBy: [.pane(pane)]
        )
    }

    private func split(
        target: String,
        direction: PaneDirection,
        size: PaneSize?,
        startDirectory: String?,
        guardedBy values: [GuardedValue]
    ) async throws(TmuxError) -> Pane {
        var arguments = ["-d", "-P", "-F", "#{pane_id}", "-t", target]
        arguments += direction.flags
        if let size { arguments += ["-l", size.argument] }
        if let startDirectory { arguments += ["-c", startDirectory] }
        let id = try await identifier(
            from: TmuxCommand("split-window", arguments),
            guardedBy: values
        )
        return try await requirePane(id, incarnation: values[0].incarnation)
    }

    // MARK: Changing

    public func rename(_ session: Session, to name: String) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("rename-session", ["-t", session.id.rawValue, name]),
            guardedBy: [.session(session)]
        )
    }

    public func rename(_ window: Window, to name: String) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("rename-window", ["-t", window.id.rawValue, name]),
            guardedBy: [.window(window)]
        )
    }

    /// Applies one of tmux's own layouts — `even-horizontal`, `tiled`, and the
    /// rest — to a window.
    public func selectLayout(
        _ window: Window,
        _ layout: String
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("select-layout", ["-t", window.id.rawValue, layout]),
            guardedBy: [.window(window)]
        )
    }

    /// Sets a pane's size outright.
    ///
    /// Passing neither dimension does nothing rather than sending tmux a
    /// command with nothing to do.
    public func resize(
        _ pane: Pane,
        width: Int? = nil,
        height: Int? = nil
    ) async throws(TmuxError) {
        var arguments = ["-t", pane.id.rawValue]
        if let width { arguments += ["-x", String(width)] }
        if let height { arguments += ["-y", String(height)] }
        guard arguments.count > 2 else { return }
        try await expectSuccess(
            TmuxCommand("resize-pane", arguments),
            guardedBy: [.pane(pane)]
        )
    }

    /// Nudges a pane's boundary, leaving the rest of the layout to absorb it.
    ///
    /// The counterpart to setting a size outright: this is how you say "a
    /// little more room" without first reading what the pane has and doing the
    /// arithmetic. Which pane grows depends on the direction — see
    /// ``ResizeDirection``.
    public func resize(
        _ pane: Pane,
        by cells: Int,
        toward direction: ResizeDirection
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand(
                "resize-pane",
                ["-t", pane.id.rawValue, direction.flag, String(cells)]
            ),
            guardedBy: [.pane(pane)]
        )
    }

    // MARK: Destroying

    public func kill(_ session: Session) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("kill-session", ["-t", session.id.rawValue]),
            guardedBy: [.session(session)]
        )
    }

    public func kill(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("kill-window", ["-t", window.id.rawValue]),
            guardedBy: [.window(window)]
        )
    }

    public func kill(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("kill-pane", ["-t", pane.id.rawValue]),
            guardedBy: [.pane(pane)]
        )
    }

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

    // MARK: Reading one object back

    func identifier(
        from command: TmuxCommand,
        guardedBy values: [GuardedValue]? = nil
    ) async throws(TmuxError) -> String {
        let reply: TmuxReply
        if let values {
            reply = try await runGuarded(command, by: values)
        } else {
            reply = try await run(command)
        }
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let id = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw .invocationFailed(reason: "tmux printed no identifier")
        }
        return id
    }

    func windowAppearance(
        from command: TmuxCommand,
        guardedBy values: [GuardedValue]
    ) async throws(TmuxError) -> WindowAppearance {
        let reply = try await runGuarded(command, by: values)
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let rows: [FormatRow]
        do {
            rows = try WindowAppearance.projection.decode(reply.standardOutput)
        } catch {
            throw .decodingFailed(error)
        }
        guard rows.count == 1 else {
            throw .invocationFailed(reason: "tmux printed \(rows.count) window appearances")
        }
        return WindowAppearance(row: rows[0], endpoint: endpoint)
    }

    private func requirePane(
        _ id: String,
        incarnation: ServerIncarnation? = nil
    ) async throws(TmuxError) -> Pane {
        guard let pane = try await panes().first(where: { $0.id.rawValue == id }),
            incarnation == nil || pane.incarnation == incarnation
        else {
            throw .serverRestarted
        }
        return pane
    }

    func expectSuccess(_ command: TmuxCommand) async throws(TmuxError) {
        let reply = try await run(command)
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
    }

    func expectSuccess(
        _ command: TmuxCommand,
        guardedBy values: [GuardedValue]
    ) async throws(TmuxError) {
        let reply = try await runGuarded(command, by: values)
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
    }
}
