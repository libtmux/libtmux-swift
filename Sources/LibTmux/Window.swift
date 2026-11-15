/// One tmux window, independent of every session that links it.
///
/// A window has no operations of its own, and neither does the ``WindowLink`` that places it in one
/// session. What you do with them is a method on ``Server`` or a lookup on a ``Snapshot``.
///
/// ## What is on here
///
/// The calls that take a window fall into a few groups. A method that changes one refuses a value
/// from another server (``TmuxError/foreignServerValue``), from a daemon that has been replaced
/// (``TmuxError/serverRestarted``), or whose ID no longer names it (``TmuxError/staleServerValue``).
///
/// **Reading it.** A window has one ID however many sessions link it. Its position in a session
/// belongs to the link, and a link's index changes when tmux reindexes.
///
/// - The window: ``Window/id``, ``Window/name``, ``Window/paneCount``, ``Window/width``,
///   ``Window/height``
/// - Its place in a session: ``WindowLink/index``, ``WindowLink/isActive``, ``WindowLink/target``
/// - Both from one reply: ``WindowAppearance``
///
/// **Finding it.** A lookup answers `nil` when tmux does not have the window. Window names are not
/// unique, so the lookup by name returns an array. A refresh answers `nil` once the window has gone.
///
/// - By ID: ``Server/window(_:)``
/// - By name: ``Server/windows(named:)``
/// - Re-read a value you hold: ``Server/refresh(_:)-(Window)``
/// - Every window, and every link: ``Server/windows()``, ``Server/windows(where:)``,
///   ``Server/windowLinks()``
/// - Which sessions show it: ``Snapshot/links(of:)``, ``Snapshot/sessions(of:)``
///
/// **Creating one.** Creating a window returns its ``WindowAppearance``, read from the creation
/// reply. Breaking a pane out returns the appearance of the window it now has.
///
/// - New window: ``Server/newWindow(in:named:startDirectory:at:environment:shell:)``
/// - New window next to a window you name: ``Server/newWindow(_:_:named:startDirectory:)``
/// - Move a pane into a window of its own: ``Server/breakPane(_:from:named:)``
///
/// **Splitting and arranging.** A split divides the window's active pane and returns the new
/// ``Pane``. A layout string is checked before tmux is asked to apply it, and a JSON layout document
/// needs tmux 3.8 or later. Rotating moves the panes through the layout and keeps their IDs.
///
/// - Split: ``Server/splitWindow(_:direction:size:startDirectory:environment:shell:)``
/// - Apply a layout: ``Server/selectLayout(_:_:)``
/// - Cycle through the presets: ``Server/nextLayout(_:)``, ``Server/previousLayout(_:)``
/// - Check layout strings first: ``Server/validateLayouts(_:)``
/// - Move panes through the layout: ``Server/rotate(_:upward:)``
/// - Panes it holds: ``Snapshot/panes(of:)-(Window)``
/// - The pane that was active before: ``Server/selectLastPane(in:)``
///
/// **Moving and linking.** Linking shows the same window, with the same ID, in a second session.
/// Removing a link leaves the window while any session still holds it.
///
/// - Move a window between sessions: ``Server/move(_:to:at:)``
/// - Show it in a second session: ``Server/link(_:into:)``
/// - Remove one appearance: ``Server/unlink(_:)``
/// - Exchange two windows: ``Server/swap(_:with:)-(WindowLink,WindowLink)``
/// - Make one active: ``Server/select(_:)-(WindowLink)``
///
/// **Changing it.** Renaming stores the name as given, with no format expansion. Restarting replaces what the window runs, and
/// kills what is still running by default.
///
/// - Rename: ``Server/rename(_:to:)-(Window,String)``
/// - Restart what it runs: ``Server/respawn(_:running:killingExisting:)``
/// - Destroy it: ``Server/kill(_:)-(Window)``
///
/// **Options and hooks.** An option call takes an ``OptionScope``. The window scope reads and writes
/// the window's own table, and a read answers `nil` for a name that table does not hold. tmux keeps
/// no hook table for a window.
///
/// - Scope: ``OptionScope/window(_:)``, ``OptionScope/globalWindow``
/// - Read: ``Server/options(_:)``, ``Server/option(_:scope:)``, ``Server/resolvedOption(_:scope:)``
/// - Write: ``Server/setOption(_:to:scope:)``, ``Server/unsetOption(_:scope:)``
public struct Window: Sendable, Hashable, Codable, Identifiable {
    public let id: WindowID
    public let incarnation: ServerIncarnation
    public let name: String
    public let paneCount: Int
    public let width: Int
    public let height: Int

    public init(
        id: WindowID,
        name: String,
        paneCount: Int,
        width: Int,
        height: Int,
        incarnation: ServerIncarnation
    ) {
        self.id = id
        self.name = name
        self.paneCount = paneCount
        self.width = width
        self.height = height
        self.incarnation = incarnation
    }
}

/// One session-local link to a window.
public struct WindowLink: Sendable, Hashable, Codable, Identifiable {
    public var id: WindowLinkID {
        WindowLinkID(sessionID: sessionID, index: index, windowID: windowID)
    }
    public let incarnation: ServerIncarnation
    public let sessionID: SessionID
    public let windowID: WindowID
    public let index: Int
    public let isActive: Bool

    public init(
        sessionID: SessionID,
        windowID: WindowID,
        index: Int,
        isActive: Bool,
        incarnation: ServerIncarnation
    ) {
        self.sessionID = sessionID
        self.windowID = windowID
        self.index = index
        self.isActive = isActive
        self.incarnation = incarnation
    }

    /// The exact link target tmux resolves in this session.
    public var target: String { "\(sessionID.rawValue):\(index)" }
}

/// One window and one session-local appearance, read from the same tmux reply.
///
/// Both properties are snapshots from one instant. ``Window/id`` identifies
/// the global window for its lifetime, while ``WindowLink/id`` identifies this
/// appearance only until tmux removes or reindexes the link.
public struct WindowAppearance: Sendable, Hashable, Codable {
    public let window: Window
    public let link: WindowLink
}

extension WindowAppearance {
    private static let idField = FormatField("window_id", .identifier(WindowID.sigil))
    private static let nameField = FormatField("window_name")
    private static let indexField = FormatField("window_index", .integer)
    private static let panesField = FormatField("window_panes", .integer)
    private static let activeField = FormatField("window_active", .flag)
    private static let widthField = FormatField("window_width", .integer)
    private static let heightField = FormatField("window_height", .integer)
    private static let sessionField = FormatField(
        "session_id", .identifier(SessionID.sigil))

    static let projection = FormatProjection(
        [
            idField, nameField, indexField, panesField, activeField, widthField,
            heightField, sessionField,
        ] + ServerIncarnation.projectionFields)

    init(row: FormatRow, endpoint: Endpoint) {
        let incarnation = ServerIncarnation(row: row, endpoint: endpoint)
        let windowID = row.identifier(Self.idField, as: WindowID.self)
        self.init(
            window: Window(
                id: windowID,
                name: row.text(Self.nameField),
                paneCount: row.integer(Self.panesField),
                width: row.integer(Self.widthField),
                height: row.integer(Self.heightField),
                incarnation: incarnation
            ),
            link: WindowLink(
                sessionID: row.identifier(Self.sessionField, as: SessionID.self),
                windowID: windowID,
                index: row.integer(Self.indexField),
                isActive: row.flag(Self.activeField),
                incarnation: incarnation
            )
        )
    }
}
