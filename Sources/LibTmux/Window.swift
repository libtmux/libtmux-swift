/// One tmux window, independent of every session that links it.
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
