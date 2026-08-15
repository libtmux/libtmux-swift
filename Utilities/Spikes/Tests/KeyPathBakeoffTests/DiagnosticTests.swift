import Dispatch
import Foundation
import SpikeSupport
import Testing

@testable import KeyPathBakeoff

#if canImport(Darwin)
    import Darwin
    import os
#elseif canImport(Glibc)
    import Glibc
    import Synchronization
#endif

private enum DiagnosticHarnessError: Error {
    case forcedProbeFailure
    case launchTimedOut
    case cleanupSignalFailedAfter(String)
    case cleanupSignalFailed
    case malformedProcessMarker
    case missingEnvironmentKey(String)
    case modulesUnavailable
    case spawnFailed(Int32)
    case unsafeProcessGroup
    case waitFailed(Int32)
}

private actor ProcessLifecycle {
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func finish(_ status: Int32) {
        guard self.status == nil else { return }
        self.status = status
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations { continuation.resume(returning: status) }
    }

    func wait() async -> Int32 {
        if let status { return status }
        return await withCheckedContinuation { waiters.append($0) }
    }

}

private enum ProcessWinner: Sendable {
    case cancellation
    case cleanup
    case completion
    case running
    case timeout
}

private enum WaitIDRecovery: Sendable {
    case failed(Int32)
    case reaped
    case wait
}

private struct LockedDiagnosticProcessState: Sendable {
    var controlFailed = false
    var processIdentifier: pid_t?
    var signalCount = 0
    var signalable = false
    var winner = ProcessWinner.running
}

private struct LockedCleanupTaskProbeState: Sendable {
    var activeCount = 0
}

private final class CleanupTaskProbe: Sendable {
    #if canImport(Darwin)
        private let state = OSAllocatedUnfairLock(
            initialState: LockedCleanupTaskProbeState()
        )
    #else
        private let state = Mutex(LockedCleanupTaskProbeState())
    #endif

    func started() {
        state.withLock { $0.activeCount += 1 }
    }

    func finished() {
        state.withLock { state in
            precondition(state.activeCount > 0)
            state.activeCount -= 1
        }
    }

    var activeCount: Int {
        state.withLock { $0.activeCount }
    }
}

private final class DiagnosticProcessState: Sendable {
    #if canImport(Darwin)
        private let state = OSAllocatedUnfairLock(
            initialState: LockedDiagnosticProcessState()
        )
    #else
        private let state = Mutex(LockedDiagnosticProcessState())
    #endif

    func install(processIdentifier: pid_t) {
        state.withLock { state in
            precondition(state.processIdentifier == nil)
            state.processIdentifier = processIdentifier
            state.signalable = true
        }
    }

    func requestCancellation() -> Bool {
        request(.cancellation, signal: SIGTERM)
    }

    func requestCleanup() -> Bool {
        request(.cleanup, signal: SIGTERM)
    }

    func requestTimeout() -> Bool {
        request(.timeout, signal: SIGTERM)
    }

    func escalate() {
        state.withLock { state in signal(SIGKILL, state: &state) }
    }

    func observeTerminal() {
        state.withLock { state in
            if case .running = state.winner { state.winner = .completion }
            signal(SIGKILL, state: &state)
            state.signalable = false
        }
    }

    func recoverFromWaitIDFailure(_ processIdentifier: pid_t) -> WaitIDRecovery {
        state.withLock { state in
            guard state.processIdentifier == processIdentifier, state.signalable else {
                return .failed(ECHILD)
            }
            var waitStatus: Int32 = 0
            var result: pid_t
            repeat {
                errno = 0
                result = waitpid(processIdentifier, &waitStatus, WNOHANG)
            } while result < 0 && errno == EINTR
            let waitError = errno
            if case .running = state.winner { state.winner = .completion }
            if result == processIdentifier {
                state.signalable = false
                return .reaped
            }
            if result < 0 {
                state.signalable = false
                return .failed(waitError)
            }
            signal(SIGKILL, state: &state)
            state.signalable = false
            return .wait
        }
    }

    var controlFailed: Bool {
        state.withLock { $0.controlFailed }
    }

    var signalCount: Int {
        state.withLock { $0.signalCount }
    }

    func outcome(for status: Int32) -> ExitRace {
        state.withLock { state in
            switch state.winner {
            case .cancellation: .cancelled(status)
            case .cleanup, .completion, .running: .completed(status)
            case .timeout: .timedOut(status)
            }
        }
    }

    private func request(_ winner: ProcessWinner, signal: Int32) -> Bool {
        state.withLock { state in
            guard case .running = state.winner else { return false }
            state.winner = winner
            self.signal(signal, state: &state)
            return true
        }
    }

    private func signal(_ signal: Int32, state: inout LockedDiagnosticProcessState) {
        guard state.signalable, let processIdentifier = state.processIdentifier else { return }
        errno = 0
        let result = kill(-processIdentifier, signal)
        let signalError = errno
        state.signalCount += 1
        if result != 0 && signalError != ESRCH { state.controlFailed = true }
    }
}

private struct LockedProcessOwnerState: Sendable {
    var cleanup: Task<CleanupResult, Never>?
}

private final class ProcessOwner: Sendable {
    private let lifecycle: ProcessLifecycle
    private let processState: DiagnosticProcessState
    private let cleanupTaskProbe: CleanupTaskProbe?
    #if canImport(Darwin)
        private let state = OSAllocatedUnfairLock(
            initialState: LockedProcessOwnerState()
        )
    #else
        private let state = Mutex(LockedProcessOwnerState())
    #endif

    init(
        lifecycle: ProcessLifecycle,
        processState: DiagnosticProcessState,
        cleanupTaskProbe: CleanupTaskProbe?
    ) {
        self.lifecycle = lifecycle
        self.processState = processState
        self.cleanupTaskProbe = cleanupTaskProbe
    }

    func startCleanup() -> Task<CleanupResult, Never> {
        let lifecycle = lifecycle
        let processState = processState
        let cleanupTaskProbe = cleanupTaskProbe
        return state.withLock { state in
            if let cleanup = state.cleanup { return cleanup }
            cleanupTaskProbe?.started()
            let cleanup = Task.detached { () -> CleanupResult in
                defer { cleanupTaskProbe?.finished() }
                let status = await withTaskGroup(
                    of: CleanupRace.self,
                    returning: Int32.self
                ) { group in
                    cleanupTaskProbe?.started()
                    group.addTask {
                        defer { cleanupTaskProbe?.finished() }
                        return .terminated(await lifecycle.wait())
                    }
                    cleanupTaskProbe?.started()
                    group.addTask {
                        defer { cleanupTaskProbe?.finished() }
                        do {
                            try await Task.sleep(for: .seconds(2))
                            return .deadline
                        } catch {
                            return .cancelled
                        }
                    }
                    while let result = await group.next() {
                        switch result {
                        case let .terminated(status):
                            group.cancelAll()
                            return status
                        case .deadline:
                            processState.escalate()
                        case .cancelled:
                            continue
                        }
                    }
                    return await lifecycle.wait()
                }
                return CleanupResult(
                    status: status,
                    controlFailed: processState.controlFailed
                )
            }
            state.cleanup = cleanup
            return cleanup
        }
    }

    func stopAndWait() async -> CleanupResult {
        await startCleanup().value
    }
}

private struct CleanupResult: Sendable {
    let status: Int32
    let controlFailed: Bool
}

private enum CleanupRace: Sendable {
    case terminated(Int32)
    case deadline
    case cancelled
}

private struct SpawnedDiagnosticProcess: Sendable {
    let processIdentifier: pid_t
}

private struct ProcessResult: Sendable {
    let status: Int32
    let output: String
}

struct BoundedSignalCase: Sendable {
    let signal: Int32
    let status: Int32
}

private let boundedSignalCases = [
    BoundedSignalCase(signal: SIGHUP, status: 129),
    BoundedSignalCase(signal: SIGINT, status: 130),
    BoundedSignalCase(signal: SIGTERM, status: 143),
]

private actor ProcessIdentifiers {
    private var values: [pid_t] = []

    func store(_ values: [pid_t]) {
        self.values = values
    }

    func load() -> [pid_t] {
        values
    }
}

private enum ExitRace: Sendable {
    case cancelled(Int32)
    case completed(Int32)
    case timedOut(Int32)
}

private enum LaunchOutcome: Equatable, Sendable {
    case cancelled
    case completed
    case deadline
    case failed(String)
}

private actor CompletionCheckpoint {
    private let parked = AsyncGate()
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await parked.open()
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilParked() async throws {
        try await parked.wait()
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private actor SpawnedProcessRecorder {
    private let recorded = AsyncGate()
    private var processIdentifier: pid_t?
    private var processState: DiagnosticProcessState?

    func store(_ processIdentifier: pid_t, state: DiagnosticProcessState) async {
        self.processIdentifier = processIdentifier
        self.processState = state
        await recorded.open()
    }

    func wait() async throws -> (pid_t, DiagnosticProcessState) {
        try await recorded.wait()
        guard let processIdentifier, let processState else {
            throw DiagnosticHarnessError.unsafeProcessGroup
        }
        return (processIdentifier, processState)
    }
}

private struct ReaperObservationState: Sendable {
    var isObserved = false
    var nextWaiterIdentifier = 0
    var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
}

private final class ReaperBarrier: Sendable {
    #if canImport(Darwin)
        private let observation = OSAllocatedUnfairLock(
            initialState: ReaperObservationState()
        )
    #else
        private let observation = Mutex(ReaperObservationState())
    #endif
    private let release = DispatchSemaphore(value: 0)

    func block() {
        let waiters = observation.withLock { state in
            state.isObserved = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        release.wait()
    }

    func waitUntilBlocked() async throws {
        let observed = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await self.waitForObservation()
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        guard observed else { throw DiagnosticHarnessError.launchTimedOut }
    }

    func open() {
        release.signal()
    }

    private func waitForObservation() async throws {
        let waiterIdentifier = observation.withLock { state in
            defer { state.nextWaiterIdentifier += 1 }
            return state.nextWaiterIdentifier
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                let resumeImmediately = observation.withLock { state in
                    if state.isObserved || Task.isCancelled { return true }
                    state.waiters[waiterIdentifier] = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
            try Task.checkCancellation()
        } onCancel: {
            let continuation = observation.withLock { state in
                state.waiters.removeValue(forKey: waiterIdentifier)
            }
            continuation?.resume()
        }
    }
}

@Suite("compile diagnostics", .serialized)
struct DiagnosticTests {
    @Test("diagnostic subprocess receives only explicit environment keys")
    func diagnosticProcessReceivesOnlyExplicitEnvironmentKeys() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-environment")
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await runProcess(
            arguments: ["/usr/bin/env"],
            currentDirectory: directory,
            timeout: .seconds(5)
        )
        #expect(result.status == 0)

        let lines = result.output.split(separator: "\n")
        var observed = Set<String>()
        var malformedEntry = false
        var pathIsNonempty = false
        var localeIsC = false
        var temporaryDirectoryMatches = false
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else {
                malformedEntry = true
                continue
            }
            let key = String(line[..<separator])
            let value = line[line.index(after: separator)...]
            observed.insert(key)
            switch key {
            case "PATH": pathIsNonempty = !value.isEmpty
            case "LC_ALL": localeIsC = value == "C"
            case "TMPDIR": temporaryDirectoryMatches = value == directory.path
            default: break
            }
        }
        #expect(!malformedEntry, "environment output contained a malformed entry")

        let shellCreated: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]
        let inherited = observed.subtracting(shellCreated)
        let required: Set<String> = ["PATH", "LC_ALL", "TMPDIR"]
        let optionalNames = ["DEVELOPER_DIR", "SDKROOT"]
        let parentEnvironment = ProcessInfo.processInfo.environment
        let presentOptional = Set(
            optionalNames.filter {
                parentEnvironment[$0] != nil
            })
        let expected = required.union(presentOptional)
        let missing = expected.subtracting(inherited).sorted()
        let unexpected = inherited.subtracting(expected).sorted()

        #expect(missing.isEmpty, "missing environment keys: \(missing)")
        #expect(unexpected.isEmpty, "unexpected environment keys: \(unexpected)")
        #expect(pathIsNonempty, "PATH was empty")
        #expect(localeIsC, "LC_ALL was not C")
        #expect(temporaryDirectoryMatches, "TMPDIR did not match the task directory")
    }

    @Test("probe release is bounded when its FIFO has no reader")
    func probeReleaseWithoutReaderIsBounded() async throws {
        let directory = try makeTemporaryDirectory(named: "probe-release")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "release.fifo")
        try makeProbeFIFO(at: fifo)

        let writer = Task {
            do {
                try await writeProbeRelease(to: fifo, timeout: .milliseconds(50))
                return false
            } catch DiagnosticHarnessError.launchTimedOut {
                return true
            } catch {
                return false
            }
        }
        var readerDescriptor: Int32 = -1
        defer {
            if readerDescriptor >= 0 { _ = close(readerDescriptor) }
        }
        let completedBeforeDeadline = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await writer.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(500))
                return false
            }
            let completed = await group.next() ?? false
            if !completed {
                readerDescriptor = open(fifo.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                #expect(readerDescriptor >= 0)
                _ = await writer.value
            }
            group.cancelAll()
            return completed
        }

        #expect(completedBeforeDeadline, "probe release blocked without a FIFO reader")
        #expect(await writer.value, "probe release did not report its missing reader")
    }

    @Test(
        "probe release survives a reader closing after open without changing signal state",
        arguments: [false, true]
    )
    func probeReleaseWritePreservesPendingSIGPIPE(
        _ startsWithPendingSIGPIPE: Bool
    ) async throws {
        let directory = try makeTemporaryDirectory(named: "probe-release-sigpipe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "release.fifo")
        let opened = directory.appending(path: "opened.fifo")
        let continuation = directory.appending(path: "continuation.fifo")
        try makeProbeFIFO(at: fifo)
        try makeProbeFIFO(at: opened)
        try makeProbeFIFO(at: continuation)
        let dataReader = try OwnedDiagnosticDescriptor(
            opening: fifo.path,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC
        )
        let openedReader = try OwnedDiagnosticDescriptor(
            opening: opened.path,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC
        )
        defer {
            dataReader.close()
            openedReader.close()
        }

        let result = try await runProcess(
            arguments: [
                try authenticatedSigpipeProbePath(),
                "fifo-post-open",
                fifo.path,
                opened.path,
                continuation.path,
                startsWithPendingSIGPIPE ? "1" : "0",
            ],
            currentDirectory: directory,
            timeout: .seconds(5),
            onReady: {
                try await waitForProbeByte(from: openedReader.descriptor)
                dataReader.close()
                let continuationWriter = try await openProbeFIFOWriter(
                    at: continuation
                )
                defer { _ = close(continuationWriter) }
                var byte = UInt8(ascii: "\n")
                let writeError = writeProbeByteWithoutSIGPIPE(
                    continuationWriter,
                    byte: &byte
                )
                guard writeError == 0 else {
                    throw DiagnosticHarnessError.spawnFailed(writeError)
                }
            }
        )
        #expect(result.status == 0)
        let pending = startsWithPendingSIGPIPE ? 1 : 0
        #expect(
            result.output == "result=EPIPE pending_before=\(pending) "
                + "pending_after=\(pending) sigpipe_mask_before=1 "
                + "sigpipe_mask_after=1 sentinel_mask_before=1 "
                + "sentinel_mask_after=1\n"
        )
    }

    @Test("probe FIFO descriptor ownership closes on failed setup unwind")
    func probeFIFODescriptorOwnershipClosesOnUnwind() throws {
        let directory = try makeTemporaryDirectory(named: "probe-release-open-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appending(path: "release.fifo")
        try makeProbeFIFO(at: fifo)
        var descriptor: Int32 = -1

        do {
            let first = try OwnedDiagnosticDescriptor(
                opening: fifo.path,
                flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC
            )
            descriptor = first.descriptor
            _ = try OwnedDiagnosticDescriptor(
                opening: directory.appending(path: "missing.fifo").path,
                flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC
            )
            Issue.record("the missing second FIFO unexpectedly opened")
        } catch DiagnosticHarnessError.spawnFailed(ENOENT) {
        }

        #expect(descriptor >= 0)
        errno = 0
        #expect(fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test("diagnostic checks are bounded and cwd independent")
    func diagnosticScript() async throws {
        let spikesDirectory = taskSpikesDirectory
        let script = spikesDirectory.appending(path: "Scripts/test-diagnostics.sh")
        let modules = try discoverModulesDirectory()
        let temporaryDirectory = try makeTemporaryDirectory(named: "diagnostics")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let result = try await runProcess(
            arguments: ["bash", script.path, "--modules", modules.path],
            currentDirectory: temporaryDirectory,
            timeout: .seconds(180)
        )
        #expect(result.status == 0)
        #expect(result.output.contains("key-path diagnostics: passed"))
        #expect(
            result.output.contains(
                "SHELL_SUPERVISOR stopped-auth=passed payload-exit-cleanup=passed"
            )
        )
        let neutralMarkers = result.output.split(separator: "\n").filter {
            $0.hasPrefix("NEUTRAL_PROBE ")
        }
        #expect(neutralMarkers.count == 1)
        if let marker = neutralMarkers.first {
            #expect(
                marker == "NEUTRAL_PROBE status=0 outcome=accepted"
                    || marker == "NEUTRAL_PROBE status=1 outcome=rejected"
            )
        }
        #expect(!result.output.contains(spikesDirectory.path))
        #expect(!result.output.contains(temporaryDirectory.path))
        #expect(!result.output.contains(modules.path))
    }

    @Test("generator check rejects missing and stale isolated output")
    func generatorNegativeControls() async throws {
        let spikesDirectory = taskSpikesDirectory
        let checkoutGenerator = spikesDirectory.appending(
            path: "Scripts/generate-key-path-switch.swift"
        )
        let checkoutGenerated = spikesDirectory.appending(
            path: "Sources/KeyPathBakeoff/GeneratedSwitch.swift"
        )
        let mirror = try makeTemporaryDirectory(named: "generator")
        defer { try? FileManager.default.removeItem(at: mirror) }
        let scripts = mirror.appending(path: "Scripts")
        let sources = mirror.appending(path: "Sources/KeyPathBakeoff")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let generator = scripts.appending(path: "generate-key-path-switch.swift")
        let generated = sources.appending(path: "GeneratedSwitch.swift")
        try FileManager.default.copyItem(at: checkoutGenerator, to: generator)

        #expect(try await runGenerator(generator, "--check", in: mirror).status == 1)
        #expect(!FileManager.default.fileExists(atPath: generated.path))
        #expect(try await runGenerator(generator, "--write", in: mirror).status == 0)
        let firstWrite = try Data(contentsOf: generated)
        #expect(try await runGenerator(generator, "--write", in: mirror).status == 0)
        #expect(try Data(contentsOf: generated) == firstWrite)

        let staleBytes = Data("stale\n".utf8)
        try staleBytes.write(to: generated)
        #expect(try await runGenerator(generator, "--check", in: mirror).status == 1)
        #expect(try Data(contentsOf: generated) == staleBytes)
        #expect(try await runGenerator(generator, "--write", in: mirror).status == 0)
        #expect(try await runGenerator(generator, "--check", in: mirror).status == 0)
        let checkoutBytes = try Data(contentsOf: checkoutGenerated)
        #expect(try Data(contentsOf: generated) == checkoutBytes)
    }

    @Test("timed out direct process group reaps leader and descendant")
    func processGroupTimeoutCleanup() async throws {
        let directory = try makeTemporaryDirectory(named: "process-group")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appending(path: "fixture.sh")
        let marker = directory.appending(path: "owned-processes")
        let script = #"""
            marker=$1
            fifo="$marker.fifo"
            mkfifo "$fifo"
            trap '' TERM
            bash -c 'trap "" TERM; read -r _ < "$1"' "$marker" "$fifo" &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" >"$marker.pending"
            mv "$marker.pending" "$marker"
            wait "$descendant"
            """#
        try Data(script.utf8).write(to: fixture)
        let identifiers = ProcessIdentifiers()
        let hostGroup = getpgrp()

        do {
            _ = try await runProcess(
                arguments: ["bash", fixture.path, marker.path],
                currentDirectory: directory,
                timeout: .milliseconds(100),
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                },
                onReady: {
                    let values = try await waitForProcessMarker(marker)
                    let leader = await identifiers.load()[0]
                    await identifiers.store(values)
                    guard values.count == 2,
                        values.allSatisfy({ $0 > 0 }),
                        values[0] == leader,
                        values[0] != values[1],
                        leader != hostGroup,
                        getpgid(leader) == leader,
                        getpgid(values[1]) == leader
                    else {
                        throw DiagnosticHarnessError.unsafeProcessGroup
                    }
                }
            )
            Issue.record("the blocking fixture did not time out")
        } catch DiagnosticHarnessError.launchTimedOut {
        } catch {
            throw error
        }

        let owned = await identifiers.load()
        try await waitForProcessAbsence(owned)
    }

    @Test("prompt timeout joins every cleanup racer before returning")
    func promptTimeoutJoinsCleanupRacers() async throws {
        let directory = try makeTemporaryDirectory(named: "prompt-timeout-cleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cleanupTasks = CleanupTaskProbe()
        let identifiers = ProcessIdentifiers()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await runProcess(
                arguments: ["/bin/sleep", "30"],
                currentDirectory: directory,
                timeout: .milliseconds(20),
                cleanupTaskProbe: cleanupTasks,
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                }
            )
            Issue.record("the prompt timeout fixture did not time out")
        } catch DiagnosticHarnessError.launchTimedOut {
        }

        #expect(clock.now - started < .seconds(1))
        let activeCleanupTasks = cleanupTasks.activeCount
        #expect(activeCleanupTasks == 0)
        if activeCleanupTasks != 0 {
            try await waitForCleanupTaskAbsence(cleanupTasks)
        }
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("cancellation immediately after spawn reaps the direct group")
    func immediatePostSpawnCancellationCleanup() async throws {
        let directory = try makeTemporaryDirectory(named: "post-spawn")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = CompletionCheckpoint()
        let cleanupTasks = CleanupTaskProbe()
        let identifiers = ProcessIdentifiers()
        let fifo = directory.appending(path: "input.fifo")
        try makeProbeFIFO(at: fifo)
        let launch = Task {
            try await runProcess(
                arguments: [
                    "bash", "-c", "read -r _ < \"$1\"", "bash", fifo.path,
                ],
                currentDirectory: directory,
                timeout: .seconds(30),
                cleanupTaskProbe: cleanupTasks,
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                    await checkpoint.wait()
                }
            )
        }
        try await checkpoint.waitUntilParked()
        let owned = await identifiers.load()
        guard owned.count == 1, getpgid(owned[0]) == owned[0] else {
            launch.cancel()
            await checkpoint.open()
            _ = await awaitLaunchOutcome(launch)
            throw DiagnosticHarnessError.unsafeProcessGroup
        }
        launch.cancel()
        do {
            try await waitForProcessAbsence(owned)
        } catch {
            await checkpoint.open()
            _ = await awaitLaunchOutcome(launch)
            throw error
        }
        await checkpoint.open()
        let outcome = await awaitLaunchOutcome(launch)
        #expect(outcome == .cancelled)
        let activeCleanupTasks = cleanupTasks.activeCount
        #expect(activeCleanupTasks == 0)
        if activeCleanupTasks != 0 {
            try await waitForCleanupTaskAbsence(cleanupTasks)
        }
    }

    @Test("completion while a post-spawn hook is parked wins later cancellation")
    func postSpawnHookCompletionWinsCancellation() async throws {
        let directory = try makeTemporaryDirectory(named: "post-spawn-completion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = CompletionCheckpoint()
        let terminal = ReaperBarrier()
        let recorder = SpawnedProcessRecorder()
        let launch = Task {
            try await runProcess(
                arguments: ["bash", "-c", "exit 0"],
                currentDirectory: directory,
                timeout: .seconds(5),
                afterSpawn: { processIdentifier, state in
                    await recorder.store(processIdentifier, state: state)
                    await hook.wait()
                },
                afterTerminalObservation: { terminal.block() }
            )
        }

        do {
            try await hook.waitUntilParked()
            try await terminal.waitUntilBlocked()
            let (processIdentifier, processState) = try await recorder.wait()
            let signalsBeforeCancellation = processState.signalCount
            #expect(signalsBeforeCancellation > 0)
            launch.cancel()
            await Task.yield()
            #expect(processState.signalCount == signalsBeforeCancellation)
            terminal.open()
            try await waitForProcessAbsence([processIdentifier])
            #expect(processState.signalCount == signalsBeforeCancellation)
            await hook.open()
            let result = try await launch.value
            #expect(result.status == 0)
        } catch {
            terminal.open()
            await hook.open()
            _ = await awaitLaunchOutcome(launch)
            throw error
        }
    }

    @Test("caller cancellation does not mask a concrete post-spawn hook error")
    func postSpawnHookErrorWinsAmbientCancellation() async throws {
        let directory = try makeTemporaryDirectory(named: "post-spawn-error")
        defer { try? FileManager.default.removeItem(at: directory) }
        let hook = CompletionCheckpoint()
        let identifiers = ProcessIdentifiers()
        let fifo = directory.appending(path: "input.fifo")
        try makeProbeFIFO(at: fifo)
        let launch = Task {
            try await runProcess(
                arguments: [
                    "bash", "-c", "read -r _ < \"$1\"", "bash", fifo.path,
                ],
                currentDirectory: directory,
                timeout: .seconds(30),
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                    await hook.wait()
                    throw DiagnosticHarnessError.forcedProbeFailure
                }
            )
        }

        try await hook.waitUntilParked()
        let owned = await identifiers.load()
        guard owned.count == 1, getpgid(owned[0]) == owned[0] else {
            launch.cancel()
            await hook.open()
            _ = await awaitLaunchOutcome(launch)
            throw DiagnosticHarnessError.unsafeProcessGroup
        }
        launch.cancel()
        do {
            try await waitForProcessAbsence(owned)
        } catch {
            await hook.open()
            _ = await awaitLaunchOutcome(launch)
            throw error
        }
        await hook.open()
        do {
            _ = try await launch.value
            Issue.record("caller cancellation masked the post-spawn hook error")
        } catch DiagnosticHarnessError.forcedProbeFailure {
        } catch {
            throw error
        }
    }

    @Test("leader exit kills a same-group descendant before completion")
    func leaderExitKillsDescendant() async throws {
        let directory = try makeTemporaryDirectory(named: "leader-exit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appending(path: "fixture.sh")
        let marker = directory.appending(path: "owned-processes")
        let script = #"""
            marker=$1
            mkfifo "$marker.fifo"
            mkfifo "$marker.release"
            bash -c 'trap "" TERM; read -r _ < "$1"' "$marker" "$marker.fifo" &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" >"$marker.pending"
            mv "$marker.pending" "$marker"
            read -r _ < "$marker.release"
            exit 0
            """#
        try Data(script.utf8).write(to: fixture)
        let identifiers = ProcessIdentifiers()
        let result = try await runProcess(
            arguments: ["bash", fixture.path, marker.path],
            currentDirectory: directory,
            timeout: .seconds(5),
            afterSpawn: { processIdentifier, _ in
                await identifiers.store([processIdentifier])
            },
            onReady: {
                let values = try await waitForProcessMarker(marker)
                let leader = await identifiers.load()[0]
                guard values[0] == leader,
                    values[0] != values[1],
                    getpgid(values[1]) == leader
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store(values)
                try await writeProbeRelease(
                    to: URL(fileURLWithPath: marker.path + ".release")
                )
            }
        )
        #expect(result.status == 0)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("a throwing readiness hook still reaps the direct group")
    func readinessFailureCleanup() async throws {
        let directory = try makeTemporaryDirectory(named: "readiness-error")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "owned-processes")
        let identifiers = ProcessIdentifiers()
        do {
            _ = try await runProcess(
                arguments: [
                    "bash", "-c",
                    "marker=$1; mkfifo \"$marker.fifo\"; "
                        + "printf '%s\\n' $$ > \"$marker.pending\"; "
                        + "mv \"$marker.pending\" \"$marker\"; "
                        + "read -r _ < \"$marker.fifo\"",
                    "bash",
                    marker.path,
                ],
                currentDirectory: directory,
                timeout: .seconds(5),
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                },
                onReady: {
                    _ = try await waitForProcessMarker(marker, expectedCount: 1)
                    throw DiagnosticHarnessError.forcedProbeFailure
                }
            )
            Issue.record("the readiness hook did not fail")
        } catch DiagnosticHarnessError.forcedProbeFailure {
        }
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("outer termination lets the shell reap its nested private group")
    func nestedShellTerminationCleanup() async throws {
        let directory = try makeTemporaryDirectory(named: "nested-shell")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "nested-processes")
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")
        let identifiers = ProcessIdentifiers()
        do {
            _ = try await runProcess(
                arguments: ["bash", script.path, "--supervisor-probe", marker.path],
                currentDirectory: directory,
                timeout: .milliseconds(100),
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                },
                onReady: {
                    let supervisor = try await waitForProcessMarker(
                        marker.appendingPathExtension("supervisor")
                    )
                    let payload = try await waitForProcessMarker(
                        marker.appendingPathExtension("payload")
                    )
                    let outer = await identifiers.load()[0]
                    let owned = [outer, supervisor[1], payload[0], payload[1]]
                    guard supervisor[0] == outer,
                        Set(owned).count == 4,
                        getpgid(outer) == outer,
                        getpgid(supervisor[1]) == supervisor[1],
                        getpgid(payload[0]) == supervisor[1],
                        getpgid(payload[1]) == supervisor[1]
                    else { throw DiagnosticHarnessError.unsafeProcessGroup }
                    await identifiers.store(owned)
                }
            )
            Issue.record("the nested shell probe did not time out")
        } catch DiagnosticHarnessError.launchTimedOut {
        }
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("bounded shell runner preserves payload status and output")
    func boundedShellRunnerPreservesPayloadStatusAndOutput() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-status")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        try Data().write(to: output)

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "5",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "bash", "-c", "printf 'bounded-output\\n'; exit 23",
            ],
            currentDirectory: directory,
            timeout: .seconds(10)
        )

        #expect(result.status == 23)
        #expect(try String(contentsOf: output, encoding: .utf8) == "bounded-output\n")
    }

    @Test("bounded shell runner authenticates pre-handshake cleanup through its job")
    func boundedShellRunnerAuthenticatesPreHandshakeCleanupThroughJob() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-preauth-job")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let path = try makeHandshakeRejectingPath(in: directory)
        let bashEnvironment = try makeBash3CompatibilityEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "PATH=\(path)", "BASH_ENV=\(bashEnvironment.path)",
                #"PS4=TRACE:${BASHPID:-$$}:${FUNCNAME[0]:-main}: "#,
                "bash", "-x", wrapper.path,
                "--bounded", "--timeout", "30",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "/bin/sleep", "30",
            ],
            currentDirectory: directory,
            timeout: .seconds(15)
        )

        #expect(result.status == 125)
        try requireOwnedJobCleanupTrace(result.output, childVariable: "child")
    }

    @Test(
        "bounded shell runner defers signals until its launched job is captured",
        arguments: boundedSignalCases
    )
    func boundedShellRunnerDefersSignalsUntilJobCapture(
        _ signalCase: BoundedSignalCase
    ) async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-launch-signal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let payloadMarker = directory.appending(path: "payload-started")
        let childMarker = directory.appending(path: "launched-child")
        let bashEnvironment = try makeLaunchSignalBashEnvironment(in: directory)
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")

        let result = try await runProcess(
            arguments: [
                "env",
                "BASH_ENV=\(bashEnvironment.path)",
                "LIBTMUX_TEST_LAUNCH_ASSIGNMENT=child=$!",
                "LIBTMUX_TEST_LAUNCH_MARKER=\(childMarker.path)",
                "LIBTMUX_TEST_LAUNCH_SIGNAL=\(signalCase.signal)",
                "bash", wrapper.path,
                "--bounded", "--timeout", "30",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "bash", "-c", "printf started >\"$1\"", "bash", payloadMarker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10)
        )

        #expect(result.status == signalCase.status)
        #expect(!FileManager.default.fileExists(atPath: payloadMarker.path))
        let launched = try await waitForProcessMarker(childMarker, expectedCount: 1)
        let survived = processExists(launched[0])
        #expect(!survived, "the pre-capture supervisor survived shell termination")
        if survived {
            try terminateTestProcessGroup(launched[0])
            try await waitForProcessAbsence(launched)
        }
    }

    @Test("bounded shell runner retires its launched job without touching a current decoy")
    func boundedShellRunnerRetiresCurrentJobAfterCaptureFailure() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-capture-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let childMarker = directory.appending(path: "launched-child")
        let bashEnvironment = try makeCaptureFailureBashEnvironment(in: directory)
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")

        do {
            let result = try await runProcess(
                arguments: [
                    "env",
                    "BASH_ENV=\(bashEnvironment.path)",
                    "LIBTMUX_TEST_LAUNCH_ASSIGNMENT=child=$!",
                    "LIBTMUX_TEST_LAUNCH_MARKER=\(childMarker.path)",
                    "bash", wrapper.path,
                    "--bounded", "--timeout", "30",
                    "--output", output.path,
                    "--cwd", directory.path,
                    "--",
                    "/bin/sleep", "30",
                ],
                currentDirectory: directory,
                timeout: .seconds(3)
            )
            #expect(result.status == 125)
            try await requireCompetingJobRetirement(marker: childMarker)
        } catch {
            if FileManager.default.fileExists(atPath: childMarker.path) {
                try await tearDownCaptureFailureJobs(marker: childMarker)
            }
            throw error
        }
    }

    @Test("diagnostic shell authenticates pre-handshake cleanup through its job")
    func diagnosticShellAuthenticatesPreHandshakeCleanupThroughJob() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-preauth-job")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "supervisor-probe")
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")
        let path = try makeHandshakeRejectingPath(in: directory)
        let bashEnvironment = try makeBash3CompatibilityEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "PATH=\(path)", "BASH_ENV=\(bashEnvironment.path)",
                #"PS4=TRACE:${BASHPID:-$$}:${FUNCNAME[0]:-main}: "#,
                "bash", "-x", script.path,
                "--supervisor-probe", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(15)
        )

        #expect(result.status == 125)
        try requireOwnedJobCleanupTrace(result.output, childVariable: "active_child")
    }

    @Test("diagnostic shell defers termination until its launched job is captured")
    func diagnosticShellDefersTerminationUntilJobCapture() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-launch-signal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "supervisor-probe")
        let childMarker = directory.appending(path: "launched-child")
        let bashEnvironment = try makeLaunchSignalBashEnvironment(in: directory)
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")

        let result = try await runProcess(
            arguments: [
                "env",
                "BASH_ENV=\(bashEnvironment.path)",
                "LIBTMUX_TEST_LAUNCH_ASSIGNMENT=active_child=$!",
                "LIBTMUX_TEST_LAUNCH_MARKER=\(childMarker.path)",
                "LIBTMUX_TEST_LAUNCH_SIGNAL=\(SIGTERM)",
                "bash", script.path,
                "--supervisor-probe", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10)
        )

        #expect(result.status == 130)
        #expect(!FileManager.default.fileExists(atPath: marker.path + ".payload"))
        let launched = try await waitForProcessMarker(childMarker, expectedCount: 1)
        let survived = processExists(launched[0])
        #expect(!survived, "the diagnostic pre-capture supervisor survived termination")
        if survived {
            try terminateTestProcessGroup(launched[0])
            try await waitForProcessAbsence(launched)
        }
    }

    @Test("diagnostic shell retires its launched job without touching a current decoy")
    func diagnosticShellRetiresCurrentJobAfterCaptureFailure() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-capture-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "supervisor-probe")
        let childMarker = directory.appending(path: "launched-child")
        let bashEnvironment = try makeCaptureFailureBashEnvironment(in: directory)
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")

        do {
            let result = try await runProcess(
                arguments: [
                    "env",
                    "BASH_ENV=\(bashEnvironment.path)",
                    "LIBTMUX_TEST_LAUNCH_ASSIGNMENT=active_child=$!",
                    "LIBTMUX_TEST_LAUNCH_MARKER=\(childMarker.path)",
                    "bash", script.path,
                    "--supervisor-probe", marker.path,
                ],
                currentDirectory: directory,
                timeout: .seconds(3)
            )
            #expect(result.status == 125)
            try await requireCompetingJobRetirement(marker: childMarker)
        } catch {
            if FileManager.default.fileExists(atPath: childMarker.path) {
                try await tearDownCaptureFailureJobs(marker: childMarker)
            }
            throw error
        }
    }

    @Test("diagnostic shell reaps its stubborn supervisor through its job")
    func diagnosticShellReapsStubbornSupervisorThroughJob() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-owned-job")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "supervisor-probe")
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")
        let identifiers = ProcessIdentifiers()
        let bashEnvironment = try makeBash3CompatibilityEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "BASH_ENV=\(bashEnvironment.path)",
                #"PS4=TRACE:${BASHPID:-$$}:${FUNCNAME[0]:-main}: "#,
                "bash", "-x", script.path,
                "--supervisor-probe", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            afterSpawn: { processIdentifier, _ in
                await identifiers.store([processIdentifier])
            },
            onReady: {
                let recorded = await identifiers.load()
                let outer = try #require(recorded.first)
                let supervisor = try await waitForProcessMarker(
                    marker.appendingPathExtension("supervisor")
                )
                let payload = try await waitForProcessMarker(
                    marker.appendingPathExtension("payload")
                )
                let owned = [outer, supervisor[1], payload[0], payload[1]]
                guard supervisor[0] == outer,
                    Set(owned).count == 4,
                    getpgid(outer) == outer,
                    getpgid(supervisor[1]) == supervisor[1],
                    getpgid(payload[0]) == supervisor[1],
                    getpgid(payload[1]) == supervisor[1]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store(owned)
                try await writeProbeRelease(
                    to: marker.appendingPathExtension("descendant-release")
                )
                try await writeProbeRelease(
                    to: marker.appendingPathExtension("payload-release")
                )
            }
        )

        #expect(result.status == 0)
        try requireOwnedJobCleanupTrace(result.output, childVariable: "active_child")
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("diagnostic shell treats wait status 127 as cleanup failure")
    func diagnosticShellTreatsWait127AsCleanupFailure() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-wait-127")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "supervisor-probe")
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")
        let identifiers = ProcessIdentifiers()
        let bashEnvironment = try makeWait127BashEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "BASH_ENV=\(bashEnvironment.path)",
                "bash", script.path,
                "--supervisor-probe", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            afterSpawn: { processIdentifier, _ in
                await identifiers.store([processIdentifier])
            },
            onReady: {
                let recorded = await identifiers.load()
                let outer = try #require(recorded.first)
                let supervisor = try await waitForProcessMarker(
                    marker.appendingPathExtension("supervisor")
                )
                let payload = try await waitForProcessMarker(
                    marker.appendingPathExtension("payload")
                )
                let owned = [outer, supervisor[1], payload[0], payload[1]]
                guard supervisor[0] == outer,
                    Set(owned).count == 4,
                    getpgid(outer) == outer,
                    getpgid(supervisor[1]) == supervisor[1],
                    getpgid(payload[0]) == supervisor[1],
                    getpgid(payload[1]) == supervisor[1]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store(owned)
                try await writeProbeRelease(
                    to: marker.appendingPathExtension("descendant-release")
                )
                try await writeProbeRelease(
                    to: marker.appendingPathExtension("payload-release")
                )
            }
        )

        #expect(result.status == 125)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("diagnostic shell reports a wait failure during signal cleanup")
    func diagnosticShellReportsSignalCleanupWaitFailure() async throws {
        let directory = try makeTemporaryDirectory(named: "diagnostic-signal-wait-127")
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "supervisor-probe")
        let script = taskSpikesDirectory.appending(path: "Scripts/test-diagnostics.sh")
        let identifiers = ProcessIdentifiers()
        let bashEnvironment = try makeWait127BashEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "BASH_ENV=\(bashEnvironment.path)",
                "bash", script.path,
                "--supervisor-probe", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            afterSpawn: { processIdentifier, _ in
                await identifiers.store([processIdentifier])
            },
            onReady: {
                let recorded = await identifiers.load()
                let outer = try #require(recorded.first)
                let supervisor = try await waitForProcessMarker(
                    marker.appendingPathExtension("supervisor")
                )
                let payload = try await waitForProcessMarker(
                    marker.appendingPathExtension("payload")
                )
                let owned = [outer, supervisor[1], payload[0], payload[1]]
                guard supervisor[0] == outer,
                    Set(owned).count == 4,
                    getpgid(outer) == outer,
                    getpgid(supervisor[1]) == supervisor[1],
                    getpgid(payload[0]) == supervisor[1],
                    getpgid(payload[1]) == supervisor[1]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store(owned)
                guard kill(-outer, SIGTERM) == 0 else {
                    throw DiagnosticHarnessError.spawnFailed(errno)
                }
            }
        )

        #expect(result.status == 125)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("bounded shell runner never signals a retired process-group number")
    func boundedShellRunnerNeverSignalsRetiredProcessGroupNumber() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-retired-job")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let gate = directory.appending(path: "before-release")
        let ready = gate.appendingPathExtension("ready")
        let retired = directory.appending(path: "retired")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let identifiers = ProcessIdentifiers()
        try makeProbeFIFO(at: gate)
        let bashEnvironment = try makeRetiredJobCacheBashEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "BASH_ENV=\(bashEnvironment.path)",
                "LIBTMUX_TEST_RETIRED_JOB=\(retired.path)",
                #"PS4=TRACE:${BASHPID:-$$}:${FUNCNAME[0]:-main}: "#,
                "bash", "-x", wrapper.path,
                "--bounded", "--timeout", "30",
                "--output", output.path,
                "--cwd", directory.path,
                "--before-release-gate", gate.path,
                "--",
                "/usr/bin/true",
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            onReady: {
                let owner = try await waitForProcessMarker(ready)
                guard owner[0] == owner[1],
                    owner[0] != getpgrp(),
                    getpgid(owner[0]) == owner[0]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store([owner[0]])
                guard kill(owner[0], SIGKILL) == 0 else {
                    throw DiagnosticHarnessError.spawnFailed(errno)
                }
                try await waitForProcessAbsence([owner[0]])
                try Data().write(to: retired)
                try await writeProbeRelease(to: gate)
            }
        )

        #expect(result.status == 125)
        let recorded = await identifiers.load()
        let retiredOwner = try #require(recorded.first)
        try requireNoRawSignalAfterJobRetirement(
            result.output,
            child: retiredOwner
        )
    }

    @Test(
        "bounded shell runner keeps its supervisor pinned after payload exit",
        arguments: [Int32(0), Int32(23)]
    )
    func boundedShellRunnerReapsDescendantAfterPayloadExit(_ payloadStatus: Int32) async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-descendant")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let marker = directory.appending(path: "payload-processes")
        let release = marker.appendingPathExtension("release")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let identifiers = ProcessIdentifiers()
        try makeProbeFIFO(at: release)

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "5",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "bash", "-c",
                #"marker=$1; status=$2; bash -c 'trap "" HUP TERM; while :; do sleep 1; done' & descendant=$!; group=$(ps -o pgid= -p $$ | tr -d ' '); printf '%s %s %s\n' "$$" "$descendant" "$group" >"$marker.pending"; mv "$marker.pending" "$marker"; read -r _ <"$marker.release"; exit "$status""#,
                "bash", marker.path, String(payloadStatus),
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            onReady: {
                let owned = try await waitForProcessMarker(marker, expectedCount: 3)
                guard Set(owned).count == 3,
                    owned[0] != owned[2],
                    owned[2] != getpgrp(),
                    getpgid(owned[0]) == owned[2],
                    getpgid(owned[1]) == owned[2],
                    getpgid(owned[2]) == owned[2]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store(owned)
                try await writeProbeRelease(to: release)
            }
        )

        #expect(result.status == payloadStatus)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("bounded shell runner timeout reaps a TERM-ignoring group")
    func boundedShellRunnerTimeoutReapsTermIgnoringGroup() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-timeout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let marker = directory.appending(path: "payload-processes")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let identifiers = ProcessIdentifiers()

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "10",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "bash", "-c",
                #"marker=$1; mkfifo "$marker.fifo"; trap '' TERM; bash -c 'trap "" TERM; read -r _ < "$1"' bash "$marker.fifo" & descendant=$!; group=$(ps -o pgid= -p $$ | tr -d ' '); printf '%s %s %s\n' "$$" "$descendant" "$group" >"$marker.pending"; mv "$marker.pending" "$marker"; wait "$descendant""#,
                "bash", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(20),
            onReady: {
                let owned = try await waitForProcessMarker(marker, expectedCount: 3)
                guard Set(owned).count == 3,
                    owned[2] != getpgrp(),
                    getpgid(owned[0]) == owned[2],
                    getpgid(owned[1]) == owned[2]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store(owned)
            }
        )

        #expect(result.status == 124)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("bounded shell runner atomically publishes timeout evidence")
    func boundedShellRunnerPublishesTimeoutMarker() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-timeout-marker")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let marker = directory.appending(path: "timed-out")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "1",
                "--output", output.path,
                "--cwd", directory.path,
                "--timeout-marker", marker.path,
                "--",
                "/bin/sleep", "30",
            ],
            currentDirectory: directory,
            timeout: .seconds(10)
        )

        #expect(result.status == 124)
        let values = try marker.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        #expect(values.isRegularFile == true)
        #expect(values.isSymbolicLink == false)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "timed-out\n")
    }

    @Test(
        "bounded shell runner handles signals during its stopped handshake",
        arguments: boundedSignalCases
    )
    func boundedShellRunnerHandlesTerminationDuringHandshake(
        _ signalCase: BoundedSignalCase
    ) async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-handshake")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let payloadMarker = directory.appending(path: "payload-started")
        let gate = directory.appending(path: "before-release")
        let ready = gate.appendingPathExtension("ready")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let identifiers = ProcessIdentifiers()
        try makeProbeFIFO(at: gate)

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "30",
                "--output", output.path,
                "--cwd", directory.path,
                "--before-release-gate", gate.path,
                "--",
                "bash", "-c", "printf started >\"$1\"", "bash", payloadMarker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            afterSpawn: { outer, _ in await identifiers.store([outer]) },
            onReady: {
                let recorded = await identifiers.load()
                let outer = try #require(recorded.first)
                let owned = try await waitForProcessMarker(ready)
                guard owned[0] == owned[1],
                    outer != owned[0],
                    outer != getpgrp(),
                    getpgid(outer) == outer,
                    getpgid(owned[0]) == owned[0]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store([outer, owned[0]])
                guard kill(-outer, signalCase.signal) == 0 else {
                    throw DiagnosticHarnessError.spawnFailed(errno)
                }
            }
        )

        #expect(result.status == signalCase.status)
        #expect(!FileManager.default.fileExists(atPath: payloadMarker.path))
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test(
        "bounded shell runner handles signals after status publication",
        arguments: boundedSignalCases
    )
    func boundedShellRunnerHandlesTerminationAfterStatusPublication(
        _ signalCase: BoundedSignalCase
    ) async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-status-termination")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let payloadMarker = directory.appending(path: "payload-process")
        let gate = directory.appending(path: "after-status")
        let ready = gate.appendingPathExtension("ready")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let identifiers = ProcessIdentifiers()
        try makeProbeFIFO(at: gate)

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "30",
                "--output", output.path,
                "--cwd", directory.path,
                "--after-status-gate", gate.path,
                "--",
                "bash", "-c",
                #"group=$(ps -o pgid= -p $$ | tr -d ' '); printf '%s %s\n' "$$" "$group" >"$1.pending"; mv "$1.pending" "$1"; exit 23"#,
                "bash", payloadMarker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            afterSpawn: { outer, _ in await identifiers.store([outer]) },
            onReady: {
                let recorded = await identifiers.load()
                let outer = try #require(recorded.first)
                let supervisor = try await waitForProcessMarker(ready)
                let payload = try await waitForProcessMarker(payloadMarker)
                guard supervisor[0] == supervisor[1],
                    outer != supervisor[0],
                    outer != getpgrp(),
                    payload[0] != supervisor[0],
                    payload[1] == supervisor[0],
                    getpgid(outer) == outer,
                    getpgid(supervisor[0]) == supervisor[0]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store([outer, supervisor[0], payload[0]])
                try await waitForProcessAbsence([payload[0]])
                guard kill(-outer, signalCase.signal) == 0 else {
                    throw DiagnosticHarnessError.spawnFailed(errno)
                }
            }
        )

        #expect(result.status == signalCase.status)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("bounded shell runner reaps its stubborn supervisor through its job")
    func boundedShellRunnerReapsStubbornSupervisorThroughJob() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-wait-order")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let bashEnvironment = try makeBash3CompatibilityEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "BASH_ENV=\(bashEnvironment.path)",
                #"PS4=TRACE:${BASHPID:-$$}:${FUNCNAME[0]:-main}: "#,
                "bash", "-x", wrapper.path,
                "--bounded", "--timeout", "5",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "/usr/bin/true",
            ],
            currentDirectory: directory,
            timeout: .seconds(10)
        )
        #expect(result.status == 0)
        try requireOwnedJobCleanupTrace(result.output, childVariable: "child")
    }

    @Test("bounded shell runner treats wait status 127 as cleanup failure")
    func boundedShellRunnerTreatsWait127AsCleanupFailure() async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-wait-127")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let bashEnvironment = try makeBoundedWait127BashEnvironment(in: directory)

        let result = try await runProcess(
            arguments: [
                "env", "BASH_ENV=\(bashEnvironment.path)",
                "bash", wrapper.path,
                "--bounded", "--timeout", "5",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "/usr/bin/true",
            ],
            currentDirectory: directory,
            timeout: .seconds(10)
        )

        #expect(result.status == 125)
    }

    @Test(
        "bounded shell runner handles signals during payload execution",
        arguments: boundedSignalCases
    )
    func boundedShellRunnerHandlesOuterTerminationOnce(
        _ signalCase: BoundedSignalCase
    ) async throws {
        let directory = try makeTemporaryDirectory(named: "bounded-signal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "payload.out")
        let marker = directory.appending(path: "payload-processes")
        let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
        let identifiers = ProcessIdentifiers()

        let result = try await runProcess(
            arguments: [
                "bash", wrapper.path,
                "--bounded", "--timeout", "30",
                "--output", output.path,
                "--cwd", directory.path,
                "--",
                "bash", "-c",
                #"marker=$1; mkfifo "$marker.fifo"; trap '' HUP INT TERM; bash -c 'trap "" HUP INT TERM; read -r _ < "$1"' bash "$marker.fifo" & descendant=$!; group=$(ps -o pgid= -p $$ | tr -d ' '); printf '%s %s %s\n' "$$" "$descendant" "$group" >"$marker.pending"; mv "$marker.pending" "$marker"; wait "$descendant""#,
                "bash", marker.path,
            ],
            currentDirectory: directory,
            timeout: .seconds(10),
            afterSpawn: { outer, _ in await identifiers.store([outer]) },
            onReady: {
                let recorded = await identifiers.load()
                let outer = try #require(recorded.first)
                let owned = try await waitForProcessMarker(marker, expectedCount: 3)
                guard Set(owned).count == 3,
                    outer != owned[2],
                    outer != getpgrp(),
                    owned[2] != getpgrp(),
                    getpgid(outer) == outer,
                    getpgid(owned[0]) == owned[2],
                    getpgid(owned[1]) == owned[2]
                else { throw DiagnosticHarnessError.unsafeProcessGroup }
                await identifiers.store([outer] + owned)
                guard kill(-outer, signalCase.signal) == 0 else {
                    throw DiagnosticHarnessError.spawnFailed(errno)
                }
            }
        )

        #expect(result.status == signalCase.status)
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("committed process completion wins a later caller cancellation")
    func committedCompletionWinsCancellation() async throws {
        let directory = try makeTemporaryDirectory(named: "completion-wins")
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkpoint = CompletionCheckpoint()
        let launch = Task {
            try await runProcess(
                arguments: ["bash", "-c", "exit 0"],
                currentDirectory: directory,
                timeout: .seconds(5),
                afterCompletion: { await checkpoint.wait() }
            )
        }
        try await checkpoint.waitUntilParked()
        launch.cancel()
        await checkpoint.open()
        let result = try await launch.value
        #expect(result.status == 0)
    }

    @Test("waitid failure still reaps a blocking leader and descendant")
    func waitIDFailureCleanup() async throws {
        let directory = try makeTemporaryDirectory(named: "waitid-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appending(path: "fixture.sh")
        let marker = directory.appending(path: "owned-processes")
        let script = #"""
            marker=$1
            mkfifo "$marker.fifo"
            trap '' TERM
            bash -c 'trap "" TERM; read -r _ < "$1"' "$marker" "$marker.fifo" &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" >"$marker.pending"
            mv "$marker.pending" "$marker"
            wait "$descendant"
            """#
        try Data(script.utf8).write(to: fixture)
        let barrier = ReaperBarrier()
        defer { barrier.open() }
        let identifiers = ProcessIdentifiers()

        do {
            _ = try await runProcess(
                arguments: ["bash", fixture.path, marker.path],
                currentDirectory: directory,
                timeout: .seconds(5),
                afterSpawn: { processIdentifier, _ in
                    await identifiers.store([processIdentifier])
                },
                beforeWaitID: { barrier.block() },
                forceWaitIDFailure: true,
                onReady: {
                    do {
                        try await barrier.waitUntilBlocked()
                        let values = try await waitForProcessMarker(marker)
                        let leader = await identifiers.load()[0]
                        guard values.count == 2,
                            values[0] == leader,
                            values[0] != values[1],
                            getpgid(values[1]) == leader
                        else { throw DiagnosticHarnessError.unsafeProcessGroup }
                        await identifiers.store(values)
                        barrier.open()
                    } catch {
                        barrier.open()
                        throw error
                    }
                }
            )
            Issue.record("the forced waitid failure was not reported")
        } catch DiagnosticHarnessError.waitFailed(let code) {
            #expect(code == EINVAL)
        }
        try await waitForProcessAbsence(await identifiers.load())
    }

    @Test("waitid closes group signaling before the leader is reaped")
    func waitIDBarrierPreventsPostReapSignal() async throws {
        let directory = try makeTemporaryDirectory(named: "waitid-barrier")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appending(path: "fixture.sh")
        let marker = directory.appending(path: "owned-processes")
        let script = #"""
            marker=$1
            mkfifo "$marker.fifo"
            mkfifo "$marker.release"
            bash -c 'trap "" TERM; read -r _ < "$1"' "$marker" "$marker.fifo" &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" >"$marker.pending"
            mv "$marker.pending" "$marker"
            read -r _ < "$marker.release"
            exit 0
            """#
        try Data(script.utf8).write(to: fixture)
        let barrier = ReaperBarrier()
        defer { barrier.open() }
        let recorder = SpawnedProcessRecorder()
        let identifiers = ProcessIdentifiers()
        let launch = Task {
            try await runProcess(
                arguments: ["bash", fixture.path, marker.path],
                currentDirectory: directory,
                timeout: .seconds(5),
                afterSpawn: { processIdentifier, state in
                    await recorder.store(processIdentifier, state: state)
                    await identifiers.store([processIdentifier])
                },
                afterTerminalObservation: { barrier.block() },
                onReady: {
                    let values = try await waitForProcessMarker(marker)
                    await identifiers.store(values)
                    try await writeProbeRelease(
                        to: URL(fileURLWithPath: marker.path + ".release")
                    )
                }
            )
        }
        do {
            try await barrier.waitUntilBlocked()
        } catch {
            launch.cancel()
            barrier.open()
            _ = await awaitLaunchOutcome(launch)
            throw error
        }
        let (_, processState) = try await recorder.wait()
        let signalsBeforeCancellation = processState.signalCount
        #expect(signalsBeforeCancellation > 0)
        launch.cancel()
        await Task.yield()
        #expect(processState.signalCount == signalsBeforeCancellation)
        barrier.open()
        let result = try await launch.value
        #expect(result.status == 0)
        try await waitForProcessAbsence(await identifiers.load())
    }
}

private var taskSpikesDirectory: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func discoverModulesDirectory() throws -> URL {
    guard var directory = Bundle.main.executableURL?.deletingLastPathComponent() else {
        throw DiagnosticHarnessError.modulesUnavailable
    }
    for _ in 0..<8 {
        let modules = directory.appending(path: "Modules")
        let keyPathModule = modules.appending(path: "KeyPathBakeoff.swiftmodule")
        let supportModule = modules.appending(path: "SpikeSupport.swiftmodule")
        if FileManager.default.isReadableFile(atPath: keyPathModule.path),
            FileManager.default.isReadableFile(atPath: supportModule.path)
        {
            return modules
        }
        directory.deleteLastPathComponent()
    }
    throw DiagnosticHarnessError.modulesUnavailable
}

private func makeTemporaryDirectory(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "libtmux-\(name)-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private struct LockedOwnedDiagnosticDescriptorState: Sendable {
    var descriptor: Int32?
}

private final class OwnedDiagnosticDescriptor: Sendable {
    #if canImport(Darwin)
        private let state = OSAllocatedUnfairLock(
            initialState: LockedOwnedDiagnosticDescriptorState()
        )
    #else
        private let state = Mutex(LockedOwnedDiagnosticDescriptorState())
    #endif

    init(opening path: String, flags: Int32) throws {
        let descriptor = open(path, flags)
        guard descriptor >= 0 else {
            throw DiagnosticHarnessError.spawnFailed(errno)
        }
        state.withLock { $0.descriptor = descriptor }
    }

    var descriptor: Int32 {
        state.withLock { $0.descriptor ?? -1 }
    }

    func close() {
        let descriptor = state.withLock { state in
            defer { state.descriptor = nil }
            return state.descriptor
        }
        if let descriptor {
            #if canImport(Darwin)
                _ = Darwin.close(descriptor)
            #else
                _ = Glibc.close(descriptor)
            #endif
        }
    }

    deinit { close() }
}

private func authenticatedSigpipeProbePath() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["LIBTMUX_SIGPIPE_PROBE"],
        path.hasPrefix("/"),
        URL(fileURLWithPath: path).standardizedFileURL.path == path,
        URL(fileURLWithPath: path).lastPathComponent == "sigpipe-probe",
        access(path, X_OK) == 0
    else {
        throw DiagnosticHarnessError.missingEnvironmentKey("LIBTMUX_SIGPIPE_PROBE")
    }
    var status = stat()
    guard lstat(path, &status) == 0,
        UInt32(status.st_mode) & 0o170000 == 0o100000,
        status.st_uid == geteuid(),
        UInt32(status.st_mode) & 0o022 == 0
    else {
        throw DiagnosticHarnessError.missingEnvironmentKey("LIBTMUX_SIGPIPE_PROBE")
    }
    return path
}

private func waitForProbeByte(from descriptor: Int32) async throws {
    guard descriptor >= 0 else { throw DiagnosticHarnessError.spawnFailed(EBADF) }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    var byte: UInt8 = 0
    while clock.now < deadline {
        errno = 0
        let count = read(descriptor, &byte, 1)
        if count == 1 { return }
        let readError = errno
        guard
            count == 0 || readError == EAGAIN || readError == EWOULDBLOCK
                || readError == EINTR
        else {
            throw DiagnosticHarnessError.spawnFailed(readError)
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DiagnosticHarnessError.launchTimedOut
}

private func openProbeFIFOWriter(at fifo: URL) async throws -> Int32 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        errno = 0
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 { return descriptor }
        let openError = errno
        guard openError == ENXIO || openError == EINTR else {
            throw DiagnosticHarnessError.spawnFailed(openError)
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DiagnosticHarnessError.launchTimedOut
}

private func makeHandshakeRejectingPath(in directory: URL) throws -> String {
    guard let inheritedPath = ProcessInfo.processInfo.environment["PATH"],
        !inheritedPath.isEmpty
    else {
        throw DiagnosticHarnessError.missingEnvironmentKey("PATH")
    }
    let shims = directory.appending(path: "shims")
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: false)
    let ps = shims.appending(path: "ps")
    let script = #"""
        #!/usr/bin/env bash
        if [[ " $* " == *" -o stat= -o pgid= -p "* ]]; then
            exit 0
        fi
        PATH=${PATH#*:}
        export PATH
        exec ps "$@"
        """#
    try Data(script.utf8).write(to: ps)
    guard chmod(ps.path, 0o700) == 0 else {
        throw DiagnosticHarnessError.spawnFailed(errno)
    }
    return "\(shims.path):\(inheritedPath)"
}

private func makeLaunchSignalBashEnvironment(in directory: URL) throws -> URL {
    let environment = directory.appending(path: "launch-signal.bash")
    let script = #"""
        set -T
        trap '
            if [[ ${BASH_COMMAND:-} == "$LIBTMUX_TEST_LAUNCH_ASSIGNMENT" ]]; then
                trap - DEBUG
                pending="$LIBTMUX_TEST_LAUNCH_MARKER.pending.$$-$RANDOM"
                (umask 077; set -C; printf "%s\n" "$!" >"$pending") || exit 94
                mv "$pending" "$LIBTMUX_TEST_LAUNCH_MARKER" || exit 94
                builtin kill -s "$LIBTMUX_TEST_LAUNCH_SIGNAL" "$$"
            fi
        ' DEBUG
        """#
    try Data(script.utf8).write(to: environment)
    return environment
}

private func makeCaptureFailureBashEnvironment(in directory: URL) throws -> URL {
    let environment = directory.appending(path: "capture-failure.bash")
    let script = #"""
        set -T
        trap '
            if [[ ${BASH_COMMAND:-} == "$LIBTMUX_TEST_LAUNCH_ASSIGNMENT" ]]; then
                trap - DEBUG
                injected_original=$!
                capture_owned_job_handle() {
                    local expected=$1
                    [[ $expected == "$injected_original" ]] || return 2
                    original_state=""
                    attempt=0
                    while (( attempt < 30000 )); do
                        original_state=$(LC_ALL=C ps -o stat= -p \
                            "$injected_original" 2>/dev/null || true)
                        [[ $original_state == *T* ]] && break
                        sleep 0.001
                        (( attempt += 1 ))
                    done
                    [[ $original_state == *T* ]] || return 2
                    bash -c '\''
                        trap "" HUP INT TERM
                        kill -STOP $$
                        while :; do sleep 1; done
                    '\'' &
                    decoy=$!
                    decoy_state=""
                    attempt=0
                    while (( attempt < 30000 )); do
                        decoy_state=$(LC_ALL=C ps -o stat= -p "$decoy" 2>/dev/null || true)
                        [[ $decoy_state == *T* ]] && break
                        sleep 0.001
                        (( attempt += 1 ))
                    done
                    [[ $decoy_state == *T* ]] || return 2
                    pending="$LIBTMUX_TEST_LAUNCH_MARKER.pending.$$-$RANDOM"
                    (umask 077; set -C; printf "%s %s\n" \
                        "$injected_original" "$decoy" >"$pending") || return 2
                    mv "$pending" "$LIBTMUX_TEST_LAUNCH_MARKER" || return 2
                    return 1
                }
            fi
        ' DEBUG
        """#
    try Data(script.utf8).write(to: environment)
    return environment
}

private func makeBash3CompatibilityEnvironment(in directory: URL) throws -> URL {
    let environment = directory.appending(path: "bash-3-compatibility.bash")
    try Data("unset BASHPID\n".utf8).write(to: environment)
    return environment
}

private func makeRetiredJobCacheBashEnvironment(in directory: URL) throws -> URL {
    let environment = directory.appending(path: "retired-job-cache.bash")
    let script = #"""
        unset BASHPID
        jobs() {
            if [[ -e ${LIBTMUX_TEST_RETIRED_JOB:-} ]]; then
                if [[ ${1:-} == "-x" && ${2:-} == "test" \
                    && ${3:-} == %* && ${4:-} == "=" \
                    && ${5:-} =~ ^[1-9][0-9]*$ ]]; then
                    builtin test "$5" = "$5"
                    return
                fi
                if [[ ${1:-} == "-p" && ${2:-} == %* ]]; then
                    return 0
                fi
            fi
            builtin jobs "$@"
        }
        """#
    try Data(script.utf8).write(to: environment)
    return environment
}

private func makeWait127BashEnvironment(in directory: URL) throws -> URL {
    let environment = directory.appending(path: "wait-127.bash")
    let script = #"""
        wait() {
            local status=0
            builtin wait "$@" || status=$?
            if [[ ${FUNCNAME[1]:-} == reap_active_child ]]; then
                return 127
            fi
            return "$status"
        }
        """#
    try Data(script.utf8).write(to: environment)
    return environment
}

private func makeBoundedWait127BashEnvironment(in directory: URL) throws -> URL {
    let environment = directory.appending(path: "bounded-wait-127.bash")
    let script = #"""
        wait() {
            local status=0
            builtin wait "$@" || status=$?
            if [[ ${FUNCNAME[1]:-} == bounded_stop ]]; then
                return 127
            fi
            return "$status"
        }
        """#
    try Data(script.utf8).write(to: environment)
    return environment
}

private func requireOwnedJobCleanupTrace(
    _ output: String,
    childVariable: String
) throws {
    let lines = output.split(separator: "\n").map(String.init)
    let assignmentMarker = ":run_bounded: \(childVariable)="
    let assignment = try #require(lines.first { $0.contains(assignmentMarker) })
    let assignmentParts = assignment.components(separatedBy: assignmentMarker)
    #expect(assignmentParts.count == 2)
    let owner = try #require(assignmentParts.first)
    let child = try #require(assignmentParts.last)
    #expect(child.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil)

    let ownerPrefix = "\(owner):"
    let ownedLines = lines.filter { $0.hasPrefix(ownerPrefix) }
    let signalMarker = ":signal_owned_job_handle: builtin kill -s KILL -- "
    let signalLine = try #require(ownedLines.first { $0.contains(signalMarker) })
    let signalParts = signalLine.components(separatedBy: signalMarker)
    #expect(signalParts.count == 2)
    let job = try #require(signalParts.last)
    #expect(job.range(of: #"^%[1-9][0-9]*$"#, options: .regularExpression) != nil)

    let resolution =
        "\(ownerPrefix)owned_job_handle_is_active: jobs -x test \(job) = \(child)"
    #expect(ownedLines.filter { $0 == resolution }.count >= 1)
    #expect(ownedLines.filter { $0 == signalLine }.count == 1)

    let waitSuffix = ": wait \(child)"
    let waitLines = ownedLines.filter { $0.hasSuffix(waitSuffix) }
    #expect(waitLines.count == 1)
    let waitLine = try #require(waitLines.first)
    let signalIndex = try #require(ownedLines.firstIndex(of: signalLine))
    let waitIndex = try #require(ownedLines.firstIndex(of: waitLine))
    #expect(signalIndex < waitIndex)

    let signalCommands = ownedLines.filter {
        $0.contains(": builtin kill ") || $0.contains(": kill -")
    }
    #expect(signalCommands.allSatisfy { $0.hasSuffix("-- \(job)") })
    let afterWait = ownedLines[ownedLines.index(after: waitIndex)...]
    #expect(
        !afterWait.contains {
            $0.contains(": builtin kill ")
                || $0.contains(": kill -")
                || $0.contains(": jobs -x ")
        }
    )
}

private func requireNoRawSignalAfterJobRetirement(
    _ output: String,
    child: pid_t
) throws {
    let lines = output.split(separator: "\n").map(String.init)
    let assignmentMarker = ":run_bounded: child=\(child)"
    let assignment = try #require(lines.first { $0.contains(assignmentMarker) })
    let owner = try #require(assignment.components(separatedBy: assignmentMarker).first)
    let ownerPrefix = "\(owner):"
    let ownedLines = lines.filter { $0.hasPrefix(ownerPrefix) }
    let gateReturnIndex = try #require(
        ownedLines.firstIndex { $0.hasSuffix(":wait_at_gate: return 0") }
    )
    let afterRetirement = ownedLines[ownedLines.index(after: gateReturnIndex)...]

    #expect(
        afterRetirement.contains { line in
            line.contains(":owned_job_handle_is_active: jobs -x test %")
                && line.hasSuffix("= \(child)")
        }
    )
    let signalCommands = afterRetirement.filter {
        $0.contains(": kill ") || $0.contains(": builtin kill ")
    }
    #expect(signalCommands.isEmpty)
    #expect(afterRetirement.filter { $0.hasSuffix(": wait \(child)") }.count == 1)
}

private func runGenerator(
    _ generator: URL,
    _ mode: String,
    in directory: URL
) async throws -> ProcessResult {
    try await runProcess(
        arguments: [
            "swift",
            "-module-cache-path",
            directory.appending(path: "module-cache").path,
            generator.path,
            mode,
        ],
        currentDirectory: directory,
        timeout: .seconds(30)
    )
}

private func runProcess(
    arguments: [String],
    currentDirectory: URL,
    timeout: Duration,
    cleanupTaskProbe: CleanupTaskProbe? = nil,
    afterCompletion: (@Sendable () async -> Void)? = nil,
    afterSpawn: (@Sendable (pid_t, DiagnosticProcessState) async throws -> Void)? = nil,
    beforeWaitID: (@Sendable () -> Void)? = nil,
    forceWaitIDFailure: Bool = false,
    afterTerminalObservation: (@Sendable () -> Void)? = nil,
    onReady: (@Sendable () async throws -> Void)? = nil
) async throws -> ProcessResult {
    let outputURL = currentDirectory.appending(path: "process-\(UUID().uuidString).out")
    let lifecycle = ProcessLifecycle()
    let processState = DiagnosticProcessState()
    let wrapper = taskSpikesDirectory.appending(path: "Scripts/run-process-group.sh")
    let inheritedEnvironment = ProcessInfo.processInfo.environment
    guard let path = inheritedEnvironment["PATH"], !path.isEmpty else {
        throw DiagnosticHarnessError.missingEnvironmentKey("PATH")
    }
    var environment = [
        "PATH": path,
        "LC_ALL": "C",
        "TMPDIR": currentDirectory.path,
    ]
    for key in ["DEVELOPER_DIR", "SDKROOT"] {
        if let value = inheritedEnvironment[key] { environment[key] = value }
    }
    try Task.checkCancellation()
    let process = try spawnDiagnosticProcess(
        arguments: [
            "bash", wrapper.path, "--cwd", currentDirectory.path, "--",
        ] + arguments,
        environment: environment,
        outputURL: outputURL,
        lifecycle: lifecycle,
        processState: processState,
        beforeWaitID: beforeWaitID,
        forceWaitIDFailure: forceWaitIDFailure,
        afterTerminalObservation: afterTerminalObservation
    )
    let owner = ProcessOwner(
        lifecycle: lifecycle,
        processState: processState,
        cleanupTaskProbe: cleanupTaskProbe
    )
    return try await withTaskCancellationHandler {
        var acquisitionOutcome: ExitRace?
        do {
            try Task.checkCancellation()
            try await afterSpawn?(process.processIdentifier, processState)
            try Task.checkCancellation()
            try await onReady?()
        } catch {
            let isCancellationError = error is CancellationError
            if isCancellationError {
                _ = processState.requestCancellation()
            } else {
                _ = processState.requestCleanup()
            }
            let cleanup = await owner.stopAndWait()
            if cleanup.controlFailed {
                throw DiagnosticHarnessError.cleanupSignalFailedAfter(
                    String(describing: type(of: error))
                )
            }
            if isCancellationError {
                let committedOutcome = processState.outcome(for: cleanup.status)
                if case .cancelled = committedOutcome { throw CancellationError() }
                acquisitionOutcome = committedOutcome
            } else {
                throw error
            }
        }

        let race: ExitRace
        if let acquisitionOutcome {
            race = acquisitionOutcome
            if case .completed = acquisitionOutcome { await afterCompletion?() }
        } else {
            do {
                race = try await withThrowingTaskGroup(of: ExitRace.self) { group in
                    group.addTask {
                        let status = await lifecycle.wait()
                        return processState.outcome(for: status)
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        guard processState.requestTimeout() else {
                            let status = await lifecycle.wait()
                            return processState.outcome(for: status)
                        }
                        let cleanup = await owner.stopAndWait()
                        return processState.outcome(for: cleanup.status)
                    }
                    defer { group.cancelAll() }
                    let result = try await group.next() ?? .timedOut(-1)
                    if case .completed = result { await afterCompletion?() }
                    if Task.isCancelled { _ = processState.requestCancellation() }
                    return result
                }
            } catch {
                if Task.isCancelled {
                    _ = processState.requestCancellation()
                } else {
                    _ = processState.requestCleanup()
                }
                let cleanup = await owner.stopAndWait()
                if cleanup.controlFailed {
                    throw DiagnosticHarnessError.cleanupSignalFailedAfter(
                        String(describing: type(of: error))
                    )
                }
                if Task.isCancelled {
                    let committedOutcome = processState.outcome(for: cleanup.status)
                    if case .cancelled = committedOutcome { throw CancellationError() }
                    if case .completed = committedOutcome { await afterCompletion?() }
                    race = committedOutcome
                } else {
                    throw error
                }
            }
        }
        if Task.isCancelled { _ = processState.requestCancellation() }
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        switch race {
        case .cancelled:
            let cleanup = await owner.stopAndWait()
            if cleanup.controlFailed { throw DiagnosticHarnessError.cleanupSignalFailed }
            throw CancellationError()
        case let .completed(status):
            if processState.controlFailed {
                throw DiagnosticHarnessError.cleanupSignalFailed
            }
            if status < 0 { throw DiagnosticHarnessError.waitFailed(-status) }
            return ProcessResult(status: status, output: output)
        case .timedOut:
            let cleanup = await owner.stopAndWait()
            if cleanup.controlFailed { throw DiagnosticHarnessError.cleanupSignalFailed }
            throw DiagnosticHarnessError.launchTimedOut
        }
    } onCancel: {
        if processState.requestCancellation() {
            _ = owner.startCleanup()
        }
    }
}

private func spawnDiagnosticProcess(
    arguments: [String],
    environment: [String: String],
    outputURL: URL,
    lifecycle: ProcessLifecycle,
    processState: DiagnosticProcessState,
    beforeWaitID: (@Sendable () -> Void)?,
    forceWaitIDFailure: Bool,
    afterTerminalObservation: (@Sendable () -> Void)?
) throws -> SpawnedDiagnosticProcess {
    let outputDescriptor = try openDiagnosticDescriptor(
        outputURL.path,
        flags: O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
        mode: 0o600
    )
    let inputDescriptor: Int32
    do {
        inputDescriptor = try openDiagnosticDescriptor(
            "/dev/null",
            flags: O_RDONLY | O_CLOEXEC,
            mode: 0
        )
    } catch {
        _ = close(outputDescriptor)
        throw error
    }
    defer {
        _ = close(outputDescriptor)
        _ = close(inputDescriptor)
    }

    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
    #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
    #endif
    var actionsInitialized = false
    var attributesInitialized = false
    defer {
        if actionsInitialized {
            _ = posix_spawn_file_actions_destroy(&actions)
        }
        if attributesInitialized {
            _ = posix_spawnattr_destroy(&attributes)
        }
    }

    var code = posix_spawn_file_actions_init(&actions)
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    actionsInitialized = true
    code = posix_spawnattr_init(&attributes)
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    attributesInitialized = true

    for (source, destination) in [
        (inputDescriptor, STDIN_FILENO),
        (outputDescriptor, STDOUT_FILENO),
        (outputDescriptor, STDERR_FILENO),
    ] {
        code = posix_spawn_file_actions_adddup2(&actions, source, destination)
        guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    }
    #if canImport(Darwin)
        for descriptor in [inputDescriptor, outputDescriptor] {
            code = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
        }
    #else
        code = posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1)
        guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    #endif

    var emptyMask = sigset_t()
    guard sigemptyset(&emptyMask) == 0 else {
        throw DiagnosticHarnessError.spawnFailed(errno)
    }
    code = posix_spawnattr_setsigmask(&attributes, &emptyMask)
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    var defaultSignals = sigset_t()
    guard sigemptyset(&defaultSignals) == 0,
        sigaddset(&defaultSignals, SIGTERM) == 0,
        sigaddset(&defaultSignals, SIGHUP) == 0,
        sigaddset(&defaultSignals, SIGINT) == 0
    else {
        throw DiagnosticHarnessError.spawnFailed(errno)
    }
    code = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    code = posix_spawnattr_setpgroup(&attributes, 0)
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    var flags =
        Int16(POSIX_SPAWN_SETSIGMASK)
        | Int16(POSIX_SPAWN_SETSIGDEF)
        | Int16(POSIX_SPAWN_SETPGROUP)
    #if canImport(Darwin)
        flags |= Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
    #endif
    code = posix_spawnattr_setflags(&attributes, flags)
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }

    let executable = "/usr/bin/env"
    let argv = [executable] + arguments
    let environmentValues = environment.keys.sorted().map {
        "\($0)=\(environment[$0]!)"
    }
    var processIdentifier: pid_t = 0
    code = withDiagnosticCStringArray(argv) { argumentPointers in
        withDiagnosticCStringArray(environmentValues) { environmentPointers in
            posix_spawn(
                &processIdentifier,
                executable,
                &actions,
                &attributes,
                argumentPointers,
                environmentPointers
            )
        }
    }
    guard code == 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
    processState.install(processIdentifier: processIdentifier)

    let waitedProcessIdentifier = processIdentifier
    DispatchQueue.global().async {
        beforeWaitID?()
        let waitIDError: Int32
        if forceWaitIDFailure {
            waitIDError = EINVAL
        } else {
            var information = siginfo_t()
            var waitIDResult: Int32
            repeat {
                waitIDResult = waitid(
                    P_PID,
                    id_t(waitedProcessIdentifier),
                    &information,
                    WEXITED | WNOWAIT
                )
            } while waitIDResult != 0 && errno == EINTR
            waitIDError = waitIDResult == 0 ? 0 : errno
        }
        var waitStatus: Int32 = 0
        let status: Int32
        if waitIDError == 0 {
            processState.observeTerminal()
            afterTerminalObservation?()
            var result: pid_t
            repeat {
                result = waitpid(waitedProcessIdentifier, &waitStatus, 0)
            } while result < 0 && errno == EINTR
            if result == waitedProcessIdentifier {
                status = diagnosticExitStatus(waitStatus)
            } else {
                status = -errno
            }
        } else {
            switch processState.recoverFromWaitIDFailure(waitedProcessIdentifier) {
            case .reaped:
                status = -waitIDError
            case let .failed(error):
                status = -error
            case .wait:
                var result: pid_t
                repeat {
                    errno = 0
                    result = waitpid(waitedProcessIdentifier, &waitStatus, 0)
                } while result < 0 && errno == EINTR
                let waitError = errno
                if result == waitedProcessIdentifier {
                    status = -waitIDError
                } else if result < 0 {
                    status = -waitError
                } else {
                    status = -ECHILD
                }
            }
        }
        Task { await lifecycle.finish(status) }
    }
    return SpawnedDiagnosticProcess(processIdentifier: processIdentifier)
}

private func openDiagnosticDescriptor(
    _ path: String,
    flags: Int32,
    mode: mode_t
) throws -> Int32 {
    let descriptor = open(path, flags, mode)
    guard descriptor >= 0 else { throw DiagnosticHarnessError.spawnFailed(errno) }
    guard descriptor > STDERR_FILENO else {
        let replacement = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        let code = errno
        _ = close(descriptor)
        guard replacement >= 0 else { throw DiagnosticHarnessError.spawnFailed(code) }
        return replacement
    }
    return descriptor
}

private func withDiagnosticCStringArray<Result>(
    _ strings: [String],
    body: ([UnsafeMutablePointer<CChar>?]) throws -> Result
) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    pointers.append(nil)
    return try body(pointers)
}

private func diagnosticExitStatus(_ status: Int32) -> Int32 {
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

private func awaitLaunchOutcome(
    _ launch: Task<ProcessResult, any Error>
) async -> LaunchOutcome {
    await withTaskGroup(of: LaunchOutcome.self) { group in
        group.addTask {
            do {
                _ = try await launch.value
                return .completed
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(String(describing: type(of: error)))
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(8))
            return .deadline
        }
        let outcome = await group.next() ?? .deadline
        if outcome == .deadline {
            launch.cancel()
        }
        group.cancelAll()
        return outcome
    }
}

private func writeProbeByteWithoutSIGPIPE(
    _ descriptor: Int32,
    byte: inout UInt8
) -> Int32 {
    var signalSet = sigset_t()
    var oldSignalSet = sigset_t()
    guard sigemptyset(&signalSet) == 0,
        sigaddset(&signalSet, SIGPIPE) == 0
    else { return errno }
    let maskResult = pthread_sigmask(SIG_BLOCK, &signalSet, &oldSignalSet)
    guard maskResult == 0 else { return maskResult }

    let operationResult: Int32 = {
        var pendingBefore = sigset_t()
        guard sigemptyset(&pendingBefore) == 0,
            sigpending(&pendingBefore) == 0
        else { return errno }
        let hadPendingSIGPIPE = sigismember(&pendingBefore, SIGPIPE) == 1

        errno = 0
        let count = write(descriptor, &byte, 1)
        guard count != 1 else { return 0 }
        let writeError = count < 0 ? errno : EIO
        guard writeError == EPIPE, !hadPendingSIGPIPE else { return writeError }

        var pendingAfter = sigset_t()
        guard sigemptyset(&pendingAfter) == 0,
            sigpending(&pendingAfter) == 0
        else { return errno }
        if sigismember(&pendingAfter, SIGPIPE) == 1 {
            var receivedSignal: Int32 = 0
            let waitResult = sigwait(&signalSet, &receivedSignal)
            guard waitResult == 0, receivedSignal == SIGPIPE else {
                return waitResult == 0 ? EINVAL : waitResult
            }
        }
        return writeError
    }()
    let restoreResult = pthread_sigmask(SIG_SETMASK, &oldSignalSet, nil)
    return restoreResult == 0 ? operationResult : restoreResult
}

private func waitForProcessMarker(
    _ marker: URL,
    expectedCount: Int = 2
) async throws -> [pid_t] {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if let contents = try? String(contentsOf: marker, encoding: .utf8) {
            let values = contents.split(whereSeparator: \.isWhitespace).compactMap {
                pid_t($0)
            }
            guard values.count == expectedCount else {
                throw DiagnosticHarnessError.malformedProcessMarker
            }
            return values
        }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DiagnosticHarnessError.malformedProcessMarker
}

private func requireCompetingJobRetirement(marker: URL) async throws {
    let identifiers = try await waitForProcessMarker(marker, expectedCount: 2)
    let original = identifiers[0]
    let decoy = identifiers[1]
    #expect(original > 1)
    #expect(decoy > 1)
    #expect(original != decoy)

    let originalSurvived = processExists(original)
    let decoySurvived = processExists(decoy)
    #expect(!originalSurvived, "the originally launched supervisor survived retirement")
    #expect(decoySurvived, "capture-failure cleanup touched the competing current job")
    if decoySurvived {
        #expect(getpgid(decoy) == decoy, "the competing job changed process-group identity")
    }

    try await tearDownCaptureFailureJobs(identifiers)
}

private func tearDownCaptureFailureJobs(marker: URL) async throws {
    let identifiers = try await waitForProcessMarker(marker, expectedCount: 2)
    try await tearDownCaptureFailureJobs(identifiers)
}

private func tearDownCaptureFailureJobs(_ identifiers: [pid_t]) async throws {
    for processIdentifier in identifiers where processExists(processIdentifier) {
        try terminateTestProcessGroup(processIdentifier)
    }
    try await waitForProcessAbsence(identifiers)
}

private func writeProbeRelease(
    to fifo: URL,
    timeout: Duration = .seconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        try Task.checkCancellation()
        errno = 0
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if descriptor >= 0 {
            defer { _ = close(descriptor) }
            while clock.now < deadline {
                try Task.checkCancellation()
                var byte = UInt8(ascii: "\n")
                let writeError = writeProbeByteWithoutSIGPIPE(
                    descriptor,
                    byte: &byte
                )
                if writeError == 0 { return }
                guard writeError == EINTR else {
                    throw DiagnosticHarnessError.spawnFailed(writeError)
                }
            }
            throw DiagnosticHarnessError.launchTimedOut
        }
        let openError = errno
        guard openError == ENXIO || openError == EINTR else {
            throw DiagnosticHarnessError.spawnFailed(openError)
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DiagnosticHarnessError.launchTimedOut
}

private func makeProbeFIFO(at fifo: URL) throws {
    guard mkfifo(fifo.path, 0o600) == 0 else {
        throw DiagnosticHarnessError.spawnFailed(errno)
    }
}

private func waitForProcessAbsence(_ identifiers: [pid_t]) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if identifiers.allSatisfy({ !processExists($0) }) { return }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DiagnosticHarnessError.launchTimedOut
}

private func waitForCleanupTaskAbsence(_ probe: CleanupTaskProbe) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
        if probe.activeCount == 0 { return }
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(1))
    }
    throw DiagnosticHarnessError.launchTimedOut
}

private func terminateTestProcessGroup(_ processIdentifier: pid_t) throws {
    guard processIdentifier > 1,
        processIdentifier != getpgrp(),
        getpgid(processIdentifier) == processIdentifier
    else {
        throw DiagnosticHarnessError.unsafeProcessGroup
    }
    errno = 0
    let result = kill(-processIdentifier, SIGKILL)
    guard result == 0 || errno == ESRCH else {
        throw DiagnosticHarnessError.spawnFailed(errno)
    }
}

private func processExists(_ identifier: pid_t) -> Bool {
    errno = 0
    return kill(identifier, 0) == 0 || errno != ESRCH
}
