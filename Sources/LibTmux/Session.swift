/// A tmux session, as it was when the listing was read.
///
/// This is a value, not a live handle: nothing here re-reads tmux, and two
/// copies never disagree. Ask the server again for a newer view.
public struct Session: Sendable, Hashable, Codable, Identifiable {
    /// tmux's own session id, stable for the session's lifetime — `$0`, `$1`.
    /// Names are not: a session can be renamed, and two servers can both have
    /// a `0`.
    public let id: String
    /// What a person calls it, and what tmux matches when a command names a
    /// session. Renameable, so it is not an identity.
    public let name: String
    /// tmux's own count, so a caller needing only the number does not have to
    /// list the windows to get it.
    public let windowCount: Int
    /// Whether any client is looking at this session. Opening a connection
    /// attaches one, so this reads differently from inside
    /// ``Server/connected(attachingTo:_:)`` — see <doc:Modes>.
    public let isAttached: Bool
    /// When tmux created the session, in seconds since the epoch. tmux's clock,
    /// not this process's.
    public let createdAt: Int

    public init(
        id: String,
        name: String,
        windowCount: Int,
        isAttached: Bool,
        createdAt: Int
    ) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.isAttached = isAttached
        self.createdAt = createdAt
    }
}

extension Session {
    private static let idField = FormatField("session_id")
    private static let nameField = FormatField("session_name")
    private static let windowsField = FormatField("session_windows", .integer)
    // `session_attached` counts attached clients rather than reporting a flag,
    // so attachment is "not zero" rather than "== 1".
    private static let attachedField = FormatField("session_attached", .integer)
    private static let createdField = FormatField("session_created", .integer)

    static let projection = FormatProjection([
        idField, nameField, windowsField, attachedField, createdField,
    ])

    init(row: FormatRow) {
        self.init(
            id: row.text(Session.idField),
            name: row.text(Session.nameField),
            windowCount: row.integer(Session.windowsField),
            isAttached: row.integer(Session.attachedField) != 0,
            createdAt: row.integer(Session.createdField)
        )
    }
}
