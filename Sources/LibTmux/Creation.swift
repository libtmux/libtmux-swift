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
    ///
    /// Environment entries are available to the first pane as it starts.
    public func newSession(
        named name: String,
        startDirectory: String? = nil,
        windowName: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        environment: [String: String] = [:]
    ) async throws(TmuxError) -> Session {
        let requestedSize = width != nil || height != nil
        let projection =
            requestedSize
            ? FormatProjection(Session.projection.fields + WindowAppearance.projection.fields)
            : Session.projection
        var arguments = [
            "-d", "-P", "-F", projection.template, "-s", tmuxLiteralArgument(name),
        ]
        if let width { arguments += ["-x", String(width)] }
        if let height { arguments += ["-y", String(height)] }
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard !name.isEmpty, !name.contains("="), !name.contains("\0"), !value.contains("\0")
            else {
                throw .invocationFailed(reason: "invalid session environment variable")
            }
            arguments += ["-e", tmuxLiteralArgument(name + "=" + value)]
        }
        if let windowName { arguments += ["-n", tmuxLiteralArgument(windowName)] }
        if let startDirectory {
            arguments += ["-c", tmuxLiteralArgument(startDirectory)]
        }
        let reply = try await run(TmuxCommand("new-session", arguments))
        guard reply.isSuccess else {
            throw .invocationFailed(reason: reply.errorText)
        }
        let rows: [FormatRow]
        do {
            rows = try projection.decode(reply.standardOutput)
        } catch {
            throw .decodingFailed(error)
        }
        guard rows.count == 1 else {
            throw .invocationFailed(reason: "tmux printed \(rows.count) sessions")
        }
        let session = Session(row: rows[0], endpoint: endpoint)
        guard requestedSize else { return session }

        let window = WindowAppearance(row: rows[0], endpoint: endpoint).window
        let widthChanged = width.map { $0 != window.width } ?? false
        let heightChanged = height.map { $0 != window.height } ?? false
        guard widthChanged || heightChanged else { return session }

        var resizeArguments = ["-t", window.id.rawValue]
        if let width { resizeArguments += ["-x", String(width)] }
        if let height { resizeArguments += ["-y", String(height)] }
        try await expectSuccess(
            TmuxCommand("resize-window", resizeArguments),
            guardedBy: [.window(window)]
        )
        return session
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
        if let name { arguments += ["-n", tmuxLiteralArgument(name)] }
        if let startDirectory {
            arguments += ["-c", tmuxLiteralArgument(startDirectory)]
        }
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
        if let startDirectory {
            arguments += ["-c", tmuxLiteralArgument(startDirectory)]
        }
        let id = try await identifier(
            from: TmuxCommand("split-window", arguments),
            guardedBy: values
        )
        return try await requirePane(id, incarnation: values[0].incarnation)
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

    /// Reads back the pane a split just made.
    ///
    /// A narrowed listing rather than every pane on the server: tmux printed
    /// the id, so there is no reason to fetch the rest and search them.
    private func requirePane(
        _ id: String,
        incarnation: ServerIncarnation? = nil
    ) async throws(TmuxError) -> Pane {
        guard let paneID = PaneID(rawValue: id) else {
            throw .invocationFailed(reason: "tmux printed an unusable pane id")
        }
        guard let pane = try await pane(paneID),
            incarnation == nil || pane.incarnation == incarnation
        else {
            throw .serverRestarted
        }
        return pane
    }
}
