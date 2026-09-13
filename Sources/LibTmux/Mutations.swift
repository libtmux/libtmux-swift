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
