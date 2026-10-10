import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A borrowed match or a newly created owned resource.
///
/// Only `created` carries destruction responsibility. `withValue` closes that
/// owner after the body; a reused value survives the scope.
public enum FindOrCreate<Value: Sendable>: Sendable {
    case reused(Value)
    case created(OwnedTmux<Value>)

    public var value: Value {
        switch self {
        case let .reused(value): value
        case let .created(owner): owner.value
        }
    }
    public var owner: OwnedTmux<Value>? {
        switch self {
        case .reused: nil
        case let .created(owner): owner
        }
    }
    public var wasCreated: Bool { owner != nil }

    public func withValue<Result: Sendable>(
        _ body: @Sendable (Value) async throws -> Result
    ) async throws -> Result {
        if let owner { return try await owner.withValue(body) }
        return try await body(value)
    }
}

private let lifecycleLocks = (0..<64).map { _ in LifecycleLock() }

/// A fixed set of cancellable gates avoids retaining an entry for each endpoint.
private actor LifecycleLock {
    private var held = false
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire() async throws(TmuxError) {
        if Task.isCancelled { throw .cancelled }
        if !held {
            held = true
            return
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        guard acquired else { throw .cancelled }
        if Task.isCancelled {
            release()
            throw .cancelled
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(returning: false)
        }
    }

    func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().1.resume(returning: true) }
    }
}

extension Server {
    private func coordinated<Value: Sendable>(
        _ body: () async throws -> Value
    ) async throws -> Value {
        try prepareEndpoint()
        guard case let .socketPath(path) = endpoint, let slash = path.lastIndex(of: "/") else {
            throw TmuxError.invalidEndpoint(.invalidSocketPath)
        }
        let parent = String(path[..<slash]).isEmpty ? "/" : String(path[..<slash])
        guard let physical = realpath(parent, nil) else {
            throw TmuxError.processLaunchFailed(
                reason: "cannot resolve the socket parent: \(String(cString: strerror(errno)))")
        }
        let key = String(cString: physical) + "/" + path[path.index(after: slash)...]
        free(physical)
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let lock = lifecycleLocks[Int(hash % UInt64(lifecycleLocks.count))]
        try await lock.acquire()
        do {
            let value = try await body()
            await lock.release()
            return value
        } catch {
            await lock.release()
            throw error
        }
    }

    private func lifecycleRunning() async throws(TmuxError) -> Bool {
        if Task.isCancelled { throw .cancelled }
        let command = TmuxCommand("list-sessions", ["-F", "#{session_id}"])
        let outcome = await runReceipted([command])
        if let failure = outcome.failure { throw failure }
        if outcome.reply.isSuccess { return true }
        let reason = outcome.reply.errorText
        if reason.hasPrefix("no server running on ")
            || reason.hasPrefix("error connecting to ")
                && reason.hasSuffix(" (No such file or directory)")
        {
            return false
        }
        throw outcome.reply.failure(for: command)
    }

    /// Finds the daemon at this endpoint, or starts and owns a new one.
    ///
    /// A private child-environment nonce proves startup through the same
    /// connection that creates the bootstrap session. A competing daemon stays
    /// borrowed, and only this call's bootstrap session is rolled back.
    public func findOrCreate(bootstrapSession name: String = "libtmux-bootstrap") async throws
        -> FindOrCreate<Server>
    {
        try await coordinated {
            if try await lifecycleRunning() { return .reused(self) }
            return try await startOwnedServer(bootstrapSession: name)
        }
    }

    /// Starts a daemon and accepts whole-server destruction responsibility.
    ///
    /// Use an explicit disposable endpoint. If another caller already owns the
    /// daemon, this call refuses whole-server ownership and removes only its own
    /// bootstrap session. `adopt()` is the explicit existing-daemon operation.
    public func newOwnedServer(bootstrapSession name: String = "libtmux-bootstrap") async throws
        -> OwnedTmux<Server>
    {
        try await coordinated {
            if try await lifecycleRunning() {
                throw TmuxError.invocationFailed(
                    reason: "server already exists; use adopt() to accept it")
            }
            let result = try await startOwnedServer(bootstrapSession: name)
            guard let owner = result.owner else {
                throw TmuxError.invocationFailed(reason: "another caller started this daemon")
            }
            return owner
        }
    }

    package func newOwnedServer(
        bootstrapSession name: String, configurationCommands: [TmuxCommand] = [],
        startupCommands: [TmuxCommand]
    ) async throws -> OwnedTmux<Server> {
        try await coordinated {
            if try await lifecycleRunning() {
                throw TmuxError.invocationFailed(reason: "fixture endpoint already exists")
            }
            guard
                let owner = try await startOwnedServer(
                    bootstrapSession: name, configurationCommands: configurationCommands,
                    startupCommands: startupCommands
                ).owner
            else {
                throw TmuxError.invocationFailed(
                    reason: "another caller started the fixture daemon")
            }
            return owner
        }
    }

    private func startOwnedServer(
        bootstrapSession name: String, configurationCommands: [TmuxCommand] = [],
        startupCommands: [TmuxCommand] = []
    ) async throws -> FindOrCreate<Server> {
        let token = ownershipToken()
        let variable = "LIBTMUX_STARTUP_" + token
        let receipt = OwnershipReceipt(kind: .session)
        let create = TmuxCommand(
            "new-session",
            [
                "-d", "-P", "-F", receipt.format,
                "-s", tmuxArgumentData(tmuxLiteralArgument(name)), "exec sh",
            ])
        let command = ownershipCommands(
            configurationCommands + [create, TmuxCommand("show-environment", ["-g", variable])]
                + startupCommands)
        let guarded = TmuxCommand(
            "if-shell",
            [
                "-F", validOwnerGeneration, command.parsedString,
                TmuxCommand("display-message", ["-p", "invalid libtmux ownership generation"])
                    .parsedString,
            ])
        let outcome = await runReceipted(
            [
                TmuxCommand("start-server"),
                TmuxCommand("set-option", ["-s", "-q", "-o", ownerGeneration, ownershipToken()]),
                guarded,
            ], environment: [variable: token], noStart: false)
        var lease = receipt.parse(outcome.reply, server: self)
        let started = outcome.reply.text.split(separator: "\n").contains(
            Substring(variable + "=" + token))
        if started { lease = lease?.asServer() }
        do {
            if let failure = outcome.failure { throw failure }
            guard let lease else {
                throw TmuxError.invocationFailed(reason: "no verified server startup receipt")
            }
            if !started {
                guard outcome.reply.exitCode == 1,
                    outcome.reply.errorText.contains("unknown variable: " + variable)
                else {
                    throw outcome.reply.failure(for: create)
                }
                try await lease.close()
                guard try await lifecycleRunning() else { throw TmuxError.serverRestarted }
                return .reused(self)
            }
            guard outcome.reply.isSuccess else { throw outcome.reply.failure(for: create) }
            guard
                let sessionID = SessionID(rawValue: receipt.parse(outcome.reply, server: self)!.id),
                let created = try await session(sessionID), created.name == name
            else {
                throw TmuxError.invocationFailed(
                    reason: "tmux did not retain the requested bootstrap name")
            }
            try await lease.verify()
            if Task.isCancelled { throw TmuxError.cancelled }
            return .created(
                OwnedTmux(self, lease: lease) { () async throws(TmuxError) in
                    try await lease.close()
                })
        } catch {
            throw await AcquisitionFailure(
                cause: error, lease: lease,
                commandFailure: outcome.reply.isSuccess ? nil : outcome.reply.failure(for: create))
        }
    }

    /// Finds one exact session name or creates an owned session.
    ///
    /// Calls using the same physical socket parent and filename coordinate
    /// within this process, including separate `Server` values. Other clients,
    /// socket-file symlink aliases and later renames remain outside that gate.
    /// Failed listings throw; they never trigger creation.
    public func findOrCreateSession(named name: String, shell: String? = nil) async throws
        -> FindOrCreate<Session>
    {
        try await coordinated {
            if try await lifecycleRunning() {
                let matches = try await sessions().filter { $0.name == name }
                guard matches.count <= 1 else {
                    throw CardinalityError.multipleMatches(count: matches.count)
                }
                if let value = matches.first { return .reused(value) }
            }
            return .created(try await newOwnedSession(named: name, shell: shell))
        }
    }

    /// Matches a window name exactly among the session's links; duplicates throw.
    public func findOrCreateWindow(in session: Session, named name: String, shell: String? = nil)
        async throws -> FindOrCreate<Window>
    {
        try await coordinated {
            let links = try await windowLinks().filter {
                $0.sessionID == session.id && $0.incarnation == session.incarnation
            }
            let ids = Set(links.map(\.windowID))
            let matches = try await windows().filter { ids.contains($0.id) && $0.name == name }
            guard matches.count <= 1 else {
                throw CardinalityError.multipleMatches(count: matches.count)
            }
            if let value = matches.first { return .reused(value) }
            return .created(try await newOwnedWindow(in: session, named: name, shell: shell))
        }
    }

    /// Matches pane-local `@libtmux_pane_identity` within one window.
    ///
    /// Reused panes remain borrowed. A new pane splits the window's first pane,
    /// and stores the supplied application identity on that pane alone.
    public func findOrCreatePane(in window: Window, identity: String, shell: String? = nil)
        async throws -> FindOrCreate<Pane>
    {
        guard !identity.isEmpty, !identity.contains("\0"), !identity.contains("\n") else {
            throw TmuxError.invocationFailed(reason: "pane identity must be a nonempty single line")
        }
        return try await coordinated {
            _ = try expectedIncarnation([window.incarnation])
            let candidates = try await panes().filter {
                $0.windowID == window.id && $0.incarnation == window.incarnation
            }
            var matches: [Pane] = []
            for candidate in candidates {
                let command = TmuxCommand(
                    "show-options",
                    ["-p", "-q", "-v", "-t", candidate.id.rawValue, "@libtmux_pane_identity"])
                let reply = try await runGuarded(command, by: [.pane(candidate)])
                guard reply.isSuccess else { throw reply.failure(for: command) }
                if reply.text == identity + "\n" { matches.append(candidate) }
            }
            guard matches.count <= 1 else {
                throw CardinalityError.multipleMatches(count: matches.count)
            }
            if let pane = matches.first { return .reused(pane) }
            guard let parent = candidates.first else { throw TmuxError.staleServerValue }
            let owner = try await splitOwned(parent, shell: shell)
            do {
                guard let lease = owner.lease else { throw TmuxError.staleServerValue }
                _ = try await lease.run(
                    TmuxCommand(
                        "set-option",
                        [
                            "-p", "-t", owner.value.id.rawValue,
                            "--", "@libtmux_pane_identity", identity,
                        ]))
                let stored = try await lease.run(
                    TmuxCommand(
                        "show-options",
                        [
                            "-p", "-q", "-v", "-t",
                            owner.value.id.rawValue, "@libtmux_pane_identity",
                        ]))
                guard stored.text == identity + "\n" else {
                    throw TmuxError.invocationFailed(
                        reason: "tmux did not retain the requested pane identity")
                }
                if Task.isCancelled { throw TmuxError.cancelled }
                return .created(owner)
            } catch {
                throw await AcquisitionFailure(cause: error, lease: owner.lease)
            }
        }
    }
}
