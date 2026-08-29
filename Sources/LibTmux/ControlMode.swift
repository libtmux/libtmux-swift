import Foundation
import Subprocess

#if canImport(System)
    import System
#else
    import SystemPackage
#endif

extension Server {
    func connected<Result: Sendable>(
        attachingTo sessionID: SessionID,
        expecting incarnation: ServerIncarnation,
        _ body: @escaping @Sendable (Server, ControlSession) async throws(TmuxError) -> Result
    ) async throws(TmuxError) -> Result {
        try await withTmuxErrorMapping {
            try await connectedGuardingIncarnation(
                attachingTo: sessionID,
                expecting: incarnation,
                body
            )
        }
    }

    func connectedGuardingIncarnation<Result: Sendable>(
        attachingTo sessionID: SessionID,
        expecting incarnation: ServerIncarnation,
        _ body: @escaping @Sendable (Server, ControlSession) async throws -> Result
    ) async throws -> Result {
        let expected = try expectedIncarnation([incarnation])
        guard try await self.incarnation() == expected else {
            throw TmuxError.serverRestarted
        }
        do {
            return try await connected(attachingTo: sessionID.rawValue) { server, control in
                let request = GuardedRequest(
                    command: TmuxCommand(
                        "display-message",
                        ["-p", "-t", sessionID.rawValue, "#{session_id}"]
                    ),
                    incarnation: expected,
                    targets: [
                        GuardedTarget(
                            target: sessionID.rawValue,
                            condition: .equals("session_id", sessionID.rawValue)
                        )
                    ]
                )
                _ = try request.validate(await control.reply(to: request))
                return try await body(server, control)
            }
        } catch TmuxError.connectionClosed {
            guard try await self.incarnation() == expected else {
                throw TmuxError.serverRestarted
            }
            throw TmuxError.connectionClosed
        }
    }

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
    /// The handed-out values do not keep the connection alive. Do not return
    /// or store them; calls made after `body` ends fail because the process has
    /// already been reaped.
    ///
    /// - Parameters:
    ///   - session: the session to attach to, which must already exist.
    ///   - body: the work to run, given this server and the connection
    ///     carrying it.
    /// - Throws: ``TmuxError/connectionClosed`` if the connection ends before
    ///   `body`, including when `body` detaches its own client.
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
    /// A server handed to a connected `body` does not keep that connection
    /// alive when returned or stored.
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
    /// The process is scoped even though Swift can retain the actor handed to
    /// `body`. Returning or storing it does not extend the process lifetime;
    /// later calls fail. When `body` returns, the session is closed and the
    /// child is reaped before this call does.
    ///
    /// Connection loss cancels `body`; teardown still waits for code that
    /// ignores cancellation.
    ///
    /// - Parameters:
    ///   - session: the session to attach to. Control mode reports `%output`
    ///     only for a session it is attached to, so a connection with no
    ///     target sees command replies and little else.
    ///   - body: the work to run against the connection.
    /// - Throws: ``TmuxError/connectionClosed`` if the connection ends before
    ///   `body`, including when `body` detaches its own client.
    public func withControlMode<Result: Sendable>(
        attachingTo session: String,
        _ body: @escaping @Sendable (ControlSession) async throws -> Result
    ) async throws -> Result {
        var platformOptions = PlatformOptions()
        platformOptions.createSession = true

        let arguments =
            ["-u", "-C"] + endpoint.addressArguments
            + ["attach-session", "-E", "-t", session]

        let outcome = try await Subprocess.run(
            Subprocess.Configuration(
                executable: .path(FilePath(tmuxExecutablePath)),
                arguments: Arguments(arguments),
                environment: .custom(
                    TmuxProcessEnvironment.controlAttachmentVariables().reduce(into: [:]) {
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
                defer {
                    group.cancelAll()
                    try? execution.send(signal: .terminate, toProcessGroup: true)
                }
                group.addTask {
                    var input = ControlLineInput()
                    for try await chunk in execution.standardOutput {
                        let data = chunk.withUnsafeBytes { Data($0) }
                        for event in input.append(data) {
                            try await consumeControlInput(event, with: control)
                        }
                    }
                    for event in input.finish() {
                        try await consumeControlInput(event, with: control)
                    }
                    await control.finish()
                    return .streamEnded
                }
                try await control.waitUntilAttached()
                group.addTask {
                    defer { Task { await control.finish() } }
                    return .body(try await body(control))
                }

                while let outcome = try await group.next() {
                    switch outcome {
                    case let .body(value):
                        return value
                    case .streamEnded:
                        group.cancelAll()
                        do {
                            while try await group.next() != nil {}
                        } catch {}
                        throw TmuxError.connectionClosed
                    }
                }
                throw TmuxError.connectionClosed
            }
        }
        return outcome.closureResult
    }
}

private func consumeControlInput(
    _ event: ControlLineInput.Event,
    with control: ControlSession
) async throws(TmuxError) {
    switch event {
    case let .line(line):
        await control.consume(line)
    case let .failure(error):
        await control.finish(throwing: error)
        throw error
    }
}

private enum ControlOutcome<Value: Sendable>: Sendable {
    case body(Value)
    case streamEnded
}
