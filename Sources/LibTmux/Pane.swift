/// A tmux pane, as it was when the listing was read.
///
/// A pane belongs to one window; session membership runs through ``WindowLink``.
///
/// A pane has no operations of its own. What you do with one is a method on ``Server``, and each
/// takes the pane as an argument.
///
/// ## What is on here
///
/// The calls that take a pane fall into a few groups. A method that changes one refuses a value from
/// another server (``TmuxError/foreignServerValue``), from a daemon that has been replaced
/// (``TmuxError/serverRestarted``), or whose ID no longer names it (``TmuxError/staleServerValue``).
///
/// **Reading it.** The ID stays with the pane when it moves between windows, and the index does not.
/// The command and the path follow the process in the pane, so they change as the user works.
///
/// - Identity: ``Pane/id``, ``Pane/incarnation``, ``Pane/windowID``, ``Pane/index``
/// - Size and edges: ``Pane/width``, ``Pane/height``, ``Pane/isAtTop``, ``Pane/isAtBottom``,
///   ``Pane/isAtLeft``, ``Pane/isAtRight``
/// - What it runs: ``Pane/currentCommand``, ``Pane/currentPath``, ``Pane/isDead``
/// - State: ``Pane/isActive``, ``Pane/isInputOff``, ``Pane/modeCount``, ``Pane/isSynchronized``
///
/// **Finding it.** A lookup answers `nil` when tmux does not have the pane. A refresh re-reads what
/// the pane reports about itself, such as its size and what runs in it, and answers `nil` once the
/// pane has gone.
///
/// - By ID: ``Server/pane(_:)``
/// - Re-read a value you hold: ``Server/refresh(_:)-(Pane)``
/// - Every pane: ``Server/panes()``, ``Server/panes(where:)``
/// - Panes of a window: ``Snapshot/panes(of:)-(Window)``
///
/// **Sending input.** Keys are sent as named keys such as `Enter` unless you ask for them literally,
/// which is the choice for anything that came from a user. Running a command line types it and then
/// presses Enter.
///
/// - Send keys: ``Server/sendKeys(_:to:literally:)``
/// - Run a command line: ``Server/run(_:in:)``
/// - Spell this tmux for the pane: ``Server/shellInvocation``
///
/// **Reading output.** A plain capture returns one string per row, and its source read is capped at
/// 1 MiB. The bounded forms return a ``PaneCapture`` that counts the older rows they left out, and an
/// incremental capture continues from where an earlier one stopped.
///
/// - Visible rows, or with history: ``Server/capture(_:includingHistory:)``
/// - Newest rows only: ``Server/capture(_:includingHistory:maximumLines:)``
/// - A range of rows:
///   ``Server/captureRange(_:startingAt:endingAt:joiningWrappedLines:maximumLines:)``
/// - Continue from a cursor: ``Server/capture(_:since:limit:)``
/// - Wait for a match:
///   ``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)``
///
/// **Splitting and arranging.** A split returns the new pane and divides the pane you name. Giving
/// neither dimension to a resize does nothing. Joining moves a pane into another window, and rotating
/// keeps every ID and changes the indices.
///
/// - Split: ``Server/split(_:direction:size:startDirectory:environment:shell:)``
/// - Set the size: ``Server/resize(_:width:height:)``
/// - Move one boundary: ``Server/resize(_:by:toward:)``
/// - Zoom: ``Server/toggleZoom(_:)``
/// - Exchange two panes: ``Server/swap(_:with:)-(Pane,Pane)``
/// - Move it into another window: ``Server/join(_:into:direction:size:)``
/// - Move it into a window of its own: ``Server/breakPane(_:from:named:)``
/// - Make it active: ``Server/select(_:)-(Pane)``, ``Server/selectLastPane(in:)``
///
/// **Modes, titles and history.** Cancelling modes clears every mode on the pane, not only copy
/// mode. Clearing history leaves the visible screen as it is. Piping expands the command as a tmux
/// format first, so a `#(...)` in it runs.
///
/// - Copy mode: ``Server/enterCopyMode(_:)``, ``Server/cancelModes(in:)``
/// - Scrollback: ``Server/clearHistory(_:)``
/// - Title: ``Server/setTitle(_:of:)``
/// - Copy its output to a command: ``Server/pipe(_:to:)``
///
/// **Changing it.** Restarting repeats the command the pane was created with unless you give another,
/// and kills what is still running by default.
///
/// - Restart: ``Server/respawn(_:running:killingExisting:startDirectory:)``
/// - Destroy it: ``Server/kill(_:)-(Pane)``
///
/// **Options.** An option call takes an ``OptionScope``. The pane scope reads and writes the pane's
/// own table. tmux keeps no hook table for a pane.
///
/// - Scope: ``OptionScope/pane(_:)``
/// - Read: ``Server/options(_:)``, ``Server/option(_:scope:)``, ``Server/resolvedOption(_:scope:)``
/// - Write: ``Server/setOption(_:to:scope:)``, ``Server/unsetOption(_:scope:)``
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
        incarnation: ServerIncarnation
    ) {
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

    static let projection = FormatProjection(
        [
            idField, indexField, widthField, heightField, activeField, deadField,
            inputOffField, modeCountField, synchronizedField,
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
            incarnation: ServerIncarnation(row: row, endpoint: endpoint)
        )
    }
}
