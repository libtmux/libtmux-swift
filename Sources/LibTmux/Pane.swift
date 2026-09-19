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
    /// Whether the pane's configured process has exited.
    public let isDead: Bool
    /// Whether tmux has disabled input to the pane.
    public let isInputOff: Bool
    /// The number of human-client modes stacked on the pane.
    public let modeCount: Int
    /// Whether input to this pane participates in synchronized-pane delivery.
    public let isSynchronized: Bool
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
    /// What the pane's configured process exited with, once ``isDead`` is set.
    ///
    /// `nil` while the pane is alive, which is the whole reason it is optional:
    /// ``isDead`` says a command finished and this says how, so a test harness
    /// can tell a passing run from a failing one without reading the screen.
    ///
    /// A pane only survives its command's exit when tmux is told to keep it —
    /// `remain-on-exit`, or `respawn-pane -k` into a pane that already has it
    /// set. Without that, tmux destroys the pane as its command ends and there
    /// is nothing left to read a status from.
    public let exitStatus: Int?
    /// The process id of the pane's own process — the shell, or whatever was
    /// started in its place — not the foreground process inside it.
    ///
    /// `nil` when tmux did not report it, which for a value decoded from an
    /// encoding older than these fields is every pane. Optional rather than a
    /// zero, because `0` is a process group to `kill(2)` rather than a
    /// missing answer.
    public let processID: Int?
    /// The pseudo-terminal tmux gave the pane, as a device path. `nil` when
    /// tmux did not report it.
    public let tty: String?
    /// The pane's title, which a program inside it can change. `nil` when
    /// tmux did not report it; a pane with no title of its own reports one
    /// tmux chose, never an empty string.
    public let title: String?
    /// The command the pane was created with, as tmux recorded it.
    ///
    /// Unlike ``currentCommand`` this does not follow the foreground process,
    /// so it still says what was asked for after the process has moved on or
    /// exited. Empty when the pane was created with no command of its own,
    /// and `nil` when tmux did not report it at all.
    public let startCommand: String?

    public init(
        id: PaneID,
        index: Int,
        width: Int,
        height: Int,
        isActive: Bool,
        isDead: Bool,
        isInputOff: Bool,
        modeCount: Int,
        isSynchronized: Bool,
        currentCommand: String,
        currentPath: String,
        isAtTop: Bool = false,
        isAtBottom: Bool = false,
        isAtLeft: Bool = false,
        isAtRight: Bool = false,
        windowID: WindowID,
        incarnation: ServerIncarnation,
        exitStatus: Int? = nil,
        processID: Int? = nil,
        tty: String? = nil,
        title: String? = nil,
        startCommand: String? = nil
    ) {
        self.exitStatus = exitStatus
        self.processID = processID
        self.tty = tty
        self.title = title
        self.startCommand = startCommand
        self.id = id
        self.index = index
        self.width = width
        self.height = height
        self.isActive = isActive
        self.isDead = isDead
        self.isInputOff = isInputOff
        self.modeCount = modeCount
        self.isSynchronized = isSynchronized
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
    private static let deadField = FormatField("pane_dead", .flag)
    private static let inputOffField = FormatField("pane_input_off", .flag)
    private static let modeCountField = FormatField("pane_in_mode", .integer)
    private static let synchronizedField = FormatField("pane_synchronized", .flag)
    private static let commandField = FormatField("pane_current_command")
    private static let pathField = FormatField("pane_current_path")
    private static let atTopField = FormatField("pane_at_top", .flag)
    private static let atBottomField = FormatField("pane_at_bottom", .flag)
    private static let atLeftField = FormatField("pane_at_left", .flag)
    private static let atRightField = FormatField("pane_at_right", .flag)
    private static let windowField = FormatField(
        "window_id", .identifier(WindowID.sigil))
    // Empty while the pane is alive, which is what `optionalInteger` is for.
    private static let exitStatusField = FormatField("pane_dead_status", .optionalInteger)
    private static let processField = FormatField("pane_pid", .integer)
    private static let ttyField = FormatField("pane_tty")
    private static let titleField = FormatField("pane_title")
    private static let startCommandField = FormatField("pane_start_command")

    /// Every field `Pane` reads from tmux's row, including the harness fields.
    ///
    /// The five added for a harness — exit status, pid, tty, title, start
    /// command — cost about 102 bytes a row, measured on tmux 3.7b: 37 panes
    /// went from 6,196 to 9,994 bytes, 61% wider. No extra round trip and no
    /// measurable time, since one `list-panes` still answers all of them, and
    /// even a 200-pane server stays far inside the 1 MiB reply cap. Kept whole
    /// rather than split into a narrow projection and a wide one, which would
    /// make every caller choose and every `Pane` mean two different things.
    static let projection = FormatProjection(
        [
            idField, indexField, widthField, heightField, activeField, deadField,
            inputOffField, modeCountField, synchronizedField,
            commandField, pathField, atTopField, atBottomField, atLeftField,
            atRightField, windowField,
            exitStatusField, processField, ttyField, titleField, startCommandField,
        ] + ServerIncarnation.projectionFields)

    init(row: FormatRow, endpoint: Endpoint) {
        self.init(
            id: row.identifier(Pane.idField, as: PaneID.self),
            index: row.integer(Pane.indexField),
            width: row.integer(Pane.widthField),
            height: row.integer(Pane.heightField),
            isActive: row.flag(Pane.activeField),
            isDead: row.flag(Pane.deadField),
            isInputOff: row.flag(Pane.inputOffField),
            modeCount: row.integer(Pane.modeCountField),
            isSynchronized: row.flag(Pane.synchronizedField),
            currentCommand: row.text(Pane.commandField),
            currentPath: row.text(Pane.pathField),
            isAtTop: row.flag(Pane.atTopField),
            isAtBottom: row.flag(Pane.atBottomField),
            isAtLeft: row.flag(Pane.atLeftField),
            isAtRight: row.flag(Pane.atRightField),
            windowID: row.identifier(Pane.windowField, as: WindowID.self),
            incarnation: ServerIncarnation(row: row, endpoint: endpoint),
            exitStatus: row.optionalInteger(Pane.exitStatusField),
            processID: row.integer(Pane.processField),
            tty: row.text(Pane.ttyField),
            title: row.text(Pane.titleField),
            startCommand: row.text(Pane.startCommandField)
        )
    }
}
