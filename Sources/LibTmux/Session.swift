/// A tmux session, as it was when the listing was read.
///
/// This is a value, not a live handle: nothing here re-reads tmux, and two
/// copies never disagree. Ask the server again for a newer view.
///
/// ## What is on here
///
/// A `Session` carries no operations. What you do with one is a method on ``Server``, a lookup on a
/// ``Snapshot``, or a scope that names it, and each method that changes the session refuses a value
/// from another server (``TmuxError/foreignServerValue``), from a daemon that has been replaced
/// (``TmuxError/serverRestarted``), or whose ID no longer names it (``TmuxError/staleServerValue``).
/// The calls fall into a few groups:
///
/// **Reading it.** The properties are the values tmux reported when the listing was read. The ID is
/// stable for the session's lifetime and the name is not, because a session can be renamed. The
/// attached flag reads differently inside a connection, because opening one attaches a client.
///
/// - Identity: ``Session/id``, ``Session/incarnation``
/// - What it is called: ``Session/name``
/// - State: ``Session/windowCount``, ``Session/isAttached``, ``Session/createdAt``
///
/// **Finding it.** A lookup answers `nil` when tmux does not have the session and throws when the
/// server cannot answer. Session names are unique, so the lookup by name returns one session. A
/// refresh answers `nil` once the session has gone, and throws ``TmuxError/serverRestarted`` if the
/// ID now names something in a replacement daemon.
///
/// - By ID: ``Server/session(_:)``
/// - By name: ``Server/session(named:)``
/// - Exists, without returning it: ``Server/hasSession(_:)``
/// - Re-read a value you hold: ``Server/refresh(_:)-(Session)``
/// - Every session: ``Server/sessions()``, ``Server/sessions(where:)``
///
/// **Finding what is inside it.** A ``Snapshot`` answers without another tmux command, and answers
/// with an empty array for a session read from a different daemon.
///
/// - Windows and their links: ``Snapshot/windows(of:)``, ``Snapshot/windowLinks(of:)``
/// - Panes: ``Snapshot/panes(of:)-(Session)``
/// - Attached clients: ``Snapshot/clients(of:)``
///
/// **Adding to it.** Creating a window returns its ``WindowAppearance``, and an index that is
/// already taken fails. Creating a session returns the ``Session``.
///
/// - New session:
///   ``Server/newSession(named:startDirectory:windowName:width:height:environment:shell:)``
/// - New window: ``Server/newWindow(in:named:startDirectory:at:environment:shell:)``
/// - New window next to a window you name: ``Server/newWindow(_:_:named:startDirectory:)``
///
/// **Changing it.** Renaming stores the name as given, with no format expansion. Moving to the next window wraps at the end, and
/// detaching a session with no clients succeeds.
///
/// - Rename: ``Server/rename(_:to:)-(Session,String)``
/// - Move between windows: ``Server/selectNextWindow(in:)``, ``Server/selectPreviousWindow(in:)``,
///   ``Server/selectLastWindow(in:)``
/// - Detach its clients: ``Server/detachClients(from:)``
/// - Destroy it: ``Server/kill(_:)-(Session)``
///
/// **Options and hooks.** An option call takes an ``OptionScope``. The session scope reads and
/// writes the session's own table, and a read answers `nil` for a name that table does not hold; the
/// resolved read follows tmux's inheritance instead. tmux keeps hooks in a global table and one per
/// session, and none for windows or panes.
///
/// - Scope: ``OptionScope/session(_:)``, ``OptionScope/globalSession``
/// - Read: ``Server/options(_:)``, ``Server/option(_:scope:)``, ``Server/resolvedOption(_:scope:)``
/// - Write: ``Server/setOption(_:to:scope:)``, ``Server/unsetOption(_:scope:)``
/// - Hooks: ``HookScope/session(_:)``, ``Server/hooks(_:)``, ``Server/setHook(_:to:at:in:)``,
///   ``Server/unsetHook(_:in:)``, ``Server/runHook(_:in:)``
public struct Session: Sendable, Hashable, Codable, Identifiable {
    /// tmux's own session id, stable for the session's lifetime — `$0`, `$1`.
    /// Names are not: a session can be renamed, and two servers can both have
    /// a `0`.
    public let id: SessionID
    /// The daemon this value was read from.
    public let incarnation: ServerIncarnation
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
        id: SessionID,
        name: String,
        windowCount: Int,
        isAttached: Bool,
        createdAt: Int,
        incarnation: ServerIncarnation
    ) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.isAttached = isAttached
        self.createdAt = createdAt
        self.incarnation = incarnation
    }
}

extension Session {
    private static let idField = FormatField("session_id", .identifier(SessionID.sigil))
    private static let nameField = FormatField("session_name")
    private static let windowsField = FormatField("session_windows", .integer)
    // `session_attached` counts attached clients rather than reporting a flag,
    // so attachment is "not zero" rather than "== 1".
    private static let attachedField = FormatField("session_attached", .integer)
    private static let createdField = FormatField("session_created", .integer)

    static let projection = FormatProjection(
        [
            idField, nameField, windowsField, attachedField, createdField,
        ] + ServerIncarnation.projectionFields)

    init(row: FormatRow, endpoint: Endpoint) {
        self.init(
            id: row.identifier(Session.idField, as: SessionID.self),
            name: row.text(Session.nameField),
            windowCount: row.integer(Session.windowsField),
            isAttached: row.integer(Session.attachedField) != 0,
            createdAt: row.integer(Session.createdField),
            incarnation: ServerIncarnation(row: row, endpoint: endpoint)
        )
    }
}
