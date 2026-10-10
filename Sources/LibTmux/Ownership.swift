import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Both errors from a resource body and its awaited cleanup.
public struct ResourceScopeFailure: Error, Sendable {
    public let bodyError: any Error
    public let cleanupError: TmuxError
}

/// Responsibility for destroying one captured tmux object.
///
/// Use `withValue` to await cleanup on return, error or cancellation. Retaining
/// this actor alone does not schedule destruction: Swift `deinit` cannot await
/// a remote command. `close` coalesces concurrent calls and becomes a no-op only
/// after success. A failed call remains retryable, and `cleanupFailure` retains
/// its error. A window owner destroys the window and all of its session links.
public actor OwnedTmux<Value: Sendable> {
    public nonisolated let value: Value
    let lease: OwnershipLease?
    private let cleanup: @Sendable () async throws(TmuxError) -> Void
    private var attempt: Task<Result<Void, TmuxError>, Never>?
    private var attemptNumber = 0
    public private(set) var isClosed = false
    public private(set) var cleanupFailure: TmuxError?

    init(
        _ value: Value, lease: OwnershipLease? = nil,
        cleanup: @escaping @Sendable () async throws(TmuxError) -> Void
    ) {
        self.lease = lease
        self.value = value
        self.cleanup = cleanup
    }

    /// Destroys the captured object without inheriting caller cancellation.
    public func close() async throws(TmuxError) {
        if isClosed { return }
        let task: Task<Result<Void, TmuxError>, Never>
        if let attempt {
            task = attempt
        } else {
            task = Task.detached { [cleanup] in
                do throws(TmuxError) {
                    try await cleanup()
                    return .success(())
                } catch { return .failure(error) }
            }
            attemptNumber += 1
            attempt = task
        }
        let number = attemptNumber
        let result = await task.value
        if number == attemptNumber { attempt = nil }
        switch result {
        case .success:
            isClosed = true
            cleanupFailure = nil
        case let .failure(error):
            if number == attemptNumber { cleanupFailure = error }
            throw error
        }
    }

    /// Runs `body`, then awaits destruction, preserving either or both errors.
    public nonisolated func withValue<Result: Sendable>(
        _ body: @Sendable (Value) async throws -> Result
    ) async throws -> Result {
        let result: Swift.Result<Result, any Error>
        do { result = .success(try await body(value)) } catch { result = .failure(error) }
        do { try await close() } catch {
            if case let .failure(bodyError) = result {
                throw ResourceScopeFailure(bodyError: bodyError, cleanupError: error)
            }
            throw error
        }
        return try result.get()
    }
}

/// Acquisition failed after a command may have created a resource.
///
/// `cause` retains the original error. A verified receipt permits rollback;
/// `cleanupFailure` records that attempt, and `retryCleanup` repeats only that
/// captured cleanup. `hasReceipt == false` means no destructive authority was
/// recovered. Inspect the endpoint before making a separate cleanup decision.
public struct AcquisitionFailure: Error, Sendable {
    public let cause: any Error
    public let cleanupFailure: TmuxError?
    public let hasReceipt: Bool
    public let commandFailure: TmuxError?
    private let rollback: OwnedTmux<Void>?

    init(cause: any Error, lease: OwnershipLease?, commandFailure: TmuxError? = nil) async {
        self.commandFailure = commandFailure
        self.cause = cause
        hasReceipt = lease != nil
        rollback = lease.map { lease in
            OwnedTmux(()) { () async throws(TmuxError) in try await lease.close() }
        }
        do {
            try await rollback?.close()
            cleanupFailure = nil
        } catch { cleanupFailure = error }
    }

    /// Retries the failed receipt-bound cleanup, or fails if no receipt exists.
    public func retryCleanup() async throws(TmuxError) {
        guard let rollback else {
            throw .invocationFailed(reason: "acquisition has no verified cleanup receipt")
        }
        try await rollback.close()
    }
}

struct OwnershipLease: Sendable {
    enum Kind: String, Sendable {
        case server, session, window, pane
        var field: String {
            switch self {
            case .server: "pid"
            case .session: "session_id"
            case .window: "window_id"
            case .pane: "pane_id"
            }
        }
        var kill: String { "kill-" + rawValue }
    }

    let server: Server
    let kind: Kind
    let id: String
    let incarnation: ServerIncarnation
    let generation: String
    let exitObservation: DaemonExitObservation?

    func asServer() -> Self {
        Self(
            server: server, kind: .server, id: String(incarnation.processID),
            incarnation: incarnation, generation: generation,
            exitObservation: DaemonExitObservation(processID: incarnation.processID))
    }

    func request(_ command: TmuxCommand) -> GuardedRequest {
        GuardedRequest(
            command: command, incarnation: incarnation,
            targets: kind == .server
                ? [] : [GuardedTarget(target: id, condition: .equals(kind.field, id))],
            generation: generation)
    }

    func run(_ command: TmuxCommand, terminating: Bool = false) async throws(TmuxError) -> TmuxReply
    {
        let guardRequest = request(command)
        let outcome = await server.runReceipted(guardRequest.commands)
        if let error = outcome.failure { throw error }
        let reply =
            try terminating
            ? guardRequest.validateTerminating(outcome.reply) : guardRequest.validate(outcome.reply)
        guard reply.isSuccess else { throw reply.failure(for: command) }
        return reply
    }

    func verify() async throws(TmuxError) {
        _ = try await run(TmuxCommand("display-message", ["-p", "#{pid}"]))
    }

    func close() async throws(TmuxError) {
        if kind == .server, let exitObservation, exitObservation.hasExited { return }
        let command = TmuxCommand(kind.kill, kind == .server ? [] : ["-t", id])
        do { _ = try await run(command, terminating: true) } catch {
            // A terminating daemon may close the client before its final reply
            // fence. Observed exit is authoritative; a live daemon still makes
            // the command failure visible and retryable.
            if let exitObservation {
                do {
                    try await exitObservation.wait(within: .milliseconds(100))
                    return
                } catch {}
            }
            throw error
        }
        if kind == .server {
            guard let exitObservation else {
                throw .invocationFailed(reason: "cannot observe the owned daemon's exit")
            }
            try await exitObservation.wait()
        }
    }
}

/// Captures the local process before destruction; socket disappearance is not exit.
struct DaemonExitObservation: Sendable {
    let processID: Int
    private let birth: String?

    init(processID: Int) {
        self.processID = processID
        birth = Self.status(processID)?.birth
    }

    private static func status(_ pid: Int) -> (state: String, birth: String)? {
        #if os(Linux)
            guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let end = text.lastIndex(of: ")")
            else { return nil }
            let fields = text[text.index(after: end)...].split(separator: " ")
            guard fields.count > 19 else { return nil }
            return (String(fields[0]), String(fields[19]))
        #else
            return nil
        #endif
    }

    var hasExited: Bool {
        if kill(pid_t(processID), 0) != 0, errno == ESRCH { return true }
        #if os(Linux)
            if let current = Self.status(processID) {
                return current.state == "Z" || current.state == "X"
                    || birth.map { $0 != current.birth } == true
            }
        #endif
        return false
    }

    func wait(within timeout: Duration = .seconds(5)) async throws(TmuxError) {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !hasExited {
            guard ContinuousClock.now < deadline else {
                throw .invocationFailed(
                    reason: "owned daemon did not exit before the cleanup deadline")
            }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { throw .cancelled }
        }
    }
}

let ownerGeneration = "@libtmux_owner_generation"
let validOwnerGeneration =
    "#{m/r:^" + String(repeating: "[0-9a-fA-F]", count: 32)
    + "$ ,#{@libtmux_owner_generation}}".replacingOccurrences(of: " ", with: "")

func ownershipToken() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

struct OwnershipReceipt: Sendable {
    let prefix = "__libtmux_ownership_" + ownershipToken()
    let kind: OwnershipLease.Kind
    var format: String { "\(prefix)|#{\(kind.field)}|#{pid}|#{start_time}|#{\(ownerGeneration)}" }

    func parse(_ reply: TmuxReply, server: Server) -> OwnershipLease? {
        let lines = reply.text.split(separator: "\n").filter { $0.hasPrefix(prefix + "|") }
        guard lines.count == 1 else { return nil }
        let parts = lines[0].split(separator: "|", omittingEmptySubsequences: false).map(
            String.init)
        guard parts.count == 5, let pid = Int(parts[2]), pid > 0,
            let started = Int(parts[3]), started > 0,
            parts[4].utf8.count == 32,
            parts[4].utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { return nil }
        switch kind {
        case .server: guard Int(parts[1]) == pid else { return nil }
        case .session: guard SessionID(rawValue: parts[1]) != nil else { return nil }
        case .window: guard WindowID(rawValue: parts[1]) != nil else { return nil }
        case .pane: guard PaneID(rawValue: parts[1]) != nil else { return nil }
        }
        guard case let .socketPath(path) = server.endpoint else { return nil }
        return OwnershipLease(
            server: server, kind: kind, id: parts[1],
            incarnation: ServerIncarnation(
                endpoint: server.endpoint, socketPath: path,
                processID: pid, startedAt: started),
            generation: parts[4],
            exitObservation: DaemonExitObservation(processID: pid))
    }
}

func ownershipCommands(_ commands: [TmuxCommand]) -> TmuxCommand {
    TmuxCommand("if-shell", ["-F", "1", commands.map(\.parsedString).joined(separator: " ; "), ""])
}

extension Server {
    private func acquire(
        kind: OwnershipLease.Kind, parent: GuardedValue? = nil,
        start: Bool = false, rollbackOnFailure: Bool = true, environment: [String: String] = [:],
        command: (String) -> TmuxCommand
    ) async throws -> (OwnershipLease, TmuxReply) {
        if Task.isCancelled { throw TmuxError.cancelled }
        let receipt = OwnershipReceipt(kind: kind)
        let operation = command(receipt.format)
        let initialize = TmuxCommand(
            "set-option", ["-s", "-q", "-o", ownerGeneration, ownershipToken()])
        let invalid = TmuxCommand(
            "display-message", ["-p", "invalid libtmux ownership generation"])
        let guarded = TmuxCommand(
            "if-shell", ["-F", validOwnerGeneration, operation.parsedString, invalid.parsedString])
        let commands = [initialize, guarded]
        let request: GuardedRequest?
        let list: TmuxCommandList
        if let parent {
            request = GuardedRequest(
                command: ownershipCommands(commands),
                incarnation: try expectedIncarnation([parent.incarnation]),
                targets: [parent.targetGuard].compactMap { $0 })
            list = request!.commands
        } else {
            request = nil
            list = TmuxCommandList((start ? [TmuxCommand("start-server")] : []) + commands)
        }
        let outcome = await runReceipted(list, environment: environment, noStart: !start)
        let lease = receipt.parse(outcome.reply, server: self)
        do {
            if let error = outcome.failure { throw error }
            let reply = try request?.validate(outcome.reply) ?? outcome.reply
            guard reply.isSuccess else { throw reply.failure(for: operation) }
            guard let lease else {
                throw TmuxError.invocationFailed(reason: "no valid ownership receipt")
            }
            if let parent,
                lease.incarnation.processID != parent.incarnation.processID
                    || lease.incarnation.startedAt != parent.incarnation.startedAt
            {
                throw TmuxError.serverRestarted
            }
            return (lease, reply)
        } catch {
            // Contradictory identity must not turn an earlier ID into permission
            // to delete an object in a replacement daemon.
            let trusted = lease.flatMap { candidate in
                parent.map {
                    candidate.incarnation.processID == $0.incarnation.processID
                        && candidate.incarnation.startedAt == $0.incarnation.startedAt
                } ?? true
                    ? candidate : nil
            }
            throw await AcquisitionFailure(
                cause: error, lease: rollbackOnFailure ? trusted : nil,
                commandFailure: outcome.reply.isSuccess
                    ? nil : outcome.reply.failure(for: operation))
        }
    }

    private func owned<Value: Sendable>(
        lease: OwnershipLease, rollbackOnFailure: Bool = true, read: () async throws -> Value
    ) async throws -> OwnedTmux<Value> {
        do {
            let value = try await read()
            try await lease.verify()
            if Task.isCancelled { throw TmuxError.cancelled }
            return OwnedTmux(value, lease: lease) { () async throws(TmuxError) in
                try await lease.close()
            }
        } catch {
            throw await AcquisitionFailure(cause: error, lease: rollbackOnFailure ? lease : nil)
        }
    }

    /// Creates a session whose ID and daemon generation belong to the returned owner.
    ///
    /// The reserved server option `@libtmux_owner_generation` is initialized
    /// once. Existing tokens must contain 32 hexadecimal characters. Do not
    /// change or shadow that option. Creation replies retain cleanup receipts
    /// before status, decoding and cancellation checks.
    public func newOwnedSession(named name: String, shell: String? = nil) async throws -> OwnedTmux<
        Session
    > {
        let (lease, _) = try await acquire(kind: .session, start: true) { format in
            TmuxCommand(
                "new-session",
                ["-d", "-P", "-F", format, "-s", tmuxArgumentData(tmuxLiteralArgument(name))]
                    + (shell.map { [$0] } ?? []))
        }
        return try await owned(lease: lease) {
            guard let id = SessionID(rawValue: lease.id), let value = try await session(id),
                value.name == name
            else {
                throw TmuxError.invocationFailed(
                    reason: "tmux did not retain the requested session name")
            }
            return value
        }
    }

    /// Creates an owned window in `session`; cleanup destroys all links to it.
    public func newOwnedWindow(in session: Session, named name: String, shell: String? = nil)
        async throws -> OwnedTmux<Window>
    {
        let (lease, _) = try await acquire(kind: .window, parent: .session(session)) { format in
            TmuxCommand(
                "new-window",
                [
                    "-d", "-P", "-F", format, "-t", session.id.rawValue,
                    "-n", tmuxArgumentData(tmuxLiteralArgument(name)),
                ] + (shell.map { [$0] } ?? []))
        }
        return try await owned(lease: lease) {
            guard let id = WindowID(rawValue: lease.id), let value = try await window(id),
                value.name == name
            else {
                throw TmuxError.invocationFailed(
                    reason: "tmux did not retain the requested window name")
            }
            return value
        }
    }

    /// Splits `pane` and owns the new pane, independent of its later index or window.
    public func splitOwned(_ pane: Pane, direction: PaneDirection = .below, shell: String? = nil)
        async throws -> OwnedTmux<Pane>
    {
        let (lease, _) = try await acquire(kind: .pane, parent: .pane(pane)) { format in
            TmuxCommand(
                "split-window",
                ["-d", "-P", "-F", format, "-t", pane.id.rawValue]
                    + direction.flags + (shell.map { [$0] } ?? []))
        }
        return try await owned(lease: lease) {
            guard let id = PaneID(rawValue: lease.id), let value = try await self.pane(id) else {
                throw TmuxError.staleServerValue
            }
            return value
        }
    }

    /// Accepts destruction responsibility for this existing daemon.
    public func adopt() async throws -> OwnedTmux<Server> {
        let (lease, _) = try await acquire(kind: .server, rollbackOnFailure: false) {
            TmuxCommand("display-message", ["-p", $0])
        }
        return try await owned(lease: lease, rollbackOnFailure: false) { self }
    }

    /// Accepts destruction responsibility for an existing session by its captured ID.
    public func adopt(_ session: Session) async throws -> OwnedTmux<Session> {
        try await adoptValue(
            session, parent: .session(session), kind: .session, id: session.id.rawValue)
    }

    /// Accepts destruction responsibility for a window, including all session links.
    public func adopt(_ window: Window) async throws -> OwnedTmux<Window> {
        try await adoptValue(window, parent: .window(window), kind: .window, id: window.id.rawValue)
    }

    /// Accepts destruction responsibility for a pane by its captured ID.
    public func adopt(_ pane: Pane) async throws -> OwnedTmux<Pane> {
        try await adoptValue(pane, parent: .pane(pane), kind: .pane, id: pane.id.rawValue)
    }

    private func adoptValue<Value: Sendable>(
        _ value: Value, parent: GuardedValue,
        kind: OwnershipLease.Kind, id: String
    ) async throws -> OwnedTmux<Value> {
        let (lease, _) = try await acquire(kind: kind, parent: parent, rollbackOnFailure: false) {
            format in
            TmuxCommand("display-message", ["-p", "-t", id, format])
        }
        guard lease.id == id else { throw TmuxError.staleServerValue }
        return try await owned(lease: lease, rollbackOnFailure: false) { value }
    }
}
