import Foundation

/// A tmux server, addressed by its endpoint.
///
/// `Server` is a value: copying one is free, passing one across a task
/// boundary needs no ceremony, and two values addressing the same daemon the
/// same way compare equal even when each was constructed separately. Nothing
/// is cached about the running daemon, so there is no shared mutable state for
/// copies to coordinate over — every answer comes from asking tmux.
public struct Server: Sendable, Hashable {
    /// Where this server listens. Every command carries it, so no call can
    /// reach the ambient server by accident.
    public let endpoint: Endpoint
    let tmuxExecutablePath: String
    let configurationFilePath: String?
    private let runtime: ServerRuntime
    /// Where commands go, when it is not a new process each time.
    ///
    /// Held here rather than in the runtime because it is a property of this
    /// handle, not of the daemon: a server reached over a connection and the
    /// same server reached directly are the same tmux, and compare equal.
    let connection: ControlSession?
    /// The session the connection attached to, so ``mode`` can name it.
    private let attachedSession: String?

    /// How long one tmux command may take before it is abandoned.
    ///
    /// `nil`, the default, waits as long as tmux does. A bound belongs on the
    /// value for the same reason ``mode`` does: nothing here is global and
    /// nothing is inherited by a task, so this is the whole of the answer for
    /// the server in hand and a program can read it rather than trust it.
    ///
    /// ``wait(for:timeout:)`` is deliberately outside it — waiting for a channel is
    /// meant to take as long as the thing being waited on, so a server-wide
    /// bound would turn every such wait into a failure. That call takes its
    /// own `timeout` instead.
    public let commandTimeout: Duration?

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

    /// A server at an absolute socket path.
    ///
    /// - Parameters:
    ///   - socketPath: where the daemon listens.
    ///   - tmuxExecutable: the tmux to run. A bare name is resolved on `PATH`
    ///     once, here, so ``tmuxExecutable`` reports a path.
    ///   - configurationFile: a `-f` configuration, or tmux's own default.
    ///   - transport: how a command reaches a process. The default spawns
    ///     tmux; pass your own to stand in for it, or to wrap it and see
    ///     every command. See ``ProcessTransport``.
    public init(
        socketPath: String,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil,
        transport: any ProcessTransport = SubprocessTransport()
    ) throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(socketPath: socketPath),
            tmuxExecutable: tmuxExecutable,
            configurationFile: configurationFile,
            transport: transport
        )
    }

    /// A server at a socket name, which tmux resolves inside `TMUX_TMPDIR`.
    ///
    /// The same name can denote different daemons in different environments;
    /// ``init(socketPath:tmuxExecutable:configurationFile:transport:)`` names
    /// one socket. Parameters are otherwise as there.
    public init(
        socketName: String,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil,
        transport: any ProcessTransport = SubprocessTransport()
    ) throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(socketName: socketName),
            tmuxExecutable: tmuxExecutable,
            configurationFile: configurationFile,
            transport: transport
        )
    }

    init(
        endpoint: Endpoint,
        tmuxExecutable: String = "tmux",
        configurationFile: String? = nil,
        transport: any ProcessTransport = SubprocessTransport()
    ) {
        let resolved = resolvedExecutable(tmuxExecutable)
        self.endpoint = endpoint
        self.tmuxExecutablePath = resolved
        self.configurationFilePath = configurationFile
        self.runtime = ServerRuntime(
            endpoint: endpoint,
            tmuxExecutable: resolved,
            configurationFile: configurationFile,
            transport: transport
        )
        self.connection = nil
        self.attachedSession = nil
        self.commandTimeout = nil
    }

    /// The same server, with every ordinary command bounded by `timeout`.
    ///
    /// ```swift
    /// let sessions = try await server.withTimeout(.seconds(5)).sessions()
    /// ```
    ///
    /// Passing `nil` removes the bound. The returned value shares this
    /// server's daemon and connection, so it compares equal to it.
    public func withTimeout(_ timeout: Duration?) -> Server {
        Server(self, commandTimeout: timeout)
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
        self.configurationFilePath = other.configurationFilePath
        self.runtime = other.runtime
        self.connection = connection
        self.attachedSession = session
        self.commandTimeout = other.commandTimeout
    }

    /// The same server under a different bound, keeping its mode.
    private init(_ other: Server, commandTimeout: Duration?) {
        self.endpoint = other.endpoint
        self.tmuxExecutablePath = other.tmuxExecutablePath
        self.configurationFilePath = other.configurationFilePath
        self.runtime = other.runtime
        self.connection = other.connection
        self.attachedSession = other.attachedSession
        self.commandTimeout = commandTimeout
    }

    /// Runs one tmux command and hands back what tmux said.
    ///
    /// A nonzero status is a reply, not an error: `has-session` answers a
    /// question with its exit code, and a rejected command carries its reason
    /// on standard error. Each output stream is capped at 1 MiB.
    ///
    /// This is also the escape hatch to `wait-for -L`, which has no typed
    /// wrapper -- see ``wait(for:timeout:)`` for why, and for the hazard reaching for
    /// it here carries: a timed-out locker is never removed from tmux's own
    /// queue, so a caller who bounds this call can wedge the channel for
    /// every later locker on the server, permanently.
    public func run(_ command: TmuxCommand) async throws(TmuxError) -> TmuxReply {
        try await run(rawArguments: command.argumentVector)
    }

    func run(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        let runtime = self.runtime
        let connection = self.connection
        return try await withCommandDeadline(commandTimeout) {
            guard let connection else {
                return try await runtime.run(rawArguments: rawArguments)
            }
            return try await connection.reply(to: rawArguments)
        }
    }

    /// Runs a command in its own process with no bound at all.
    ///
    /// For the one command whose whole purpose is to take as long as it takes.
    /// ``runInOwnProcess(rawArguments:)`` is the bounded counterpart, for a
    /// command that needs its own process for some *other* reason.
    func runUnbounded(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        try await runtime.run(rawArguments: rawArguments)
    }

    package func run(
        _ command: TmuxCommand,
        launchEnvironment: [String: String]
    ) async throws(TmuxError) -> TmuxReply {
        try await runtime.run(
            rawArguments: command.argumentVector,
            environmentOverrides: launchEnvironment
        )
    }

    /// Runs a command in a process of its own, whatever mode this server is in.
    ///
    /// For a command a connection cannot carry faithfully. tmux runs a control
    /// client's commands one at a time, so a command that blocks holds every
    /// command behind it — including whichever one would release it. Sending
    /// such a command over the connection would deadlock the scope; giving it
    /// its own process keeps the answer identical and the connection free.
    ///
    /// Still bounded by ``commandTimeout``: needing its own process is not a
    /// reason to wait forever. ``runUnbounded(rawArguments:)`` is for the one
    /// command that is *meant* to.
    func runInOwnProcess(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        let runtime = self.runtime
        return try await withCommandDeadline(commandTimeout) {
            try await runtime.run(rawArguments: rawArguments)
        }
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

    func runTerminatingIsolated(
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

    private func windowListingRows() async throws(TmuxError) -> [WindowAppearance] {
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

    /// Sessions attached by at least one client this process did not open for
    /// its own internal use.
    ///
    /// `Session.isAttached` answers tmux's own question -- is anything
    /// attached -- which counts a connection this process opened for itself
    /// the same as a person's. A caller reporting attachment to someone else
    /// (an MCP tool answering "is a person watching this session", say) wants
    /// this instead. See ``OwnedControlClients``.
    package func sessionIDsAttachedByOthers() async throws(TmuxError) -> Set<SessionID> {
        var attached: Set<SessionID> = []
        for client in try await clients() {
            guard await !OwnedControlClients.shared.contains(client.processID) else { continue }
            attached.insert(client.sessionID)
        }
        return attached
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
        let projection = FormatProjection(ServerIncarnation.projectionFields)
        let command = TmuxCommand("display-message", ["-p", projection.template])
        let reply = try await run(
            rawArguments: command.argumentVector
        )
        guard reply.isSuccess else { throw reply.failure(for: command) }
        let rows: [FormatRow]
        do {
            rows = try projection.decode(reply.standardOutput)
        } catch {
            throw .decodingFailed(error)
        }
        guard let row = rows.first else {
            throw .invocationFailed(reason: "tmux returned no server identity")
        }
        return ServerIncarnation(row: row, endpoint: endpoint)
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
    /// Asks the question tmux has a command for rather than listing every
    /// session and searching one: `has-session` answers with its exit status,
    /// so this decodes nothing and stays correct for a name a listing would
    /// have to be parsed to find.
    public func hasSession(_ name: String) async throws(TmuxError) -> Bool {
        try await run(
            rawArguments: TmuxCommand("has-session", ["-t", name]).argumentVector
        ).isSuccess
    }

    /// Whether a server is listening on this endpoint.
    public func isRunning() async throws(TmuxError) -> Bool {
        try await run(
            rawArguments: TmuxCommand("list-sessions", ["-F", "#{session_id}"])
                .argumentVector
        ).isSuccess
    }

    /// Two servers are the same server when they address the same daemon the
    /// same way.
    ///
    /// The endpoint, the tmux binary and the configuration file are what
    /// decide that: a command built from either value reaches the same daemon
    /// and is parsed by the same tmux. A mode, a bound, and the process
    /// boundary underneath are ways of *reaching* that server rather than
    /// different servers, so they are not part of this — which is what lets
    /// `server.withTimeout(_:)` and a connected scope's server still compare
    /// equal to the one they came from.
    ///
    /// A substituted ``ProcessTransport`` is deliberately not part of it
    /// either, which has one consequence worth stating: a server wired to a
    /// test double compares equal to one that reaches the real daemon. That
    /// is the intended reading — a double stands in for *that* server — but it
    /// means equality answers "which tmux is this addressing", never "will
    /// these two behave alike".
    public static func == (lhs: Server, rhs: Server) -> Bool {
        lhs.endpoint == rhs.endpoint
            && lhs.tmuxExecutablePath == rhs.tmuxExecutablePath
            && lhs.configurationFilePath == rhs.configurationFilePath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(endpoint)
        hasher.combine(tmuxExecutablePath)
        hasher.combine(configurationFilePath)
    }
}

/// How a command reaches one daemon: which tmux to run, with what
/// configuration, over which process boundary.
///
/// This was an actor, on the reasoning that copies of a ``Server`` should
/// coordinate rather than race. It holds no mutable state and never did, so
/// there was nothing to coordinate and the isolation bought only an executor
/// hop per command — and an identity, which is what made two servers on one
/// socket compare unequal. A value says what it is instead.
struct ServerRuntime: Sendable {
    private let endpoint: Endpoint
    private let tmuxExecutable: String
    private let configurationFile: String?
    private let transport: any ProcessTransport

    init(
        endpoint: Endpoint,
        tmuxExecutable: String,
        configurationFile: String?,
        transport: any ProcessTransport
    ) {
        self.endpoint = endpoint
        self.tmuxExecutable = tmuxExecutable
        self.configurationFile = configurationFile
        self.transport = transport
    }

    func run(
        rawArguments: [String],
        perStreamOutputLimit: Int = defaultTmuxReplyByteLimit,
        environmentOverrides: [String: String] = [:]
    ) async throws(TmuxError) -> TmuxReply {
        guard perStreamOutputLimit >= 0 else {
            throw .invocationFailed(reason: "output limit cannot be negative")
        }
        try requireTmuxCommandFits(rawArguments)
        let transport = self.transport
        let executable = tmuxExecutable
        // `-u` keeps format bytes in UTF-8 without changing the environment a
        // newly started daemon passes to panes.
        let configurationArguments = configurationFile.map { ["-f", $0] } ?? []
        let arguments = ["-u"] + configurationArguments + endpoint.addressArguments + rawArguments
        var environment = TmuxProcessEnvironment.variables()
        environment.merge(environmentOverrides) { _, override in override }
        let reply = try await transport.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
        try requireReplyFitsLimit(reply, perStreamOutputLimit)
        return reply
    }
}
