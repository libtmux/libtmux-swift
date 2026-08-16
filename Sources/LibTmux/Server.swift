import Foundation

/// A tmux server, addressed by its endpoint.
///
/// `Server` is a value: copying one is free, copies compare equal, and passing
/// one across a task boundary needs no ceremony. The mutable part — the process
/// boundary and anything cached about the running daemon — lives behind an
/// actor that every copy shares, so two copies of the same server coordinate
/// with each other rather than racing.
public struct Server: Sendable, Hashable {
    /// Where this server listens. Every command carries it, so no call can
    /// reach the ambient server by accident.
    public let endpoint: Endpoint
    let tmuxExecutablePath: String
    private let runtime: ServerRuntime
    /// Where commands go, when it is not a new process each time.
    ///
    /// Held here rather than in the runtime because it is a property of this
    /// handle, not of the daemon: a server reached over a connection and the
    /// same server reached directly are the same tmux, and compare equal.
    let connection: ControlSession?
    /// The session the connection attached to, so ``mode`` can name it.
    private let attachedSession: String?

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

    public init(socketPath: String, tmuxExecutable: String = "tmux") throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(socketPath: socketPath),
            tmuxExecutable: tmuxExecutable
        )
    }

    public init(socketName: String, tmuxExecutable: String = "tmux") throws(TmuxError) {
        self.init(
            endpoint: try Endpoint(socketName: socketName),
            tmuxExecutable: tmuxExecutable
        )
    }

    init(
        endpoint: Endpoint,
        tmuxExecutable: String = "tmux",
        transport: any ProcessTransport = SubprocessTransport()
    ) {
        let resolved = resolvedExecutable(tmuxExecutable)
        self.endpoint = endpoint
        self.tmuxExecutablePath = resolved
        self.runtime = ServerRuntime(
            endpoint: endpoint,
            tmuxExecutable: resolved,
            transport: transport
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
        self.runtime = other.runtime
        self.connection = connection
        self.attachedSession = session
    }

    /// Runs one tmux command and hands back what tmux said.
    ///
    /// A nonzero status is a reply, not an error: `has-session` answers a
    /// question with its exit code, and a rejected command carries its reason
    /// on standard error.
    public func run(_ command: TmuxCommand) async throws(TmuxError) -> TmuxReply {
        try await run(rawArguments: command.argumentVector)
    }

    func run(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        guard let connection else {
            return try await runtime.run(rawArguments: rawArguments)
        }
        return try await connection.reply(to: rawArguments)
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

    /// Every session on this server, in tmux's own order.
    ///
    /// Returns an empty array when the server is not running — the same answer
    /// as a running server with no sessions. Use ``isRunning()`` when the
    /// difference matters.
    public func sessions() async throws(TmuxError) -> [Session] {
        try await list(
            TmuxCommand("list-sessions", ["-F", Session.projection.template]),
            projection: Session.projection,
            row: Session.init(row:)
        )
    }

    /// Every window on this server, in tmux's own order.
    ///
    /// A window linked into more than one session appears once per session,
    /// carrying the same ``Window/id`` — that repetition is tmux's model, not
    /// a duplicate.
    public func windows() async throws(TmuxError) -> [Window] {
        try await list(
            TmuxCommand("list-windows", ["-a", "-F", Window.projection.template]),
            projection: Window.projection,
            row: Window.init(row:)
        )
    }

    /// Every pane on this server, in tmux's own order.
    public func panes() async throws(TmuxError) -> [Pane] {
        try await list(
            TmuxCommand("list-panes", ["-a", "-F", Pane.projection.template]),
            projection: Pane.projection,
            row: Pane.init(row:)
        )
    }

    /// Every client attached to this server.
    public func clients() async throws(TmuxError) -> [Client] {
        try await list(
            TmuxCommand("list-clients", ["-F", Client.projection.template]),
            projection: Client.projection,
            row: Client.init(row:)
        )
    }

    /// Reads every object on this server as one consistent picture.
    ///
    /// The listings are separate tmux commands, so the server's identity is
    /// read before and after them. If a daemon died and a replacement bound the
    /// same socket in between, the reads describe two different servers and
    /// this throws ``TmuxError/serverRestarted`` rather than returning a
    /// picture that never existed. A partial snapshot is never returned.
    public func snapshot() async throws(TmuxError) -> Snapshot {
        let before = try await serverProcessID()
        let sessions = try await sessions()
        let windows = try await windows()
        let panes = try await panes()
        let clients = try await clients()
        let after = try await serverProcessID()
        guard let before, let after, before == after else {
            throw .serverRestarted
        }
        return Snapshot(
            serverProcessID: before,
            sessions: sessions,
            windows: windows,
            panes: panes,
            clients: clients
        )
    }

    /// The running server's process id, or `nil` if nothing is listening.
    ///
    /// A restart changes it, which is what lets a multi-command capture prove
    /// it came from one server.
    public func serverProcessID() async throws(TmuxError) -> Int? {
        let reply = try await run(
            rawArguments: TmuxCommand("display-message", ["-p", "#{pid}"]).argumentVector
        )
        guard reply.isSuccess else { return nil }
        return Int(reply.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a listing and decodes it.
    ///
    /// A failed tmux command yields an empty array: a server that is not
    /// running has no windows, and callers that need to tell that apart from a
    /// running-but-empty server have ``isRunning()``.
    private func list<Element: Sendable>(
        _ command: TmuxCommand,
        projection: FormatProjection,
        row: (FormatRow) -> Element
    ) async throws(TmuxError) -> [Element] {
        let reply = try await run(rawArguments: command.argumentVector)
        guard reply.isSuccess else { return [] }
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
actor ServerRuntime {
    private let endpoint: Endpoint
    private let tmuxExecutable: String
    private let transport: any ProcessTransport

    init(endpoint: Endpoint, tmuxExecutable: String, transport: any ProcessTransport) {
        self.endpoint = endpoint
        self.tmuxExecutable = tmuxExecutable
        self.transport = transport
    }

    func run(rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        // Copied out of isolation before the await so the actor is not held for
        // the lifetime of a tmux process.
        let transport = self.transport
        let executable = tmuxExecutable
        // `-u` forces UTF-8 regardless of locale. Without it, `LC_ALL=C` makes
        // tmux rewrite any non-ASCII byte in a format — including the record
        // separator — to `_`, which is itself legal in a session name, so a
        // listing would silently split on the wrong character.
        let arguments = ["-u"] + endpoint.addressArguments + rawArguments
        return try await transport.run(
            executable: executable,
            arguments: arguments,
            environment: TmuxProcessEnvironment.variables()
        )
    }
}
