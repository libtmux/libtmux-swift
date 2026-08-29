import Subprocess

/// One submitted line, and the blocks tmux has answered it with so far.
///
/// A line is not always one block: tmux answers a `;` list with one per
/// command. So a waiter knows how many commands it sent and collects until it
/// has them — or until one comes back an error, because tmux runs a list only
/// as far as its first failure. Without this the surplus blocks outlive the
/// call that caused them and answer whichever command asks next.
private struct SubmittedLine {
    enum Completion {
        case counted(commands: Int)
        case fenced(marker: String)
    }

    let id: UInt64
    let completion: Completion
    let replyByteLimit: Int
    var collected: [ControlReply] = []
    var collectedBytes = 0
    var receivedCommands = 0
    var completionError: TmuxError?
    var answered = false
    /// Nil once cancellation has answered the caller. The line stays queued
    /// until tmux's reply is drained, preserving every later reply's position.
    var continuation: CheckedContinuation<Result<ControlReply, TmuxError>, Never>?

    mutating func consume(_ reply: ControlReply) {
        switch completion {
        case let .counted(commands):
            guard reply.isControlCommand else { return }
            if receivedCommands < Int.max { receivedCommands += 1 }
            collect(reply)
            answered = receivedCommands >= commands || reply.isError
        case let .fenced(marker):
            consumeFenced(reply, marker: marker)
        }
    }

    private mutating func consumeFenced(_ reply: ControlReply, marker: String) {
        guard reply.isControlCommand else { return }
        collect(reply)
        if reply.lines.contains(marker) {
            answered = true
            if reply.isError, completionError == nil {
                completionError = .invocationFailed(
                    reason: "guarded request ended with an invalid control marker"
                )
            }
        }
    }

    private mutating func collect(_ reply: ControlReply) {
        guard completionError == nil else { return }
        guard !reply.outputExceededLimit else {
            completionError = tmuxOutputLimitError(replyByteLimit)
            collected.removeAll(keepingCapacity: false)
            return
        }
        for line in reply.lines {
            let (lineBytes, lineOverflowed) = line.utf8.count.addingReportingOverflow(1)
            let (totalBytes, totalOverflowed) = collectedBytes.addingReportingOverflow(lineBytes)
            guard !lineOverflowed, !totalOverflowed, totalBytes <= replyByteLimit else {
                completionError = tmuxOutputLimitError(replyByteLimit)
                collected.removeAll(keepingCapacity: false)
                return
            }
            collectedBytes = totalBytes
        }
        collected.append(reply)
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

private struct AttachWaiter {
    let id: UInt64
    let continuation: CheckedContinuation<Result<Void, TmuxError>, Never>
}

/// A live control-mode connection.
///
/// Commands go in and numbered replies come back, so output belongs to the
/// command that produced it — the attribution a `;` list cannot give. Anything
/// the server volunteers meanwhile arrives on ``notifications``.
public actor ControlSession {
    private let write: @Sendable ([UInt8]) async throws -> Void
    private var parser: ControlProtocolParser
    private let replyByteLimit: Int
    private var pending: [SubmittedLine] = []
    private var nextSubmissionID: UInt64 = 0
    private var attachWaiters: [AttachWaiter] = []
    private var nextAttachWaiterID: UInt64 = 0
    private var lastWrite: Task<Void, Never>?
    private var isAttached = false
    /// Why the connection ended, once it has.
    ///
    /// ``finish(throwing:)`` can only fail the waiters that exist when it runs,
    /// so a command sent afterwards would wait on a reply nothing is left to
    /// deliver. This is what fails it instead — as
    /// ``TmuxError/requestNotSubmitted`` rather than as this reason, because a
    /// command that never reached tmux is safe to retry. ``waitUntilAttached()``
    /// reports the reason itself, where the distinction does not arise.
    private var closure: TmuxError?
    private nonisolated let broadcast: NotificationBroadcast

    /// Everything the server volunteered: `%output`, `%window-add`, and the
    /// rest.
    ///
    /// Each access is an observer of its own, and every observer sees every
    /// notification. Two iterators of one `AsyncStream` would divide them
    /// instead — which is the shape a waiter and a watcher on the same
    /// connection have, so it cannot be left to the caller to avoid.
    ///
    /// Anything that arrived before the first observer is replayed to it, so
    /// acting and then observing is not a race. That replay covers the first
    /// observer alone, and every later one starts where it subscribed — so two
    /// observers of one event are both taken before the command that causes it.
    /// An `async let` is late enough to miss it: its initializer is evaluated
    /// in the child task, not where it is written.
    /// A slow observer fails with ``TmuxError/notificationBufferOverflow(limit:)``
    /// rather than retaining connection output without bound.
    public nonisolated var notifications: ControlNotificationStream {
        broadcast.subscribe()
    }

    init(writer: StandardInputWriter) {
        self.write = { bytes in
            _ = try await writer.write(bytes)
        }
        self.parser = ControlProtocolParser()
        self.replyByteLimit = defaultTmuxReplyByteLimit
        self.broadcast = NotificationBroadcast()
    }

    init(
        write: @escaping @Sendable ([UInt8]) async throws -> Void,
        notificationLimit: Int = NotificationBroadcast.defaultLimit,
        replyByteLimit: Int = defaultTmuxReplyByteLimit
    ) {
        precondition(replyByteLimit >= 0)
        self.write = write
        self.parser = ControlProtocolParser(maximumReplyBytes: replyByteLimit)
        self.replyByteLimit = replyByteLimit
        self.broadcast = NotificationBroadcast(limit: notificationLimit)
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
    /// A reply exceeding 1 MiB fails with ``TmuxError/outputLimitExceeded(perStreamBytes:)``.
    public func send(_ command: TmuxCommand) async throws(TmuxError) -> ControlReply {
        try requireSingleLine(command.argumentVector)
        return try await send(
            line: command.argumentVector.map(tmuxQuoted).joined(separator: " ")
        )
    }

    /// - Parameters:
    ///   - line: the command line to send, already quoted.
    ///   - commands: how many commands that line carries, which is how many
    ///     blocks tmux may answer it with.
    func send(line: String, commands: Int = 1) async throws(TmuxError) -> ControlReply {
        try await requireReadyForSubmission()
        return try await enqueue(line: line, completion: .counted(commands: commands))
    }

    func sendFenced(line: String, marker: String) async throws(TmuxError) -> ControlReply {
        try await requireReadyForSubmission()
        return try await enqueue(line: line, completion: .fenced(marker: marker))
    }

    private func requireReadyForSubmission() async throws(TmuxError) {
        guard closure == nil else { throw TmuxError.requestNotSubmitted }
        do {
            try await waitUntilAttached()
        } catch {
            if Task.isCancelled { throw TmuxError.cancelled }
            throw TmuxError.requestNotSubmitted
        }
        // Waiting for attach suspends, so the connection can close before the
        // command is enqueued even when it was open at entry.
        guard closure == nil else { throw TmuxError.requestNotSubmitted }
    }

    private func enqueue(
        line: String,
        completion: SubmittedLine.Completion
    ) async throws(TmuxError) -> ControlReply {
        let id = nextSubmissionID
        nextSubmissionID &+= 1
        let result: Result<ControlReply, TmuxError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                // Registered before the write, because the reply can arrive while
                // the write is still suspended and a reply with nobody waiting is
                // discarded.
                pending.append(
                    SubmittedLine(
                        id: id,
                        completion: completion,
                        replyByteLimit: replyByteLimit,
                        continuation: continuation
                    )
                )
                let write = self.write
                // Chained to the previous send: the queue is ordered by who
                // entered the actor, and the writes have to reach tmux in that
                // same order or a reply lands on the wrong waiter.
                let previous = lastWrite
                lastWrite = Task { [line] in
                    await previous?.value
                    guard self.closure == nil else { return }
                    do {
                        try await write(Array("\(line)\n".utf8))
                    } catch {
                        // A failed write means the connection is gone, and the
                        // transport's word for it — `Broken pipe` — is not one this
                        // library promises. Otherwise the error a caller sees
                        // depends on whether the write or the read noticed first.
                        self.finish(throwing: TmuxError.connectionClosed)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelSubmission(id) }
        }
        return try result.get()
    }

    /// tmux answers the attach itself with a block, before any command is sent.
    /// Sending before it arrives would hand a command that block instead of its
    /// own reply, shifting every later answer by one.
    func waitUntilAttached() async throws(TmuxError) {
        if let closure { throw closure }
        guard !isAttached else { return }
        let id = nextAttachWaiterID
        nextAttachWaiterID &+= 1
        let result: Result<Void, TmuxError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .failure(.cancelled))
                    return
                }
                attachWaiters.append(AttachWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelAttachWaiter(id) }
        }
        return try result.get()
    }

    private func cancelAttachWaiter(_ id: UInt64) {
        guard let index = attachWaiters.firstIndex(where: { $0.id == id }) else { return }
        attachWaiters.remove(at: index).continuation.resume(returning: .failure(.cancelled))
    }

    private func cancelSubmission(_ id: UInt64) {
        guard let index = pending.firstIndex(where: { $0.id == id }),
            let continuation = pending[index].continuation
        else { return }
        pending[index].continuation = nil
        continuation.resume(returning: .failure(.cancelled))
    }

    /// Consumes one line of the server's output.
    ///
    /// Replies are matched to waiters in order because tmux answers in order,
    /// and the parser refuses a block whose number does not advance rather than
    /// letting one land on the wrong waiter. A block belongs to the oldest line
    /// that is still collecting — see ``SubmittedLine`` for why that is not one
    /// block each.
    func consume(_ line: String) {
        guard let event = parser.consume(line) else { return }
        switch event {
        case let .reply(reply):
            guard isAttached else {
                guard !reply.outputExceededLimit else {
                    finish(throwing: tmuxOutputLimitError(replyByteLimit))
                    return
                }
                guard !reply.isError else {
                    let replyText = reply.lines.joined(separator: "\n")
                    finish(
                        throwing: TmuxError.invocationFailed(
                            reason:
                                replyText.isEmpty
                                ? "tmux rejected the control-mode attachment" : replyText
                        )
                    )
                    return
                }
                isAttached = true
                let waiters = attachWaiters
                attachWaiters = []
                for waiter in waiters { waiter.continuation.resume(returning: .success(())) }
                return
            }
            guard !pending.isEmpty else { return }
            pending[0].consume(reply)
            guard pending[0].answered else { return }
            let answered = pending.removeFirst()
            guard let continuation = answered.continuation else { return }
            if let error = answered.completionError {
                continuation.resume(returning: .failure(error))
            } else {
                continuation.resume(returning: .success(answered.reply))
            }
        case let .notification(notification):
            broadcast.yield(notification)
        case .exited:
            finish(throwing: TmuxError.connectionClosed)
        case let .protocolViolation(reason):
            finish(
                throwing: TmuxError.invocationFailed(
                    reason: "control protocol violation: \(reason)"
                )
            )
        }
    }

    /// Fails every waiter and closes the notification stream.
    ///
    /// The default is ``TmuxError/connectionClosed`` rather than
    /// cancellation, because every way of getting here is the connection
    /// ending: tmux said `%exit`, its output stream ran out, or the scope
    /// that owned it returned. A caller told its command was cancelled would
    /// reasonably retry; one told the connection closed knows to reopen it.
    func finish(throwing error: TmuxError? = nil) {
        guard closure == nil else { return }
        let reason = error ?? TmuxError.connectionClosed
        closure = reason
        let waiters = pending
        pending = []
        for waiter in waiters {
            waiter.continuation?.resume(returning: .failure(reason))
        }
        let attaching = attachWaiters
        attachWaiters = []
        for waiter in attaching {
            waiter.continuation.resume(returning: .failure(reason))
        }
        broadcast.finish()
    }
}
