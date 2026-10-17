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
        return try await connection.reply(to: rawArguments)
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

    func versionCheck() async throws(TmuxError) -> (version: ServerVersion, live: Bool) {
        try await runtime.checkVersion()
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
        perStreamOutputLimit: Int = defaultTmuxReplyByteLimit,
        environmentOverrides: [String: String] = [:]
    ) async throws(TmuxError) -> TmuxReply {
        guard perStreamOutputLimit >= 0 else {
            throw .invocationFailed(reason: "output limit cannot be negative")
        }
        try requireTmuxCommandFits(rawArguments)
        guard checkingVersions else {
            return try await send(
                rawArguments,
                perStreamOutputLimit: perStreamOutputLimit,
                environmentOverrides: environmentOverrides
            )
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
                        ["-N"] + rawArguments, perStreamOutputLimit: perStreamOutputLimit,
                        environmentOverrides: environmentOverrides)
                }
            }
            let (checked, live) = try await checkVersion()
            let marker = Support.Versions.makeMarker()
            let fenced = Support.Versions.fence(rawArguments, to: checked, marker: marker)
            try requireTmuxCommandFits(fenced)
            let reply = try await send(
                // A daemon that vanished after the check must not be restarted
                // by a client whose release was never checked.
                (live ? ["-N"] : []) + fenced,
                perStreamOutputLimit: perStreamOutputLimit,
                environmentOverrides: environmentOverrides
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
        case .absent: return nil
        case let .failed(reason): throw .invocationFailed(reason: reason)
        }
    }

    private func send(
        _ rawArguments: [String],
        perStreamOutputLimit: Int,
        environmentOverrides: [String: String] = [:]
    ) async throws(TmuxError) -> TmuxReply {
        // Copied out of isolation before the await so the actor is not held for
        // the lifetime of a tmux process.
        let transport = self.transport
        let executable = tmuxExecutable
        let arguments = clientArguments + endpoint.addressArguments + rawArguments
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
