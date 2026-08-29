/// A tmux pane, as it was when the listing was read.
///
/// A pane belongs to one window; session membership runs through ``WindowLink``.
public struct Pane: Sendable, Hashable, Codable, Identifiable {
    /// tmux's own pane id — `%0`, `%1`.
    public let id: PaneID
    /// The daemon this value was read from.
    public let incarnation: ServerIncarnation
    /// Position within its window, renumbered as panes come and go.
    public let index: Int
    /// The width tmux is drawing this pane at, in cells.
    public let width: Int
    /// The height tmux is drawing this pane at, in cells.
    public let height: Int
    /// The pane a command reaches when it names the window and stops there.
    public let isActive: Bool
    /// The command tmux believes is running. It reflects the foreground
    /// process, so it changes as the user works.
    public let currentCommand: String
    /// The working directory of the process in the pane, which follows the
    /// user around rather than staying where the pane was created.
    public let currentPath: String
    /// Whether the pane reaches its window's top edge. A pane can be against
    /// more than one edge, and a lone pane is against all four.
    public let isAtTop: Bool
    /// Whether the pane reaches its window's bottom edge.
    public let isAtBottom: Bool
    /// Whether the pane reaches its window's left edge.
    public let isAtLeft: Bool
    /// Whether the pane reaches its window's right edge.
    public let isAtRight: Bool
    /// The window this pane is in. Panes move between windows, so this is
    /// where it is now rather than where it started.
    public let windowID: WindowID

    public init(
        id: PaneID,
        index: Int,
        width: Int,
        height: Int,
        isActive: Bool,
        currentCommand: String,
        currentPath: String,
        isAtTop: Bool = false,
        isAtBottom: Bool = false,
        isAtLeft: Bool = false,
        isAtRight: Bool = false,
        windowID: WindowID,
        incarnation: ServerIncarnation
    ) {
        self.id = id
        self.index = index
        self.width = width
        self.height = height
        self.isActive = isActive
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.isAtTop = isAtTop
        self.isAtBottom = isAtBottom
        self.isAtLeft = isAtLeft
        self.isAtRight = isAtRight
        self.windowID = windowID
        self.incarnation = incarnation
    }
}

extension Pane {
    private static let idField = FormatField("pane_id", .identifier(PaneID.sigil))
    private static let indexField = FormatField("pane_index", .integer)
    private static let widthField = FormatField("pane_width", .integer)
    private static let heightField = FormatField("pane_height", .integer)
    private static let activeField = FormatField("pane_active", .flag)
    private static let commandField = FormatField("pane_current_command")
    private static let pathField = FormatField("pane_current_path")
    private static let atTopField = FormatField("pane_at_top", .flag)
    private static let atBottomField = FormatField("pane_at_bottom", .flag)
    private static let atLeftField = FormatField("pane_at_left", .flag)
    private static let atRightField = FormatField("pane_at_right", .flag)
    private static let windowField = FormatField(
        "window_id", .identifier(WindowID.sigil))

    static let projection = FormatProjection(
        [
            idField, indexField, widthField, heightField, activeField,
            commandField, pathField, atTopField, atBottomField, atLeftField,
            atRightField, windowField,
        ] + ServerIncarnation.projectionFields)

    init(row: FormatRow, endpoint: Endpoint) {
        self.init(
            id: row.identifier(Pane.idField, as: PaneID.self),
            index: row.integer(Pane.indexField),
            width: row.integer(Pane.widthField),
            height: row.integer(Pane.heightField),
            isActive: row.flag(Pane.activeField),
            currentCommand: row.text(Pane.commandField),
            currentPath: row.text(Pane.pathField),
            isAtTop: row.flag(Pane.atTopField),
            isAtBottom: row.flag(Pane.atBottomField),
            isAtLeft: row.flag(Pane.atLeftField),
            isAtRight: row.flag(Pane.atRightField),
            windowID: row.identifier(Pane.windowField, as: WindowID.self),
            incarnation: ServerIncarnation(row: row, endpoint: endpoint)
        )
    }
}
