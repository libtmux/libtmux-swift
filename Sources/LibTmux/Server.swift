import Foundation

/// A tmux server, addressed by its endpoint.
///
/// `Server` is a value: copying one is free, copies compare equal, and passing
/// one across a task boundary needs no ceremony. The mutable part — the process
/// boundary and anything cached about the running daemon — lives behind an
/// actor that every copy shares, so two copies of the same server coordinate
/// with each other rather than racing.
///
/// Addressing a server does not start it. Every command carries the endpoint you gave, so no call
/// reaches a server you did not name. Name none, with
/// ``Server/init(tmuxExecutable:configurationFile:environment:)``, and tmux picks the server itself
/// unless `LIBTMUX_SOCKET` or `LIBTMUX_SOCKET_PATH` names one. What a call returns — a ``Session``,
/// ``Window``, ``Pane``, or ``Client`` — is a value as it stood when tmux was asked, and it carries
/// no operations: to act on one, pass it to a method here. A method that changes what a value names
/// refuses the value, rather than acting on whatever tmux has since given that ID, if it came from
/// another server (``TmuxError/foreignServerValue``) or from a daemon that has been replaced
/// (``TmuxError/serverRestarted``), or if its ID no longer names the object it described
/// (``TmuxError/staleServerValue``). The last two are checked inside the tmux command that acts.
///
/// ## What is on here
///
/// A tmux server does a great many things, so this type has a great many methods. They fall into a
/// few groups:
///
/// **Connecting.** The initializers address a server without starting it. A program running inside
/// tmux finds its server through its ``TmuxContext``, and a discovery call lists the servers
/// already running. The running check answers whether anything is listening, the required form
/// throws when nothing is, and a third call starts the daemon. The version call reads the tmux
/// binary's version, so it answers before any daemon exists, while the incarnation and the process
/// ID identify the daemon that is running. Running a scope in a ``TmuxMode`` sends each command
/// either to a process of its own or over one control-mode connection, and two calls open that
/// connection and hand it to you.
///
/// - Address a server without starting it:
///   ``Server/init(socketPath:tmuxExecutable:configurationFile:)``,
///   ``Server/init(socketName:tmuxExecutable:configurationFile:)``,
///   ``Server/init(tmuxExecutable:configurationFile:environment:)``
/// - What was addressed: ``Server/endpoint``, ``Server/tmuxExecutable``
/// - How commands reach it: ``Server/mode``
/// - From inside tmux: ``TmuxContext/current(environment:)``,
///   ``TmuxContext/server(tmuxExecutable:)``
/// - Servers already running: ``TmuxServers/discover(in:tmuxExecutable:)``
/// - Is anything listening: ``Server/isRunning()``
/// - Require a listening server: ``Server/requireRunning()``
/// - Start the daemon: ``Server/startServer()``
/// - Read the tmux binary's version: ``Server/version()``
/// - Identify the running daemon: ``Server/incarnation()``, ``Server/serverProcessID()``
/// - Run a scope in a mode: ``Server/using(_:_:)``
/// - Open the connection: ``Server/connected(attachingTo:_:)``,
///   ``Server/withControlMode(attachingTo:_:)``
///
/// **Finding one thing.** Look up a session, window or pane by ID, or a session or windows by name.
/// Each lookup answers `nil`, or an empty array for the plural, when tmux does not have it, and
/// throws when the server cannot answer. Window names are not unique, which is why the lookup by
/// window name returns an array. A session can be checked for by name or ID without returning it,
/// and a value you hold can be refreshed. A refresh answers `nil` once the object has gone. If the
/// daemon was replaced and the ID names something in the new one, it throws
/// ``TmuxError/serverRestarted`` instead, because tmux numbers IDs from zero again.
///
/// - By ID: ``Server/session(_:)``, ``Server/window(_:)``, ``Server/pane(_:)``
/// - By name: ``Server/session(named:)``, ``Server/windows(named:)``
/// - By name or ID, without returning it: ``Server/hasSession(_:)``
/// - Re-read a value you hold: ``Server/refresh(_:)-(Session)``, ``Server/refresh(_:)-(Window)``,
///   ``Server/refresh(_:)-(Pane)``
///
/// **Listing everything.** Each call reads one tmux listing. A failed listing throws rather than
/// reading as an empty server; use ``Server/isRunning()`` when absence is an expected answer. A
/// window linked into several sessions appears once in the window listing and once per session in
/// the window-link listing. Taking a snapshot reads every listing as one ``Snapshot`` and throws
/// ``TmuxError/serverRestarted`` if a different daemon bound the socket in between. It is not a
/// transaction: another client can still change the same daemon between the listings.
///
/// - Listings: ``Server/sessions()``, ``Server/windows()``, ``Server/windowLinks()``,
///   ``Server/panes()``, ``Server/clients()``
/// - Every listing as one snapshot: ``Server/snapshot()``
///
/// **Querying things and getting around.** Each filtered listing takes a ``FilterExpr``. tmux
/// evaluates as much of it as its format language can express before the rows cross the process
/// boundary, and the rest is applied here, so the answer is the one filtering the full listing
/// would give; the filtered client listing applies all of it here. Filtered listings throw
/// ``FilteredListingError``, which keeps a tmux failure apart from a regular expression that ran
/// out of budget. `exactlyOne(_:)` takes the one element a filter matches from any listing, and
/// ``FilterSelectionError`` tells no match from several. To move between levels without another
/// tmux command, ask a ``Snapshot``. Selecting the sessions where some, every, or no pane matches
/// takes a ``RelationQuantifier``, and panes can be selected by a filter on their session. A
/// ``Pane`` carries its window ID and a ``Client`` its session ID, so a value you hold leads back
/// up.
///
/// - Filter a listing: ``Server/sessions(where:)``, ``Server/windows(where:)``,
///   ``Server/panes(where:)``, ``Server/clients(where:)``
/// - Go down a level: ``Snapshot/windows(of:)``, ``Snapshot/panes(of:)-(Window)``,
///   ``Snapshot/panes(of:)-(Session)``
/// - Go up a level: ``Snapshot/sessions(of:)``, ``Snapshot/session(of:)``
/// - Sessions by their panes: ``Snapshot/sessions(_:ofPanes:)``
/// - Panes by their session: ``Snapshot/panes(inSession:)``
/// - Back up from a value you hold: ``Pane/windowID``, ``Client/sessionID``
///
/// **Changing things.** Creating returns what was made: creating a session returns the ``Session``,
/// creating a window returns a ``WindowAppearance``, and a split returns the new ``Pane``. A split
/// divides a window's active pane or the pane you name. Killing destroys one object, killing the
/// server stops the daemon, and renaming changes the name of a session or a window. Selecting
/// chooses what is active.
///
/// - New session:
///   ``Server/newSession(named:startDirectory:windowName:width:height:environment:shell:)``
/// - New window: ``Server/newWindow(in:named:startDirectory:at:environment:shell:)``
/// - New window next to a window you name: ``Server/newWindow(_:_:named:startDirectory:)``
/// - Split a window's active pane:
///   ``Server/splitWindow(_:direction:size:startDirectory:environment:shell:)``
/// - Split the pane you name: ``Server/split(_:direction:size:startDirectory:environment:shell:)``
/// - Destroy one object: ``Server/kill(_:)-(Session)``, ``Server/kill(_:)-(Window)``,
///   ``Server/kill(_:)-(Pane)``
/// - Stop the daemon: ``Server/killServer()``
/// - Rename a session or a window: ``Server/rename(_:to:)-(Session,String)``,
///   ``Server/rename(_:to:)-(Window,String)``
/// - Choose what is active: ``Server/select(_:)-(WindowLink)``, ``Server/select(_:)-(Pane)``,
///   ``Server/selectNextWindow(in:)``, ``Server/selectPreviousWindow(in:)``,
///   ``Server/selectLastWindow(in:)``, ``Server/selectLastPane(in:)``
///
/// **Arranging windows and panes.** Apply a layout, cycle through tmux's presets, or check layout
/// strings before anything changes. Set a pane's size, move one of its boundaries, or zoom it.
/// Rotate the panes of a window through its layout, and exchange two windows or two panes. Move a
/// pane into a window of its own or into another window. Move a window between sessions, show it in
/// a second one, or remove one of its appearances. Restart what a pane or a window runs.
///
/// - Apply a layout: ``Server/selectLayout(_:_:)``
/// - Cycle through the presets: ``Server/nextLayout(_:)``, ``Server/previousLayout(_:)``
/// - Check layout strings first: ``Server/validateLayouts(_:)``
/// - Set a pane's size: ``Server/resize(_:width:height:)``
/// - Move one boundary of a pane: ``Server/resize(_:by:toward:)``
/// - Zoom a pane: ``Server/toggleZoom(_:)``
/// - Move panes through the layout: ``Server/rotate(_:upward:)``
/// - Exchange two windows or two panes: ``Server/swap(_:with:)-(WindowLink,WindowLink)``,
///   ``Server/swap(_:with:)-(Pane,Pane)``
/// - Move a pane into a window of its own: ``Server/breakPane(_:from:named:)``
/// - Move a pane into another window: ``Server/join(_:into:direction:size:)``
/// - Move a window between sessions: ``Server/move(_:to:at:)``
/// - Show a window in a second session: ``Server/link(_:into:)``
/// - Remove one appearance of a window: ``Server/unlink(_:)``
/// - Restart what a pane or a window runs:
///   ``Server/respawn(_:running:killingExisting:startDirectory:)``,
///   ``Server/respawn(_:running:killingExisting:)``
///
/// **Options and hooks.** An ``OptionScope`` names the exact table: the server's, the global
/// session or window table, or one session, window, or pane. Listing a table shows what has been
/// set in it, not tmux's built-in defaults. Reading one value there answers `nil` when it is not
/// set, and the resolved read gives the effective value after tmux resolves inheritance. Hooks live
/// in the global table or in one session's, chosen by a ``HookScope``. The environment, global or
/// one session's through an ``EnvironmentScope``, can be read whole or by variable; removing a
/// variable marks it so that new processes start without it. Writing an option, a hook or an
/// environment variable hands back tmux's ``TmuxReply``, so a name tmux refuses is in the reply
/// rather than thrown.
///
/// - List a table: ``Server/options(_:)``
/// - Read one value: ``Server/option(_:scope:)``
/// - Read the effective value: ``Server/resolvedOption(_:scope:)``
/// - Write an option: ``Server/setOption(_:to:scope:)``, ``Server/unsetOption(_:scope:)``
/// - List the bound hooks: ``Server/hooks(_:)``
/// - Bind a command to a hook: ``Server/setHook(_:to:at:in:)``
/// - Unbind a hook: ``Server/unsetHook(_:in:)``
/// - Run a hook's commands now: ``Server/runHook(_:in:)``
/// - Read the environment: ``Server/environment(_:)``, ``Server/environmentValue(_:in:)``
/// - Write the environment: ``Server/setEnvironment(_:to:in:)``, ``Server/unsetEnvironment(_:in:)``
/// - Remove a variable for new processes: ``Server/removeEnvironment(_:in:)``
///
/// **Everything else tmux keeps.** Paste buffers can be listed, read, set, loaded, saved, deleted
/// and pasted; the load and save pair have tmux read or write the file itself, which avoids the
/// argument-size limit of ``Server/setBuffer(_:named:)`` and, on a connected server, its refusal of
/// newlines. Format expansion reaches any field the library does not model, for the server, for an
/// object you hold, or for an ID that arrived as a string. Load a configuration file into the
/// running server. A wait blocks until something signals the channel, and throws
/// ``TmuxError/serverRestarted`` if the server went away while it waited.
///
/// - List and read paste buffers: ``Server/buffers()``, ``Server/buffer(named:)``
/// - Set a buffer: ``Server/setBuffer(_:named:)``
/// - Through a file: ``Server/loadBuffer(from:named:)``, ``Server/saveBuffer(named:to:)``
/// - Delete a buffer: ``Server/deleteBuffer(named:)``
/// - Paste a buffer: ``Server/paste(buffer:into:)``
/// - Format for the server: ``Server/format(_:)``
/// - Format for an object you hold: ``Server/format(_:for:)-(String,Session)``,
///   ``Server/format(_:for:)-(String,WindowLink)``, ``Server/format(_:for:through:)``
/// - Format for an ID as a string: ``Server/format(_:addressing:)``
/// - Load a configuration file: ``Server/sourceFile(_:)``
/// - Wait for a channel: ``Server/wait(for:)``
/// - Signal a channel: ``Server/signal(_:)``
///
/// **Talking to a pane.** Send keys as characters rather than key names when `literally` is set,
/// and type a command line followed by Enter. A shell invocation spells a tmux that reaches this
/// server for a command running inside a pane. A capture reads the visible rows, and the scrollback
/// too on request; a capture with a line limit keeps the newest and reports how many it dropped,
/// and a ranged capture reads a range of them. A capture since a ``CaptureCursor`` returns only
/// what has been printed since it, and waiting for output ends once a pane prints something that
/// matches. Copy a pane's output to a shell command, enter copy mode, clear every mode, clear its
/// scrollback, and set its title.
///
/// - Send keys: ``Server/sendKeys(_:to:literally:)``
/// - Type a command line: ``Server/run(_:in:)``
/// - Spell a tmux for a command in a pane: ``Server/shellInvocation``
/// - Read the visible rows: ``Server/capture(_:includingHistory:)``
/// - Keep the newest and report the drop: ``Server/capture(_:includingHistory:maximumLines:)``
/// - Read a range: ``Server/captureRange(_:startingAt:endingAt:joiningWrappedLines:maximumLines:)``
/// - Read since a cursor: ``Server/capture(_:since:limit:)``
/// - Wait for matching output:
///   ``Server/waitForOutput(in:matching:stoppingAt:requiringFreshOutput:startingAt:timeout:tailLimit:)``
/// - Copy output to a shell command: ``Server/pipe(_:to:)``
/// - Enter copy mode: ``Server/enterCopyMode(_:)``
/// - Clear every mode: ``Server/cancelModes(in:)``
/// - Clear the scrollback: ``Server/clearHistory(_:)``
/// - Set the title: ``Server/setTitle(_:of:)``
///
/// **Things that need a terminal.** None. Menus, popups, prompts, and key bindings need an attached
/// client to mean anything, so this type leaves them out. Detaching acts on clients the server
/// already holds and needs no terminal of its own, and a connected scope attaches a control-mode
/// client, which talks over pipes rather than a terminal.
///
/// - Detach: ``Server/detach(_:)``, ``Server/detachClients(from:)``
/// - Attach a control-mode client: ``Server/connected(attachingTo:_:)``
///
/// **Running a command.** Anything tmux can do that is not here is reachable by running a tmux
/// command. One call runs a single command and another runs several in one invocation. Both hand
/// back a ``TmuxReply``: a nonzero status is a reply, not an error.
///
/// - Run one command: ``Server/run(_:)-(TmuxCommand)``
/// - Run several in one invocation: ``Server/run(_:)-(TmuxCommandList)``
public struct Server: Sendable, Hashable {
    /// Where this server listens. Every command carries it, so a call reaches the
    /// server you named, and the one tmux picks only when this is
    /// ``Endpoint/tmuxChoice``.
    public let endpoint: Endpoint
    let tmuxExecutablePath: String
    let clientArguments: [String]
    private let runtime: ServerRuntime
    /// Where commands go, when it is not a new process each time.
    ///
    /// Held here rather than in the runtime because it is a property of this
    /// handle, not of the daemon: a server reached over a connection and the
    /// same server reached directly are the same tmux, and compare equal.
    let connection: ControlSession?
    /// The session the connection attached to, so ``mode`` can name it.
    private let attachedSession: String?

    /// The tmux this server runs, resolved to a path.
    ///
    /// A consumer that spawns its own tmux — to find other servers, or to build
    /// a command line — should use this one rather than whatever is on `PATH`,
    /// because a client of a different protocol version cannot talk to this
    /// server at all.
    public var tmuxExecutable: String { tmuxExecutablePath }

    /// How work from this server reaches tmux.
    ///
    /// A mode belongs to the value, not to the process or the task, so this is
    /// the whole of the answer — there is no setting elsewhere to consult and
    /// nothing inherited from a caller. Reading it is how a program checks the
    /// precedence rule rather than trusting it: a server handed to you inside
    /// ``using(_:_:)`` reports that mode, and any other server reports
    /// ``TmuxMode/direct``.
    public var mode: TmuxMode {
        guard let attachedSession else { return .direct }
        return .connected(to: attachedSession)
    }

    public init(
        socketPath: String,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil
    ) throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(socketPath: socketPath),
            tmuxExecutable: tmuxExecutable,
            configurationFile: configurationFile
        )
    }

    public init(
        socketName: String,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil
    ) throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(socketName: socketName),
            tmuxExecutable: tmuxExecutable,
            configurationFile: configurationFile
        )
    }

    /// A server on the socket the environment names, else on the one tmux picks.
    ///
    /// `LIBTMUX_SOCKET_PATH` names a socket path, passed to tmux as `-S`.
    /// Otherwise `LIBTMUX_SOCKET` names a socket name, passed as `-L`. With
    /// neither set the server's ``endpoint`` is ``Endpoint/tmuxChoice``: tmux is
    /// passed no socket and chooses the server itself, the one in `TMUX` inside
    /// tmux and the default socket in `TMUX_TMPDIR` elsewhere. The path wins when
    /// both variables are set, as it does for the Python library. A variable that
    /// is empty or only whitespace counts as unset, each one on its own, so a
    /// blank path leaves a set name in force; any other value is used as written.
    ///
    /// Name a socket with ``init(socketPath:tmuxExecutable:configurationFile:)``
    /// or ``init(socketName:tmuxExecutable:configurationFile:)`` when the answer
    /// must not depend on the environment; those leave both variables unread.
    /// Only the two variables are read from `environment`. Every tmux process the
    /// server starts inherits the process's own environment, `TMUX` included.
    ///
    /// ```swift
    /// let server = try Server()
    /// let sessions = try await server.sessions()
    /// ```
    ///
    /// - Parameter environment: where to read the two variables from.
    /// - Throws: ``TmuxError/invalidEndpoint(_:)`` for a socket path that is too
    ///   long. The error names the length and never the value.
    public init(
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(environment: environment),
            tmuxExecutable: tmuxExecutable,
            configurationFile: configurationFile
        )
    }

    package init(
        endpoint: Endpoint,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil,
        force256Colors: Bool = false
    ) {
        self.init(
            endpoint: endpoint, tmuxExecutable: tmuxExecutable,
            configurationFile: configurationFile, force256Colors: force256Colors,
            transport: SubprocessTransport(), checkingVersions: true)
    }

    /// A server over a process boundary the caller supplies.
    ///
    /// The version check is off unless asked for: a scripted transport answers
    /// the commands a test writes, and a version probe or fence in front of
    /// them would change what it sees. The shipped initializers always enforce it.
    init(
        endpoint: Endpoint,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil,
        force256Colors: Bool = false,
        transport: any ProcessTransport,
        checkingVersions: Bool = false
    ) {
        let resolved = resolvedExecutable(tmuxExecutable)
        self.endpoint = endpoint
        self.tmuxExecutablePath = resolved
        // `-u` keeps format bytes in UTF-8 without changing the environment a
        // newly started daemon passes to panes.
        self.clientArguments =
            ["-u"] + (force256Colors ? ["-2"] : [])
            + (configurationFile.map { ["-f", $0] } ?? [])
        self.runtime = ServerRuntime(
            endpoint: endpoint,
            tmuxExecutable: resolved,
            clientArguments: clientArguments,
            transport: transport,
            checkingVersions: checkingVersions
        )
        self.connection = nil
        self.attachedSession = nil
    }

    /// The same server in another mode.
    ///
    /// Private because a connection has a lifetime, and only the scope that
    /// owns it may hand one out. Passing `nil` gives the direct server back,
    /// which is what lets a scope inside a connected one opt out of it.
    init(
        _ other: Server,
        dispatchingOver connection: ControlSession?,
        attachedTo session: String?
    ) {
        self.endpoint = other.endpoint
        self.tmuxExecutablePath = other.tmuxExecutablePath
        self.clientArguments = other.clientArguments
        self.runtime = other.runtime
        self.connection = connection
        self.attachedSession = session
    }

    /// Runs one tmux command and hands back what tmux said.
    ///
    /// A nonzero status is a reply, not an error: `has-session` answers a
    /// question with its exit code, and a rejected command carries its reason
    /// on standard error. Each output stream is capped at 1 MiB.
    public func run(_ command: TmuxCommand) async throws(TmuxError) -> TmuxReply {
        try await run(rawArguments: command.argumentVector)
    }

    func run(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        guard let connection else {
            return try await runtime.run(rawArguments: rawArguments)
        }
        try await runtime.requireFeatures(for: rawArguments)
        return try await connection.reply(to: rawArguments)
    }

    func versionCheck() async throws(TmuxError) -> (version: ServerVersion, live: Bool) {
        try await runtime.checkVersion()
    }

    /// Whether the daemon behind this server has exited or is exiting.
    func hasLostDaemon() async -> Bool {
        await runtime.daemonIsGone()
    }

    func requireCommandFeatures(_ rawArguments: [String]) async throws(TmuxError) {
        try await runtime.requireFeatures(for: rawArguments)
    }

    func executableVersion() async throws(TmuxError) -> TmuxVersion {
        try await runtime.executableVersion()
    }

    /// Makes the next command believe a daemon of this release was checked,
    /// which is what a daemon replaced behind the endpoint looks like to it.
    func presumeSupported(_ daemon: ServerVersion) async {
        await runtime.presumeSupported(daemon)
    }

    /// The release every command is checked against: the running daemon's,
    /// or the executable's when nothing listens yet.
    ///
    /// Throws for a release below the supported floor, which is what lets a
    /// caller decide before it sends anything.
    package func daemonVersion() async throws(TmuxError) -> TmuxVersion {
        try await runtime.serverVersion().version
    }

    /// Runs a command in a process of its own, whatever mode this server is in.
    ///
    /// For the one command that does not return promptly. tmux runs a control
    /// client's commands one at a time, so a command that blocks holds every
    /// command behind it — including whichever one would release it. Sending
    /// such a command over the connection would deadlock the scope; giving it
    /// its own process keeps the answer identical and the connection free.
    func runInOwnProcess(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        try await runtime.run(rawArguments: rawArguments)
    }

    package func runIsolated(
        _ command: TmuxCommand,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        try await runtime.run(
            rawArguments: command.argumentVector,
            perStreamOutputLimit: perStreamOutputLimit
        )
    }

    package func runIsolated(
        _ command: TmuxCommand,
        expecting incarnation: ServerIncarnation,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let expected = try expectedIncarnation([incarnation])
        let request = GuardedRequest(
            command: command,
            incarnation: expected,
            targets: []
        )
        let reply = try await runtime.run(
            rawArguments: request.commands.argumentVector,
            perStreamOutputLimit: perStreamOutputLimit
        )
        return try request.validate(reply)
    }

    func runIsolated(
        _ command: TmuxCommand,
        guarding pane: Pane,
        matching bounds: PaneCaptureBounds,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let boundsGuard = GuardedTarget(
            target: pane.id.rawValue,
            condition: .all(
                .equals("history_size", bounds.historySize),
                .equals("history_bytes", bounds.historyBytes),
                .equals("pane_height", bounds.paneHeight),
                .equals("cursor_y", bounds.cursorRow)
            )
        )
        let request = GuardedRequest(
            command: command,
            incarnation: try expectedIncarnation([pane.incarnation]),
            targets: [GuardedValue.pane(pane).targetGuard, boundsGuard].compactMap { $0 }
        )
        let reply = try await runtime.run(
            rawArguments: request.commands.argumentVector,
            perStreamOutputLimit: perStreamOutputLimit
        )
        return try request.validate(reply)
    }

    package func runTerminatingIsolated(
        _ command: TmuxCommand,
        expecting incarnation: ServerIncarnation,
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let expected = try expectedIncarnation([incarnation])
        let request = GuardedRequest(
            command: command,
            incarnation: expected,
            targets: []
        )
        let reply = try await runtime.run(
            rawArguments: request.commands.argumentVector,
            perStreamOutputLimit: perStreamOutputLimit
        )
        return try request.validateTerminating(reply)
    }

    /// Every session on this server, in tmux's own order.
    ///
    /// Use ``isRunning()`` when absence is an expected probe; a failed listing
    /// throws rather than impersonating a running server with no sessions.
    public func sessions() async throws(TmuxError) -> [Session] {
        try await list(
            TmuxCommand("list-sessions", ["-F", Session.projection.template]),
            projection: Session.projection,
            row: { Session(row: $0, endpoint: endpoint) }
        )
    }

    /// Every window on this server, in tmux's own order.
    ///
    /// A window linked into more than one session appears once here. Use
    /// ``windowLinks()`` for each session-local appearance.
    public func windows() async throws(TmuxError) -> [Window] {
        var seen: Set<WindowID> = []
        return try await windowListingRows().compactMap { row in
            seen.insert(row.window.id).inserted ? row.window : nil
        }
    }

    /// Every session-local link to a window, in tmux's own order.
    public func windowLinks() async throws(TmuxError) -> [WindowLink] {
        try await windowListingRows().map(\.link)
    }

    func windowListingRows() async throws(TmuxError) -> [WindowAppearance] {
        try await list(
            TmuxCommand("list-windows", ["-a", "-F", WindowAppearance.projection.template]),
            projection: WindowAppearance.projection,
            row: { WindowAppearance(row: $0, endpoint: endpoint) }
        )
    }

    /// Every pane on this server, in tmux's own order. A pane whose window has
    /// several session links appears once.
    public func panes() async throws(TmuxError) -> [Pane] {
        var seen: Set<PaneID> = []
        return try await list(
            TmuxCommand("list-panes", ["-a", "-F", Pane.projection.template]),
            projection: Pane.projection,
            row: { Pane(row: $0, endpoint: endpoint) }
        ).compactMap { pane in
            seen.insert(pane.id).inserted ? pane : nil
        }
    }

    /// Every client attached to this server.
    public func clients() async throws(TmuxError) -> [Client] {
        try await list(
            TmuxCommand("list-clients", ["-F", Client.projection.template]),
            projection: Client.projection,
            row: { Client(row: $0, endpoint: endpoint) }
        )
    }

    /// Reads every object from one daemon incarnation.
    ///
    /// The listings are separate tmux commands, so the server's identity is
    /// read before and after them. If a daemon died and a replacement bound the
    /// same socket in between, this throws ``TmuxError/serverRestarted``.
    /// Another client can still mutate the same daemon between listings.
    public func snapshot() async throws(TmuxError) -> Snapshot {
        let before = try await incarnation()
        let sessions = try await sessions()
        let windowRows = try await windowListingRows()
        var seen: Set<WindowID> = []
        let windows = windowRows.compactMap { row in
            seen.insert(row.window.id).inserted ? row.window : nil
        }
        let windowLinks = windowRows.map(\.link)
        let panes = try await panes()
        let clients = try await clients()
        let after = try await incarnation()
        guard before == after else {
            throw .serverRestarted
        }
        return Snapshot(
            incarnation: before,
            sessions: sessions,
            windows: windows,
            windowLinks: windowLinks,
            panes: panes,
            clients: clients
        )
    }

    /// The running server's process id.
    ///
    /// A restart changes it, which is what lets a multi-command capture prove
    /// it came from one server.
    public func serverProcessID() async throws(TmuxError) -> Int {
        try await incarnation().processID
    }

    /// The running daemon at this endpoint.
    ///
    /// Use ``isRunning()`` for a Boolean probe. This read throws when tmux
    /// cannot answer so absence cannot look like an empty identity.
    public func incarnation() async throws(TmuxError) -> ServerIncarnation {
        // `display-message` would fire a configured `after-display-message`
        // hook on every identity read. `run-shell -C` expands the format and
        // parses the result as a command, so tmux reports the expansion in its
        // error for the first word. The fields are joined into one word:
        // `q:` backslash-escapes what would split a word, and the path comes
        // last because it may hold commas.
        let marker = Support.Versions.makeMarker() + "-"
        let command = TmuxCommand(
            "run-shell", ["-C", marker + "#{pid},#{start_time},#{q:socket_path}"])
        // A process of its own even over a connection: a control client
        // prints this error outside any reply block, where it cannot be read.
        let reply = try await runInOwnProcess(rawArguments: command.argumentVector)
        let prefix = "unknown command: \(marker)"
        let lines = reply.errorText.split(separator: "\n", omittingEmptySubsequences: false)
        guard reply.exitCode == 1, lines.count == 1, lines[0].hasPrefix(prefix) else {
            if reply.exitCode == 1, lines.first?.hasPrefix(prefix) == true {
                throw .invocationFailed(reason: "tmux reported a multi-line server identity")
            }
            throw reply.failure(for: command)
        }
        let fields = lines[0].dropFirst(prefix.count).split(
            separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let processID = Int(fields[0]), let startedAt = Int(fields[1])
        else {
            throw .invocationFailed(reason: "tmux returned no server identity")
        }
        return ServerIncarnation(
            endpoint: endpoint, socketPath: String(fields[2]),
            processID: processID, startedAt: startedAt)
    }

    /// Runs a listing and decodes it.
    ///
    /// A failed tmux command throws; only a successful empty listing is empty.
    private func list<Element: Sendable>(
        _ command: TmuxCommand,
        projection: FormatProjection,
        row: (FormatRow) -> Element
    ) async throws(TmuxError) -> [Element] {
        let reply = try await run(rawArguments: command.argumentVector)
        guard reply.isSuccess else { throw reply.failure(for: command) }
        do {
            return try projection.decode(reply.standardOutput).map(row)
        } catch {
            throw .decodingFailed(error)
        }
    }

    /// Whether a session by this name or id exists.
    ///
    /// Lists sessions and compares in Swift rather than asking `has-session`
    /// to resolve the name: a plain `-t name` reads an unambiguous
    /// abbreviation as a match, so `-t alpha` answers yes for a session
    /// named only `alphabet`, and `-t =name` answers no for one whose real
    /// name holds `.` or `:`. Neither target spelling is both exact and
    /// universal; listing first and comparing by value is. Checking
    /// ``isRunning()`` first keeps this false rather than thrown for a
    /// server that is not there yet or just went away -- ``sessions()``
    /// itself throws on that, unlike the `has-session` this replaces.
    public func hasSession(_ name: String) async throws(TmuxError) -> Bool {
        guard try await isRunning() else { return false }
        return try await sessions().contains { $0.name == name || $0.id.rawValue == name }
    }

    /// Whether a server is listening on this endpoint.
    public func isRunning() async throws(TmuxError) -> Bool {
        try await run(
            rawArguments: TmuxCommand("list-sessions", ["-F", "#{session_id}"])
                .argumentVector
        ).isSuccess
    }

    public static func == (lhs: Server, rhs: Server) -> Bool {
        lhs.runtime === rhs.runtime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(runtime))
    }
}

/// The mutable half of a server.
///
/// An actor, so that copies of one ``Server`` coordinate rather than race: the
/// value is free to be copied because everything mutable lives behind here.
///
/// Every command a server sends as a process passes through ``run``, which is
/// where the version check happens: the daemon's release is read, refused if it
/// is below the supported floor, and each batch is fenced to that release so a
/// daemon replaced in between refuses it instead of running it.
actor ServerRuntime {
    private let endpoint: Endpoint
    private let tmuxExecutable: String
    private let clientArguments: [String]
    private let transport: any ProcessTransport
    private let checkingVersions: Bool
    /// What the daemon at this endpoint answered when asked its version.
    ///
    /// Only a running daemon's answer is kept, once per endpoint and shared by
    /// every ``Server`` value that reaches it. It is a claim about one daemon,
    /// so a refused fence or a vanished endpoint drops it, and the next command
    /// asks again.
    private var localDaemon: ServerVersion?
    private var daemonVersion: ServerVersion? {
        get { checkingVersions ? VersionCache.shared.daemon(for: registryKey) : localDaemon }
        set {
            if checkingVersions {
                VersionCache.shared.record(newValue, for: registryKey)
            } else {
                localDaemon = newValue
            }
        }
    }
    private var registryKey: VersionCache.Key {
        VersionCache.Key(endpoint: endpoint, executable: tmuxExecutable)
    }
    /// What the executable reports, read once an endpoint has no daemon.
    private var executableVersion: ServerVersion?
    private var probing: Task<ServerVersion?, any Error>?

    init(
        endpoint: Endpoint,
        tmuxExecutable: String,
        clientArguments: [String],
        transport: any ProcessTransport,
        checkingVersions: Bool = false
    ) {
        self.endpoint = endpoint
        self.tmuxExecutable = tmuxExecutable
        self.clientArguments = clientArguments
        self.transport = transport
        self.checkingVersions = checkingVersions
    }

    func run(
        rawArguments: [String],
        perStreamOutputLimit: Int = defaultTmuxReplyByteLimit
    ) async throws(TmuxError) -> TmuxReply {
        guard perStreamOutputLimit >= 0 else {
            throw .invocationFailed(reason: "output limit cannot be negative")
        }
        try requireTmuxCommandFits(rawArguments)
        guard checkingVersions else {
            return try await send(rawArguments, perStreamOutputLimit: perStreamOutputLimit)
        }
        var retried = false
        while true {
            if rawArguments == ["kill-server"], daemonVersion == nil {
                if let daemon = try await probeDaemon() {
                    daemonVersion = daemon
                } else {
                    // Nothing listens, so there is nothing to stop and nothing
                    // for a release floor to protect. `-N` keeps the client
                    // from starting the server it was asked to stop.
                    return try await send(
                        ["-N"] + rawArguments, perStreamOutputLimit: perStreamOutputLimit)
                }
            }
            let (checked, live) = try await checkVersion()
            try TmuxCommandGuard.check(rawArguments, against: checked)
            let marker = Support.Versions.makeMarker()
            let fenced = Support.Versions.fence(rawArguments, to: checked, marker: marker)
            try requireTmuxCommandFits(fenced)
            let reply = try await send(
                // A daemon that vanished after the check must not be restarted
                // by a client whose release was never checked.
                (live ? ["-N"] : []) + fenced,
                perStreamOutputLimit: perStreamOutputLimit
            )
            if Support.Versions.isRefusal(reply, marker: marker) {
                // Nothing ran. The daemon is not the one that was checked,
                // so ask the endpoint again; a replacement that is too old
                // is refused there, and one that keeps changing is reported.
                daemonVersion = nil
                guard !retried else { throw .serverRestarted }
                retried = true
                continue
            }
            if live, !retried, Support.Versions.isAbsentEndpoint(reply) {
                // The checked daemon exited. Nothing ran; check what is
                // there now (or the executable that would start a daemon).
                daemonVersion = nil
                retried = true
                continue
            }
            return reply
        }
    }

    func presumeSupported(_ daemon: ServerVersion) { daemonVersion = daemon }

    /// Whether the daemon at this endpoint has exited or is exiting.
    ///
    /// tmux stays up until every client has left, so after `kill-server` a
    /// stopped client leaves a daemon that accepts a connection and drops it
    /// ("server exited unexpectedly") instead of one that is absent. Both mean
    /// the panes are gone. The probe skips the version check, which would
    /// itself have to talk to the daemon it is asking about, and `-N` keeps it
    /// from starting a replacement.
    func daemonIsGone() async -> Bool {
        guard
            let reply = try? await send(
                ["-N", "list-sessions", "-F", "#{session_id}"],
                perStreamOutputLimit: 4096)
        else { return false }
        guard reply.exitCode != 0 else { return false }
        return Support.Versions.isAbsentEndpoint(reply)
            || reply.errorText.contains("server exited unexpectedly")
            || reply.errorText.contains("lost server")
    }

    /// Refuses a literal batch the checked release cannot run safely.
    func requireFeatures(for rawArguments: [String]) async throws(TmuxError) {
        guard checkingVersions else { return }
        try TmuxCommandGuard.check(rawArguments, against: try await checkVersion().version)
    }

    /// The release of the daemon commands are checked against, or of the
    /// executable that would start one when nothing listens.
    func serverVersion() async throws(TmuxError) -> ServerVersion {
        try await checkVersion().version
    }

    /// The executable's own report, with no daemon involved.
    func executableVersion() async throws(TmuxError) -> TmuxVersion {
        let token = try await executableToken()
        guard let version = TmuxVersion(parsing: token) else {
            throw .invocationFailed(
                reason: "could not read a tmux version from \(token.debugDescription)"
            )
        }
        return version
    }

    private func executableToken() async throws(TmuxError) -> String {
        let reply = try await send(["-V"], perStreamOutputLimit: defaultTmuxReplyByteLimit)
        guard reply.isSuccess,
            let token = Support.Versions.executableToken(
                banner: reply.text, executable: tmuxExecutable)
        else {
            throw .invocationFailed(
                reason: "could not read a tmux version from \(reply.text.debugDescription)"
            )
        }
        return token
    }

    func checkVersion() async throws(TmuxError) -> (version: ServerVersion, live: Bool) {
        if let daemonVersion { return (daemonVersion, true) }
        if let daemon = try await probeDaemon() {
            daemonVersion = daemon
            return (daemon, true)
        }
        if let executableVersion { return (executableVersion, false) }
        let executable = try Support.Versions.requireCore(try await executableToken())
        executableVersion = executable
        return (executable, false)
    }

    /// Asks the daemon, and only a daemon that is already there.
    ///
    /// Callers that arrive while a probe is in flight share its answer, so
    /// the first batch of concurrent commands spends one process on the version
    /// check rather than one each.
    private func probeDaemon() async throws(TmuxError) -> ServerVersion? {
        let task: Task<ServerVersion?, any Error>
        if let probing {
            task = probing
        } else {
            task = Task { try await self.probeDaemonOnce() }
            probing = task
        }
        defer { if probing == task { probing = nil } }
        do {
            return try await task.value
        } catch {
            throw normalizedTmuxError(error)
        }
    }

    private func probeDaemonOnce() async throws(TmuxError) -> ServerVersion? {
        let marker = Support.Versions.makeMarker()
        let reply = try await send(
            Support.Versions.probeArguments(marker: marker),
            perStreamOutputLimit: defaultTmuxReplyByteLimit
        )
        switch Support.Versions.interpret(probe: reply, marker: marker) {
        case let .version(token): return try Support.Versions.requireCore(token)
        case .predatesProbe:
            throw .unsupportedTmuxVersion(
                reported: "older than 3.2", required: "\(TmuxVersion.coreMinimum)",
                operation: "any command")
        case .absent, .clientRejectsFlag: return nil
        case let .failed(reason): throw .invocationFailed(reason: reason)
        }
    }

    private func send(
        _ rawArguments: [String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        // Copied out of isolation before the await so the actor is not held for
        // the lifetime of a tmux process.
        let transport = self.transport
        let executable = tmuxExecutable
        let arguments = clientArguments + endpoint.addressArguments + rawArguments
        let reply = try await transport.run(
            executable: executable,
            arguments: arguments,
            environment: TmuxProcessEnvironment.variables(),
            perStreamOutputLimit: perStreamOutputLimit
        )
        try requireReplyFitsLimit(reply, perStreamOutputLimit)
        return reply
    }
}
