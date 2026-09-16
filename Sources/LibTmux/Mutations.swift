import Foundation

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

/// A named tmux window layout or an explicitly supplied custom layout.
///
/// Encodes as tmux's layout string, so stored layouts and tmuxp documents keep
/// their existing wire representation. Custom strings are validated by tmux
/// when applied, allowing layouts saved from `window_layout` and future names.
///
/// Restoring a saved layout onto the window it came from puts every pane back
/// in its cell only from a JSON string (tmux 3.8 and later, read by a client
/// that has negotiated it -- see ``Server/connected(attachingTo:_:)``): the
/// classic string carries cell positions but no pane identity, so a pane can
/// land in a different cell of the same shape (verified against tmux 3.7c).
/// Applying a saved layout to a window with a different pane count is not
/// refused either way -- tmux fits what panes there are to the tree and drops
/// the rest, silently.
///
/// One shape is checked before that, not after: a JSON-encoded layout --
/// `window_layout` on tmux 3.8 and later -- reads back a `{`-prefixed string,
/// and applying that to a server older than 3.8 is not merely rejected. tmux
/// 3.3 and 3.3a free an uninitialized `cause` while rejecting a layout their
/// grammar does not recognize, which JSON is not, and any string reaching
/// that path there kills the daemon rather than reporting an error (fixed in
/// 3.4). `Server.selectLayout` guards this: it refuses a `{`-shaped layout
/// client-side rather than dispatching it, either because the string is not
/// valid JSON at all (every version) or because the server is older than 3.8
/// (that version and later apply it normally).
public struct WindowLayout: Sendable, Hashable, Codable {
    /// The text passed to tmux's `select-layout` command.
    public let rawValue: String

    private init(_ value: String) { rawValue = value }

    public static let evenHorizontal = Self("even-horizontal")
    public static let evenVertical = Self("even-vertical")
    public static let mainHorizontal = Self("main-horizontal")
    public static let mainVertical = Self("main-vertical")
    public static let tiled = Self("tiled")

    /// Uses a saved layout or a layout name supplied at runtime.
    public static func custom(_ value: String) -> Self { Self(value) }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Whether a layout string is the JSON form, decided exactly as tmux's own
/// `layout_construct` decides it: skip leading whitespace, then look at one
/// byte. Nothing past that byte is inspected here.
private func layoutOpensAsJSON(_ layout: String) -> Bool {
    layout.first(where: { !$0.isWhitespace }) == "{"
}

/// Whether a `{`-shaped layout is at least syntactically valid JSON.
///
/// Answers nothing about whether tmux's own reader would accept the
/// object's fields — that is `layout_parse_json`'s job on the versions that
/// have it, and this never looks past `{"V":...,"L":{...}}`'s outermost
/// braces to check.
private func isSyntacticallyValidJSON(_ layout: String) -> Bool {
    guard let data = layout.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
}

extension Server {
    // MARK: Changing

    public func rename(_ session: Session, to name: String) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand(
                "rename-session", ["-t", session.id.rawValue, "--", tmuxLiteralArgument(name)]),
            guardedBy: [.session(session)]
        )
    }

    public func rename(_ window: Window, to name: String) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand(
                "rename-window", ["-t", window.id.rawValue, "--", tmuxLiteralArgument(name)]),
            guardedBy: [.window(window)]
        )
    }

    /// Applies a named or custom layout to a window.
    public func selectLayout(
        _ window: Window,
        _ layout: WindowLayout
    ) async throws(TmuxError) {
        try await selectLayout(window, layout.rawValue)
    }

    /// Applies one of tmux's own layouts — `even-horizontal`, `tiled`, and the
    /// rest — to a window.
    ///
    /// A `{`-shaped `layout` — the JSON `window_layout` tmux 3.8 and later
    /// report — is checked before it reaches tmux at all, rather than after:
    /// see ``WindowLayout`` for why. This never inspects the JSON body past
    /// confirming it parses; the shape it accepts or rejects is exactly what
    /// `layout_construct` accepts or rejects, not a grammar of its own.
    public func selectLayout(
        _ window: Window,
        _ layout: String
    ) async throws(TmuxError) {
        if layoutOpensAsJSON(layout) {
            guard isSyntacticallyValidJSON(layout) else {
                throw .invocationFailed(
                    reason:
                        "layout is not valid JSON: \(layout.debugDescription)"
                )
            }
            // tmux 3.8 (commit bf43fdc0, tag 3.8-rc, verified against
            // ~/study/c/tmux) is the first release with a JSON layout
            // reader. Every earlier release runs the same string past its
            // checksum-prefixed grammar instead, which a JSON string never
            // matches; on 3.4 and later that fails cleanly, but 3.3 and
            // 3.3a's rejection path frees an uninitialized `cause` and kills
            // the daemon (see ``WindowLayout``). A `next-3.8` build is
            // deliberately excluded too — TmuxVersion.< ranks a development
            // build below the release it names, since which commit it was
            // built from, and so whether this reader is even in it yet, is
            // exactly what a preview build does not promise.
            let running = try await version()
            guard running >= TmuxVersion(major: 3, minor: 8) else {
                throw .invocationFailed(
                    reason:
                        "a JSON layout needs tmux 3.8 or later; this server reports "
                        + "\(running), and forwarding one to 3.3 or 3.3a crashes it "
                        + "rather than being rejected"
                )
            }
        }
        try await expectSuccess(
            TmuxCommand("select-layout", ["-t", window.id.rawValue, "--", layout]),
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

    /// Toggles whether one pane fills its window.
    public func toggleZoom(_ pane: Pane) async throws(TmuxError) {
        try await expectSuccess(
            TmuxCommand("resize-pane", ["-Z", "-t", pane.id.rawValue]),
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
