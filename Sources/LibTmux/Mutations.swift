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
        var arguments = ["-d", "-P", "-F", "#{session_id}", "-s", name]
        if let windowName { arguments += ["-n", windowName] }
        if let startDirectory { arguments += ["-c", startDirectory] }
        let id = try await identifier(
            from: TmuxCommand("new-session", arguments)
        )
        return try await requireSession(id)
    }

    /// Creates a window in a session, after the ones already there.
    public func newWindow(
        in session: Session,
        named name: String? = nil,
        startDirectory: String? = nil
    ) async throws(TmuxError) -> Window {
        try await newWindow(
            target: session.id,
            placement: nil,
            named: name,
            startDirectory: startDirectory
        )
    }

    /// Creates a window next to one that already exists.
    ///
    /// - Parameters:
    ///   - placement: which side of `neighbour` to take.
    ///   - neighbour: the window to sit next to. Its session is the one the new
    ///     window joins.
    ///   - name: what to call it. Left out, tmux names it after what runs in it.
    ///   - startDirectory: where the window's first pane starts.
    public func newWindow(
        _ placement: WindowPlacement,
        _ neighbour: Window,
        named name: String? = nil,
        startDirectory: String? = nil
    ) async throws(TmuxError) -> Window {
        try await newWindow(
            target: neighbour.id,
            placement: placement,
            named: name,
            startDirectory: startDirectory
        )
    }

    private func newWindow(
        target: String,
        placement: WindowPlacement?,
        named name: String?,
        startDirectory: String?
    ) async throws(TmuxError) -> Window {
        var arguments = ["-d", "-P", "-F", "#{window_id}", "-t", target]
        if let placement { arguments.append(placement.flag) }
        if let name { arguments += ["-n", name] }
        if let startDirectory { arguments += ["-c", startDirectory] }
        let id = try await identifier(from: TmuxCommand("new-window", arguments))
        return try await requireWindow(id)
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
            target: window.id,
            direction: direction,
            size: size,
            startDirectory: startDirectory
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
            target: pane.id,
            direction: direction,
            size: size,
            startDirectory: startDirectory
        )
    }

    private func split(
        target: String,
        direction: PaneDirection,
        size: PaneSize?,
        startDirectory: String?
    ) async throws(TmuxError) -> Pane {
        var arguments = ["-d", "-P", "-F", "#{pane_id}", "-t", target]
        arguments += direction.flags
        if let size { arguments += ["-l", size.argument] }
        if let startDirectory { arguments += ["-c", startDirectory] }
        let id = try await identifier(from: TmuxCommand("split-window", arguments))
        return try await requirePane(id)
    }

    // MARK: Changing

    public func rename(_ session: Session, to name: String) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("rename-session", ["-t", session.id, name])
        )
    }

    public func rename(_ window: Window, to name: String) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("rename-window", ["-t", window.id, name])
        )
    }

    /// Applies one of tmux's own layouts — `even-horizontal`, `tiled`, and the
    /// rest — to a window.
    public func selectLayout(
        _ window: Window,
        _ layout: String
    ) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("select-layout", ["-t", window.id, layout])
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
        var arguments = ["-t", pane.id]
        if let width { arguments += ["-x", String(width)] }
        if let height { arguments += ["-y", String(height)] }
        guard arguments.count > 2 else { return }
        try await expectSuccess(TmuxCommand("resize-pane", arguments))
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
                ["-t", pane.id, direction.flag, String(cells)]
            )
        )
    }

    // MARK: Destroying

    public func kill(_ session: Session) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("kill-session", ["-t", session.id]))
    }

    public func kill(_ window: Window) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("kill-window", ["-t", window.id]))
    }

    public func kill(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(TmuxCommand("kill-pane", ["-t", pane.id]))
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
        var arguments = ["-t", pane.id]
        if literally { arguments.append("-l") }
        try await expectSuccess(TmuxCommand("send-keys", arguments + keys))
    }

    /// Runs a shell command line in a pane, as if typed.
    public func run(
        _ commandLine: String,
        in pane: Pane
    ) async throws(TmuxError) {
        try await sendKeys([commandLine, "Enter"], to: pane)
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
        var arguments = ["-p", "-t", pane.id]
        if includingHistory { arguments += ["-S", "-"] }
        let reply = try await run(TmuxCommand("capture-pane", arguments))
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        var text = reply.text
        // tmux terminates the last row; that newline is not an extra row.
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? [] : text.components(separatedBy: "\n")
    }

    // MARK: Reading one object back

    func identifier(
        from command: TmuxCommand
    ) async throws(TmuxError) -> String {
        let reply = try await run(command)
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let id = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw .invocationFailed(reason: "tmux printed no identifier")
        }
        return id
    }

    private func requireSession(_ id: String) async throws(TmuxError) -> Session {
        guard let session = try await sessions().first(where: { $0.id == id }) else {
            throw .serverRestarted
        }
        return session
    }

    private func requireWindow(_ id: String) async throws(TmuxError) -> Window {
        guard let window = try await windows().first(where: { $0.id == id }) else {
            throw .serverRestarted
        }
        return window
    }

    private func requirePane(_ id: String) async throws(TmuxError) -> Pane {
        guard let pane = try await panes().first(where: { $0.id == id }) else {
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
}
