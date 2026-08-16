import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

/// One submitted line, and the blocks tmux has answered it with so far.
///
/// A line is not always one block: tmux answers a `;` list with one per
/// command. So a waiter knows how many commands it sent and collects until it
/// has them — or until one comes back an error, because tmux runs a list only
/// as far as its first failure. Without this the surplus blocks outlive the
/// call that caused them and answer whichever command asks next.
private struct SubmittedLine {
    let commands: Int
    var collected: [ControlReply] = []
    let continuation: CheckedContinuation<ControlReply, any Error>

    /// Whether tmux has said everything it is going to about this line.
    var isAnswered: Bool {
        collected.count >= commands || collected.contains(where: \.isError)
    }

    /// The blocks as the one reply the caller asked for. A process concatenates
    /// a list's output onto one stream and reports one status; this is the same
    /// answer assembled from the pieces a connection reports it in.
    var reply: ControlReply {
        ControlReply(
            number: collected.first?.number ?? 0,
            lines: collected.flatMap(\.lines),
            isError: collected.contains(where: \.isError)
        )
    }
}

/// A live control-mode connection.
///
/// Commands go in and numbered replies come back, so output belongs to the
/// command that produced it — the attribution a `;` list cannot give. Anything
/// the server volunteers meanwhile arrives on ``notifications``.
public actor ControlSession {
    private let writer: StandardInputWriter
    private var parser = ControlProtocolParser()
    private var pending: [SubmittedLine] = []
    private var attachWaiters: [CheckedContinuation<Void, any Error>] = []
    private var lastWrite: Task<Void, Never>?
    private var isAttached = false
    /// Why the connection ended, once it has.
    ///
    /// ``finish(throwing:)`` can only fail the waiters that exist when it runs.
    /// A command sent after that point would queue a continuation nothing is
    /// left to answer — the reader that resumes them is gone — so it waits for a
    /// reply that cannot arrive. Remembering the reason lets a late send fail
    /// with it instead.
    private var closure: (any Error)?
    private let notificationSink: AsyncStream<ControlNotification>.Continuation

    /// Everything the server volunteered: `%output`, `%window-add`, and the
    /// rest. Buffered, so a consumer that starts late still sees what it
    /// missed.
    public nonisolated let notifications: AsyncStream<ControlNotification>

    init(writer: StandardInputWriter) {
        self.writer = writer
        var sink: AsyncStream<ControlNotification>.Continuation!
        // Unbounded, because `%output` carries pane bytes rather than state:
        // dropping one loses terminal output with nothing to indicate it went
        // missing, and a consumer watching for a particular line would wait
        // for something that was silently discarded. A caller that opens a
        // connection is expected to drain this or keep the scope short.
        self.notifications = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        self.notificationSink = sink
    }

    /// Sends a command and waits for the block tmux brackets its reply with.
    ///
    /// A tmux error closes the block with `%error` rather than failing the
    /// connection, so it comes back as a reply whose ``ControlReply/isError``
    /// is set — the same way a nonzero exit is a reply elsewhere in this
    /// library.
    ///
    /// Concurrent sends are safe. tmux answers in the order it receives
    /// commands, so replies are matched to waiters in that order — which holds
    /// because writes are chained, not merely because they are usually fast.
    public func send(_ command: TmuxCommand) async throws -> ControlReply {
        try requireSingleLine(command.argumentVector)
        return try await send(
            line: command.argumentVector.map(tmuxQuoted).joined(separator: " ")
        )
    }

    /// - Parameters:
    ///   - line: the command line to send, already quoted.
    ///   - commands: how many commands that line carries, which is how many
    ///     blocks tmux may answer it with.
    func send(line: String, commands: Int = 1) async throws -> ControlReply {
        if let closure { throw closure }
        try await waitUntilAttached()
        // Checked again: waiting for the attach suspends, and the connection
        // can end while it does.
        if let closure { throw closure }
        return try await withCheckedThrowingContinuation { continuation in
            // Registered before the write, because the reply can arrive while
            // the write is still suspended and a reply with nobody waiting is
            // discarded.
            pending.append(
                SubmittedLine(commands: commands, continuation: continuation)
            )
            let writer = self.writer
            // Chained to the previous send: the queue is ordered by who
            // entered the actor, and the writes have to reach tmux in that
            // same order or a reply lands on the wrong waiter.
            let previous = lastWrite
            lastWrite = Task { [line] in
                await previous?.value
                do {
                    _ = try await writer.write(Array("\(line)\n".utf8))
                } catch {
                    // A failed write means the connection is gone, and the
                    // transport's word for it — `Broken pipe` — is not one this
                    // library promises. Otherwise the error a caller sees
                    // depends on whether the write or the read noticed first.
                    self.failOldestWaiter(TmuxError.connectionClosed)
                }
            }
        }
    }

    /// tmux answers the attach itself with a block, before any command is sent.
    /// Sending before it arrives would hand a command that block instead of its
    /// own reply, shifting every later answer by one.
    private func waitUntilAttached() async throws {
        guard !isAttached else { return }
        try await withCheckedThrowingContinuation { continuation in
            attachWaiters.append(continuation)
        }
    }

    private func failOldestWaiter(_ error: any Error) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().continuation.resume(throwing: error)
    }

    /// Consumes one line of the server's output.
    ///
    /// Replies are matched to waiters in order because tmux answers in order;
    /// the number on each block is what proves that assumption rather than
    /// assuming it. A block belongs to the oldest line that is still collecting
    /// — see ``SubmittedLine`` for why that is not one block each.
    func consume(_ line: String) {
        guard let event = parser.consume(line) else { return }
        switch event {
        case let .reply(reply):
            guard isAttached else {
                isAttached = true
                let waiters = attachWaiters
                attachWaiters = []
                for waiter in waiters { waiter.resume() }
                return
            }
            guard !pending.isEmpty else { return }
            pending[0].collected.append(reply)
            guard pending[0].isAnswered else { return }
            let answered = pending.removeFirst()
            answered.continuation.resume(returning: answered.reply)
        case let .notification(notification):
            notificationSink.yield(notification)
        case .exited:
            finish(throwing: TmuxError.connectionClosed)
        }
    }

    /// Fails every waiter and closes the notification stream.
    ///
    /// The default is ``TmuxError/connectionClosed`` rather than
    /// cancellation, because every way of getting here is the connection
    /// ending: tmux said `%exit`, its output stream ran out, or the scope
    /// that owned it returned. A caller told its command was cancelled would
    /// reasonably retry; one told the connection closed knows to reopen it.
    func finish(throwing error: (any Error)? = nil) {
        let reason = error ?? TmuxError.connectionClosed
        closure = reason
        let waiters = pending
        pending = []
        for waiter in waiters {
            waiter.continuation.resume(throwing: reason)
        }
        let attaching = attachWaiters
        attachWaiters = []
        for waiter in attaching {
            waiter.resume(throwing: reason)
        }
        notificationSink.finish()
    }
}

extension Server {
    /// Runs `body` with every command carried by one live connection instead
    /// of a new tmux process each time.
    ///
    /// The server handed to `body` is this server: the same calls, the same
    /// return types, the same errors. Only how the work reaches tmux changes.
    ///
    /// ```swift
    /// let names = try await server.connected(attachingTo: "main") { server, _ in
    ///     try await server.sessions().map(\.name)
    /// }
    /// ```
    ///
    /// A connection is a client, and tmux has no client that is attached to
    /// nothing — a control client with no target runs tmux's default command
    /// and creates a session. So the connection attaches to `session`, and that
    /// is visible in what the server reports about itself: that session reads
    /// as attached, and ``Server/clients()`` includes the connection. Nothing
    /// else differs.
    ///
    /// The connection is handed over too, because it can do one thing a
    /// process cannot: report what changed without being asked. That capability
    /// exists only here, and so does the value carrying it — there is no way to
    /// write a `%output` reader against a server that has no connection.
    ///
    /// - Parameters:
    ///   - session: the session to attach to, which must already exist.
    ///   - body: the work to run, given this server and the connection
    ///     carrying it.
    public func connected<Result: Sendable>(
        attachingTo session: String,
        _ body: @escaping @Sendable (Server, ControlSession) async throws -> Result
    ) async throws -> Result {
        let server = self
        return try await withControlMode(attachingTo: session) { control in
            try await body(
                Server(server, dispatchingOver: control, attachedTo: session),
                control
            )
        }
    }

    /// Runs `body` with this server in `mode`.
    ///
    /// The one switch. Every call inside is the call you would write anyway and
    /// hands back the type it would hand back anyway; `mode` decides only how it
    /// travels. Reach for this when the choice is made at runtime — a flag, a
    /// config, a benchmark running both — so it stays a value rather than two
    /// shapes of code:
    ///
    /// ```swift
    /// let mode: TmuxMode = attachToExisting ? .connected(to: "main") : .direct
    /// let names = try await server.using(mode) { server in
    ///     try await server.sessions().map(\.name)
    /// }
    /// ```
    ///
    /// Scoped even for ``TmuxMode/direct``, where nothing needs closing, so that
    /// the two read identically at the call site. ``connected(attachingTo:_:)``
    /// is the same thing with the connection handed over as well, for the one
    /// capability a process does not have.
    ///
    /// Modes nest, and the innermost wins: `using(.direct)` inside a connected
    /// scope gives back a server that spawns processes, which is the supported
    /// way to keep one call off a connection.
    public func using<Result: Sendable>(
        _ mode: TmuxMode,
        _ body: @escaping @Sendable (Server) async throws -> Result
    ) async throws -> Result {
        switch mode {
        case .direct:
            return try await body(Server(self, dispatchingOver: nil, attachedTo: nil))
        case let .connected(session):
            return try await connected(attachingTo: session) { server, _ in
                try await body(server)
            }
        }
    }

    /// Opens a control-mode connection for the duration of `body`, handing
    /// over the connection itself.
    ///
    /// ``connected(attachingTo:_:)`` is the one to reach for: it gives the same
    /// connection *and* a server that speaks over it. This is the layer beneath,
    /// for talking the control protocol directly.
    ///
    /// Scoped rather than handed out: the connection is a live process, and a
    /// value that outlives its process is a value that lies. When `body`
    /// returns, the session is closed and the child is reaped before this call
    /// does.
    ///
    /// - Parameters:
    ///   - session: the session to attach to. Control mode reports `%output`
    ///     only for a session it is attached to, so a connection with no
    ///     target sees command replies and little else.
    ///   - body: the work to run against the connection.
    public func withControlMode<Result: Sendable>(
        attachingTo session: String,
        _ body: @escaping @Sendable (ControlSession) async throws -> Result
    ) async throws -> Result {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true

        let arguments =
            ["-u", "-C"] + endpoint.addressArguments
            + ["attach-session", "-t", session]

        let outcome = try await Subprocess.run(
            Subprocess.Configuration(
                executable: .path(FilePath(tmuxExecutablePath)),
                arguments: Arguments(arguments),
                environment: .custom(
                    TmuxProcessEnvironment.variables().reduce(into: [:]) {
                        keys, variable in
                        keys[Subprocess.Environment.Key(rawValue: variable.key)!] =
                            variable.value
                    }
                ),
                platformOptions: platformOptions
            ),
            input: .inputWriter,
            output: .sequence,
            error: .discarded
        ) { execution in
            let control = ControlSession(writer: execution.standardInputWriter)
            return try await withThrowingTaskGroup(
                of: ControlOutcome<Result>.self
            ) { group in
                group.addTask {
                    var line: [UInt8] = []
                    for try await chunk in execution.standardOutput {
                        for byte in chunk.withUnsafeBytes({ Array($0) }) {
                            if byte == UInt8(ascii: "\n") {
                                await control.consume(
                                    String(decoding: line, as: UTF8.self)
                                )
                                line.removeAll(keepingCapacity: true)
                            } else {
                                line.append(byte)
                            }
                        }
                    }
                    await control.finish()
                    return .streamEnded
                }
                group.addTask {
                    defer { Task { await control.finish() } }
                    return .body(try await body(control))
                }

                var result: Result?
                while let outcome = try await group.next() {
                    if case let .body(value) = outcome {
                        result = value
                        break
                    }
                }
                group.cancelAll()
                try? execution.send(signal: .terminate, toProcessGroup: true)
                // Reached only if the reader finished before the body did,
                // which means tmux went away underneath it.
                guard let result else { throw TmuxError.connectionClosed }
                return result
            }
        }
        return outcome.closureResult
    }
}

private enum ControlOutcome<Value: Sendable>: Sendable {
    case body(Value)
    case streamEnded
}

/// Refuses an argument a command line cannot carry.
///
/// A connection sends commands one per line, so a newline inside an argument
/// ends the command there and leaves the rest to be read as the next one — and
/// tmux answers the truncated command, successfully, having done something the
/// caller did not ask for.
///
/// There is no encoding that avoids it. Single quotes leave the newline as a
/// newline. Double quotes carry it as `\n`, but tmux expands `#` and `$` inside
/// them and offers no escape for `#`, so any value that might contain a format
/// sequence would be rewritten instead. A process takes an argument vector and
/// has none of this trouble, which is why the same call is fine in the default
/// mode.
func requireSingleLine(_ arguments: [String]) throws(TmuxError) {
    guard arguments.allSatisfy({ !$0.contains("\n") }) else {
        throw .invocationFailed(
            reason:
                "an argument containing a newline cannot be sent over a control "
                + "connection; run this on a server without one"
        )
    }
}

/// Quotes one argument for tmux's own command parser.
///
/// Control mode takes a command *line*, not argv, so tmux re-parses what is
/// sent: `#` opens a comment, and whitespace and quotes separate or group.
/// A format like `#{session_name}` therefore has to be quoted or it vanishes
/// mid-command.
func tmuxQuoted(_ argument: String) -> String {
    let safe = argument.allSatisfy { character in
        character.isLetter || character.isNumber
            || "_-./=:@%+,".contains(character)
    }
    if safe, !argument.isEmpty { return argument }
    return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

extension ControlSession {
    /// Answers a process-shaped request from the connection.
    ///
    /// The rest of the library asks for a listing the same way whatever is
    /// carrying it, so a connection has to reply in the shape a process would:
    /// bytes, and a status. A command tmux rejected keeps its meaning as a
    /// reply rather than becoming a thrown error — the same contract
    /// ``Server/run(_:)`` states — so its text lands on standard error with a
    /// nonzero status instead.
    func reply(to rawArguments: [String]) async throws(TmuxError) -> TmuxReply {
        guard !rawArguments.isEmpty else {
            return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
        }
        try requireSingleLine(rawArguments)
        // A list arrives as its commands with `;` between them, and the
        // separator has to stay punctuation. Quoting it the way an argument is
        // quoted would make it a literal, and tmux would read a whole list as
        // one command with a `;` in the middle of it — running the first and
        // silently dropping the rest.
        let commands = rawArguments.split(separator: TmuxCommandList.separator)
        let line =
            commands
            .map { $0.map(tmuxQuoted).joined(separator: " ") }
            .joined(separator: " \(TmuxCommandList.separator) ")

        let reply: ControlReply
        do {
            // How many commands went out is how many blocks may come back.
            reply = try await send(line: line, commands: commands.count)
        } catch let error as TmuxError {
            throw error
        } catch {
            throw TmuxError.invocationFailed(reason: String(describing: error))
        }

        // A process ends its output with a newline; the connection reports
        // lines. Restore it, so both spellings decode to the same rows.
        let bytes =
            reply.lines.isEmpty
            ? []
            : Array((reply.lines.joined(separator: "\n") + "\n").utf8)
        return TmuxReply(
            standardOutput: reply.isError ? [] : bytes,
            standardError: reply.isError ? bytes : [],
            exitCode: reply.isError ? 1 : 0
        )
    }
}
