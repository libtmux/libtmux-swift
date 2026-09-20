import CProcessObservation
import Dispatch
import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Owns process handles and a reconnecting control scope for one captured shell.
final class RunShellObservation: Sendable {
    private let processes: [RunShellProcessExit]
    private let monitor: Task<Void, Never>
    private let ended: RunShellSignal
    private let health: RunShellSignal
    private let ready: RunShellSignal

    private init(
        processes: [RunShellProcessExit], monitor: Task<Void, Never>,
        ended: RunShellSignal, health: RunShellSignal, ready: RunShellSignal
    ) {
        self.processes = processes
        self.monitor = monitor
        self.ended = ended
        self.health = health
        self.ready = ready
    }

    static func start(
        for pane: Pane, using server: Server, within timeout: Duration
    ) async throws -> RunShellObservation {
        let observation = try await observe(pane, using: server)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask { try await observation.ready.wait() }
                group.addTask {
                    try await Task.sleep(for: max(.zero, timeout))
                    throw TmuxError.timedOut(after: max(.zero, timeout))
                }
                try await group.next()
            }
            return observation
        } catch {
            await observation.close()
            throw error
        }
    }

    static func observe(_ pane: Pane, using server: Server) async throws -> RunShellObservation {
        let server = server.withTimeout(min(server.commandTimeout ?? .seconds(1), .seconds(1)))
        guard let process = pane.processID else { throw TmuxError.staleServerValue }
        let shell = try RunShellProcessExit(process)
        let daemon: RunShellProcessExit
        do {
            daemon = try RunShellProcessExit(pane.incarnation.processID)
        } catch {
            await shell.close()
            throw error
        }
        let ready = RunShellSignal()
        let ended = RunShellSignal()
        let health = RunShellSignal()
        let monitor = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { group.cancelAll() }
                    group.addTask { try await shell.wait() }
                    group.addTask { try await daemon.wait() }
                    group.addTask {
                        try await server.using(.direct) { direct in
                            while true {
                                do {
                                    try await observeTopology(pane, using: direct, ready: ready)
                                    return
                                } catch {
                                    try Task.checkCancellation()
                                    let failure =
                                        error as? TmuxError
                                        ?? .invocationFailed(reason: String(describing: error))
                                    await ready.finish(.failure(failure))
                                    await health.finish(.failure(failure))
                                    try await Task.sleep(for: .milliseconds(100))
                                }
                            }
                        }
                    }
                    try await group.next()
                }
                await ended.finish(.success(()))
                await health.finish(.success(()))
                await ready.finish(.failure(.staleServerValue))
            } catch {
                await ended.finish(.failure(.cancelled))
                await health.finish(.failure(.cancelled))
                await ready.finish(.failure(.cancelled))
            }
        }
        return RunShellObservation(
            processes: [shell, daemon], monitor: monitor,
            ended: ended, health: health, ready: ready)
    }

    func wait() async throws { try await health.wait() }

    func waitForEnd() async throws { try await ended.wait() }

    func whileAlive<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await operation() }
            group.addTask {
                try await self.wait()
                throw TmuxError.staleServerValue
            }
            guard let result = try await group.next() else { throw TmuxError.cancelled }
            return result
        }
    }

    func close() async {
        monitor.cancel()
        await monitor.value
        for process in processes { await process.close() }
    }

    private static let topologyNotifications: Set<String> = [
        "layout-change", "session-window-changed", "unlinked-window-add",
        "unlinked-window-close", "window-add", "window-close", "window-pane-changed",
    ]

    private static func observeTopology(
        _ pane: Pane, using server: Server, ready: RunShellSignal
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard let session = try await attachment(pane, using: server) else { return }
            do {
                let ended = try await server.connectedGuardingIncarnation(
                    attachingTo: session, expecting: pane.incarnation
                ) { connected, control in
                    let notifications = control.notifications
                    guard let current = try await attachment(pane, using: connected) else {
                        return true
                    }
                    guard current == session else { return false }
                    await ready.finish(.success(()))
                    let (checks, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(
                        bufferingPolicy: .bufferingNewest(1))
                    // Respawning a live pane need not emit a topology notification.
                    let timer = DispatchSource.makeTimerSource(queue: .global())
                    timer.schedule(
                        deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                    timer.setEventHandler { continuation.yield(()) }
                    timer.activate()
                    defer {
                        timer.cancel()
                        continuation.finish()
                    }
                    return try await withThrowingTaskGroup(of: Void.self) { group in
                        defer { group.cancelAll() }
                        group.addTask {
                            do {
                                for try await notification in notifications {
                                    if topologyNotifications.contains(notification.name) {
                                        continuation.yield(())
                                    }
                                }
                                continuation.finish()
                            } catch { continuation.finish(throwing: error) }
                        }
                        for try await _ in checks {
                            try Task.checkCancellation()
                            guard let current = try await attachment(pane, using: connected) else {
                                return true
                            }
                            if current != session { return false }
                        }
                        return false
                    }
                }
                if ended { return }
            } catch {
                try Task.checkCancellation()
                if try await attachment(pane, using: server) == nil { return }
                guard let tmuxError = error as? TmuxError,
                    tmuxError == .connectionClosed || tmuxError == .staleServerValue
                else { throw error }
            }
        }
    }

    private static func attachment(_ pane: Pane, using server: Server) async throws -> SessionID? {
        let value: String?
        do {
            value = try await server.formatGlobal(
                "#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}", for: pane)
        } catch {
            if error == .serverRestarted { return nil }
            if let process = Int32(exactly: pane.incarnation.processID), process > 0 {
                errno = 0
                if kill(process, 0) == -1 && errno == ESRCH { return nil }
            }
            throw error
        }
        guard let value else { return nil }
        let fields = value.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[1] == pane.id.rawValue,
            let process = Int(fields[2]), let session = SessionID(rawValue: String(fields[0])),
            fields[3] == "0" || fields[3] == "1"
        else { throw TmuxError.invocationFailed(reason: "invalid shell lifecycle snapshot") }
        return process == pane.processID && fields[3] == "0" ? session : nil
    }
}

private actor RunShellSignal {
    private var result: Result<Void, TmuxError>?
    private var observers: [UUID: AsyncStream<Result<Void, TmuxError>>.Continuation] = [:]

    func finish(_ result: Result<Void, TmuxError>) {
        guard self.result == nil else { return }
        self.result = result
        let current = observers.values
        observers = [:]
        for observer in current {
            observer.yield(result)
            observer.finish()
        }
    }

    func wait() async throws {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let id = UUID()
        let (events, continuation) = AsyncStream<Result<Void, TmuxError>>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id) }
        }
        defer { observers.removeValue(forKey: id) }
        for await result in events {
            try Task.checkCancellation()
            return try result.get()
        }
        throw TmuxError.cancelled
    }

    private func remove(_ id: UUID) { observers.removeValue(forKey: id) }
}

// Dispatch sources are immutable after activation; cancellation is thread-safe.
private final class RunShellProcessExit: @unchecked Sendable {
    private let source: (any DispatchSourceProtocol)?
    private let ended = RunShellSignal()
    private let closed = RunShellSignal()

    init(_ process: Int) throws {
        guard process > 0, let process = Int32(exactly: process) else {
            throw TmuxError.staleServerValue
        }
        let ended = ended
        let closed = closed
        #if canImport(Darwin)
            let source = DispatchSource.makeProcessSource(
                identifier: process, eventMask: .exit, queue: .global())
            source.setCancelHandler { Task { await closed.finish(.success(())) } }
        #else
            let descriptor = libtmux_open_process(process)
            guard descriptor >= 0 else {
                if errno == ESRCH { throw TmuxError.staleServerValue }
                if errno == ENOSYS || errno == EPERM || errno == EACCES {
                    source = nil
                    Task { await closed.finish(.success(())) }
                    return
                }
                throw TmuxError.invocationFailed(
                    reason: "could not observe shell process exit (errno \(errno))")
            }
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
            source.setCancelHandler {
                _ = Glibc.close(descriptor)
                Task { await closed.finish(.success(())) }
            }
        #endif
        self.source = source
        source.setEventHandler { [weak self] in
            self?.source?.cancel()
            Task { await ended.finish(.success(())) }
        }
        source.activate()
    }

    deinit { source?.cancel() }

    func wait() async throws { try await ended.wait() }

    func close() async {
        source?.cancel()
        // Teardown must reap descriptors even when the owning task was cancelled.
        await Task { try? await closed.wait() }.value
    }
}
