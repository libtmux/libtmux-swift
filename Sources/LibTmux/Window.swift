/// A tmux window, as it was when the listing was read.
public struct Window: Sendable, Hashable, Codable, Identifiable {
    /// tmux's own window id — `@0`, `@1`. Stable for the window's lifetime;
    /// the index is not, because windows renumber when one is closed.
    public let id: String
    /// What tmux shows in the status line. Renameable and not unique, so it
    /// identifies a window to a person, not to code.
    public let name: String
    /// Position within its session. Renumbering makes this a display value,
    /// not an identity.
    public let index: Int
    /// tmux's own count, so a caller that needs only the number does not have
    /// to list the panes to get it.
    public let paneCount: Int
    /// The window a command reaches when it names the session and stops there.
    public let isActive: Bool
    /// The width tmux is drawing this window at, in cells. It follows
    /// whichever client is attached to the session, so it can differ between a
    /// session someone is looking at and one nobody is.
    public let width: Int
    /// The height tmux is drawing this window at, in cells, and on the same
    /// terms as ``width``.
    public let height: Int
    /// The session this window belongs to. A window can be linked into more
    /// than one session, in which case it appears once per session with the
    /// same ``id``.
    public let sessionID: String

    public init(
        id: String,
        name: String,
        index: Int,
        paneCount: Int,
        isActive: Bool,
        width: Int,
        height: Int,
        sessionID: String
    ) {
        self.id = id
        self.name = name
        self.index = index
        self.paneCount = paneCount
        self.isActive = isActive
        self.width = width
        self.height = height
        self.sessionID = sessionID
    }
}

extension Window {
    private static let idField = FormatField("window_id")
    private static let nameField = FormatField("window_name")
    private static let indexField = FormatField("window_index", .integer)
    private static let panesField = FormatField("window_panes", .integer)
    private static let activeField = FormatField("window_active", .flag)
    private static let widthField = FormatField("window_width", .integer)
    private static let heightField = FormatField("window_height", .integer)
    private static let sessionField = FormatField("session_id")

    static let projection = FormatProjection([
        idField, nameField, indexField, panesField, activeField, widthField,
        heightField, sessionField,
    ])

    init(row: FormatRow) {
        self.init(
            id: row.text(Window.idField),
            name: row.text(Window.nameField),
            index: row.integer(Window.indexField),
            paneCount: row.integer(Window.panesField),
            isActive: row.flag(Window.activeField),
            width: row.integer(Window.widthField),
            height: row.integer(Window.heightField),
            sessionID: row.text(Window.sessionField)
        )
    }
}
