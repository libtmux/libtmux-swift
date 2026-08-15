/// A client attached to a tmux server.
public struct Client: Sendable, Hashable, Codable, Identifiable {
    /// The client's name, which is its terminal path for an ordinary client.
    public var id: String { name }
    /// tmux's name for the client, which for a terminal is the path of its
    /// tty. It is what a command targeting a client has to say.
    public let name: String
    /// The terminal device behind the client, empty for one with no terminal.
    public let tty: String
    /// The client process, which is not the server: killing it detaches rather
    /// than shutting anything down.
    public let processID: Int
    /// The terminal's width in cells, absent for a client that has no
    /// terminal. tmux reports it as empty for a control-mode connection, so
    /// `nil` is what it said rather than a zero this library invented.
    public let width: Int?
    /// The terminal's height in cells, absent on the same terms as ``width``.
    public let height: Int?
    /// Whether this client is a control-mode connection rather than a
    /// terminal.
    public let isControlMode: Bool
    /// The session the client is looking at. A client attaches to exactly one,
    /// and switching sessions changes this rather than making a new client.
    public let sessionID: String

    public init(
        name: String,
        tty: String,
        processID: Int,
        width: Int?,
        height: Int?,
        isControlMode: Bool,
        sessionID: String
    ) {
        self.name = name
        self.tty = tty
        self.processID = processID
        self.width = width
        self.height = height
        self.isControlMode = isControlMode
        self.sessionID = sessionID
    }
}

extension Client {
    private static let nameField = FormatField("client_name")
    private static let ttyField = FormatField("client_tty")
    private static let pidField = FormatField("client_pid", .integer)
    private static let widthField = FormatField("client_width", .optionalInteger)
    private static let heightField = FormatField("client_height", .optionalInteger)
    private static let controlField = FormatField("client_control_mode", .flag)
    private static let sessionField = FormatField("session_id")

    static let projection = FormatProjection([
        nameField, ttyField, pidField, widthField, heightField, controlField,
        sessionField,
    ])

    init(row: FormatRow) {
        self.init(
            name: row.text(Client.nameField),
            tty: row.text(Client.ttyField),
            processID: row.integer(Client.pidField),
            width: row.optionalInteger(Client.widthField),
            height: row.optionalInteger(Client.heightField),
            isControlMode: row.flag(Client.controlField),
            sessionID: row.text(Client.sessionField)
        )
    }
}
