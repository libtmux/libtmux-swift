import Foundation
import Testing

@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import os
#else
    import Synchronization
#endif

actor NonCancellationGate {
    private var opened = false
    private var parked = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        parked = true
        guard !opened else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilParked() async {
        while !parked { await Task.yield() }
    }

    func waitUntilParkedOrCancelled() async throws {
        while !parked {
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func open() {
        opened = true
        waiter?.resume()
        waiter = nil
    }
}

private final class SignalAttemptRecorder: Sendable {
    #if canImport(Darwin)
        private let attempts = OSAllocatedUnfairLock(initialState: 0)
    #else
        private let attempts = Mutex(0)
    #endif

    func record() -> Int32 {
        attempts.withLock { $0 += 1 }
        return 0
    }

    var count: Int {
        attempts.withLock { $0 }
    }
}

struct ProbeProcessTree: Sendable {
    let leader: Int32
    let descendant: Int32
    let processGroup: Int32
}

struct FoundationCancellationObservation: Sendable {
    let leaderReaped: Bool
    let descendantSurvived: Bool
    let descendantCleaned: Bool
}

enum ContractDeadlineError: Error {
    case exceeded
}

extension TransportBakeoffSuite {
    @Suite("transport cancellation")
    struct CancellationTests {
        @Test("direct spawn cancellation never signals after exact child reap")
        func directSpawnCancellationNeverSignalsAfterExactChildReap() async throws {
            let reaped = NonCancellationGate()
            let signals = SignalAttemptRecorder()
            let task = Task {
                try await DirectSpawnTransport(
                    processOwnerHooks: POSIXProcessOwnerHooks(
                        signalProcessGroup: { _, _ in signals.record() },
                        afterReap: { await reaped.wait() }
                    )
                ).run(try probeRequest(["exit", "0"]))
            }
            do {
                try await withContractDeadline(
                    operation: { try await reaped.waitUntilParkedOrCancelled() },
                    onTimeout: { task.cancel() }
                )
            } catch {
                task.cancel()
                await reaped.open()
                _ = await task.result
                throw error
            }
            let attemptsBeforeCancellation = signals.count
            #expect(attemptsBeforeCancellation > 0)
            task.cancel()
            await reaped.open()

            do {
                _ = try await withContractDeadline { try await task.value }
                Issue.record("cancelled request returned a reply")
            } catch is CancellationError {
            }
            #expect(signals.count == attemptsBeforeCancellation)
        }

        @Test("direct spawn recovers from a nonterminal waitid failure")
        func directSpawnRecoversFromANonterminalWaitIDFailure() async throws {
            let signals = SignalAttemptRecorder()
            do {
                _ = try await withContractDeadline {
                    try await DirectSpawnTransport(
                        processOwnerHooks: POSIXProcessOwnerHooks(
                            signalProcessGroup: { processIdentifier, signal in
                                _ = signals.record()
                                return kill(-processIdentifier, signal)
                            },
                            observeTerminal: { _ in .failed(EINVAL) }
                        )
                    ).run(try probeRequest(["delayed-exit", "1000"]))
                }
                Issue.record("injected waitid failure returned a reply")
            } catch let ProcessInvocationError.ioFailure(operation, code) {
                #expect(operation == "waitid")
                #expect(code == EINVAL)
            }

            #expect(signals.count > 0)
        }

        @Test("cancellation before spawn wins over invocation", arguments: TransportKind.allCases)
        func cancellationBeforeSpawnWinsOverInvocation(_ kind: TransportKind) async throws {
            let gate = NonCancellationGate()
            let task = Task {
                await gate.wait()
                return try await kind.transport().run(
                    ProcessRequest(
                        executable: .path("/libtmux/must-not-spawn"),
                        arguments: [],
                        environment: [:],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            await gate.waitUntilParked()
            task.cancel()
            await gate.open()

            do {
                _ = try await withContractDeadline { try await task.value }
                Issue.record("cancelled request returned a reply")
            } catch is CancellationError {
            }
        }

        @Test(
            "cancellation terminates a blocked process group",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func cancellationTerminatesABlockedProcessGroup(_ kind: TransportKind) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupProcessGroup: Int32?
            let task = Task {
                try await kind.transport().run(try probeRequest(["block", marker.path]))
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForProbeMarker(marker)
            cleanupProcessGroup = tree.processGroup
            task.cancel()

            do {
                _ = try await withContractDeadline(
                    operation: { try await task.value },
                    onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
                )
                Issue.record("cancelled blocked request returned a reply")
            } catch is CancellationError {
            }
            try await assertCancellationOutcome(kind: kind, tree: tree)
            cleanupProcessGroup = nil
        }

        @Test(
            "cancellation during output terminates the producer",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func cancellationDuringOutputTerminatesTheProducer(_ kind: TransportKind) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupProcessGroup: Int32?
            let task = Task {
                try await kind.transport().run(try probeRequest(["stream", marker.path, "4096"]))
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForProbeMarker(marker)
            cleanupProcessGroup = tree.processGroup
            task.cancel()

            do {
                _ = try await withContractDeadline(
                    operation: { try await task.value },
                    onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
                )
                Issue.record("cancelled streaming request returned a reply")
            } catch is CancellationError {
            }
            try await assertCancellationOutcome(kind: kind, tree: tree)
            cleanupProcessGroup = nil
        }

        @Test("swift-subprocess cancellation kills a SIGTERM-ignoring descendant")
        func swiftSubprocessCancellationKillsASIGTERMIgnoringDescendant() async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                var cleanupDescendant: Int32?
                let task = Task {
                    try await SwiftSubprocessTransport().run(
                        try probeRequest(["block-stubborn-descendant", marker.path])
                    )
                }
                defer {
                    task.cancel()
                    if let cleanupDescendant,
                        processIsRunning(cleanupDescendant),
                        processHasExactArgument(cleanupDescendant, marker.path)
                    {
                        _ = kill(cleanupDescendant, SIGKILL)
                    }
                    try? FileManager.default.removeItem(at: marker)
                }

                let tree = try await waitForProbeMarker(marker)
                cleanupDescendant = tree.descendant
                task.cancel()
                do {
                    _ = try await withContractDeadline { try await task.value }
                    Issue.record("cancelled request returned reply data")
                } catch is CancellationError {
                }
                try await waitForProcessRecordAbsence(tree.leader)
                let descendantRemoved = try await processRecordBecomesAbsent(
                    tree.descendant,
                    within: .seconds(1)
                )
                #expect(descendantRemoved)
                if !descendantRemoved,
                    processIsRunning(tree.descendant),
                    processHasExactArgument(tree.descendant, marker.path)
                {
                    _ = kill(tree.descendant, SIGKILL)
                }
                try await waitForProcessRecordAbsence(tree.descendant)
                if processRecordIsAbsent(tree.descendant) { cleanupDescendant = nil }
            #endif
        }

        @Test("Foundation cancellation leaves its descendant alive")
        func foundationCancellationLeavesItsDescendantAlive() async throws {
            let observation = try await observeFoundationCancellationDisqualification()

            #expect(observation.leaderReaped)
            #expect(observation.descendantSurvived)
            #expect(observation.descendantCleaned)
        }

        @Test("direct blocked waits preserve cooperative executor progress")
        func directBlockedWaitsPreserveCooperativeExecutorProgress() async throws {
            var markers: [URL] = []
            var tasks: [Task<ProcessReply, any Error>] = []
            var trees: [ProbeProcessTree] = []
            var cleanupProcessGroups: Set<Int32> = []
            defer {
                for task in tasks { task.cancel() }
                for processGroup in cleanupProcessGroups { _ = kill(-processGroup, SIGKILL) }
                for marker in markers { try? FileManager.default.removeItem(at: marker) }
            }

            for _ in 0..<8 {
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString
                )
                markers.append(marker)
                let task = Task {
                    try await DirectSpawnTransport().run(
                        try probeRequest(["block", marker.path])
                    )
                }
                tasks.append(task)
                let tree = try await waitForProbeMarker(marker)
                trees.append(tree)
                cleanupProcessGroups.insert(tree.processGroup)
            }

            let progress = Task {
                var steps = 0
                for _ in 0..<10_000 {
                    steps += 1
                    await Task.yield()
                }
                return steps
            }
            #expect(try await withContractDeadline { await progress.value } == 10_000)

            for (task, tree) in zip(tasks, trees) {
                task.cancel()
                do {
                    _ = try await withContractDeadline(
                        operation: { try await task.value },
                        onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
                    )
                    Issue.record("cancelled blocked direct process returned reply data")
                } catch is CancellationError {
                }
                try await assertCancellationOutcome(kind: .directSpawn, tree: tree)
                cleanupProcessGroups.remove(tree.processGroup)
            }
        }
    }
}

func withContractDeadline<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value,
    onTimeout: @escaping @Sendable () -> Void = {}
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            onTimeout()
            throw ContractDeadlineError.exceeded
        }
        guard let value = try await group.next() else {
            throw ContractDeadlineError.exceeded
        }
        group.cancelAll()
        return value
    }
}

func waitForProbeMarker(
    _ marker: URL,
    within duration: Duration = .seconds(5)
) async throws -> ProbeProcessTree {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        if let tree = probeProcessTree(from: marker) { return tree }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ContractFixtureError.invalidProbeReply
}

func probeProcessTree(from marker: URL) -> ProbeProcessTree? {
    guard let data = try? Data(contentsOf: marker), !data.isEmpty else { return nil }
    let fields = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \Character.isWhitespace)
    guard fields.count == 3, let leader = Int32(fields[0]),
        let descendant = Int32(fields[1]), let processGroup = Int32(fields[2])
    else { return nil }
    return ProbeProcessTree(
        leader: leader,
        descendant: descendant,
        processGroup: processGroup
    )
}

private func observeFoundationCancellationDisqualification() async throws
    -> FoundationCancellationObservation
{
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var cleanupLeader: Int32?
    var cleanupDescendant: Int32?
    let task = Task {
        try await FoundationProcessTransport().run(try probeRequest(["block", marker.path]))
    }
    defer {
        task.cancel()
        if let cleanupLeader { _ = kill(cleanupLeader, SIGKILL) }
        if let cleanupDescendant { _ = kill(cleanupDescendant, SIGKILL) }
        try? FileManager.default.removeItem(at: marker)
    }

    let tree = try await waitForProbeMarker(marker)
    cleanupLeader = tree.leader
    cleanupDescendant = tree.descendant
    task.cancel()
    try await waitForProcessExit(tree.leader)
    guard !processIsRunning(tree.leader) else { throw ContractDeadlineError.exceeded }
    let descendantSurvived = processIsRunning(tree.descendant)
    if descendantSurvived {
        _ = kill(tree.descendant, SIGKILL)
    } else if processRecordIsAbsent(tree.descendant) {
        cleanupDescendant = nil
    }
    try await waitForProcessRecordAbsence(tree.descendant)
    let descendantCleaned = processRecordIsAbsent(tree.descendant)
    if descendantCleaned { cleanupDescendant = nil }

    do {
        _ = try await withContractDeadline(
            operation: { try await task.value },
            onTimeout: { _ = kill(tree.leader, SIGKILL) }
        )
        throw ContractFixtureError.invalidProbeReply
    } catch is CancellationError {
    }

    try await waitForProcessRecordAbsence(tree.leader)
    let leaderReaped = processRecordIsAbsent(tree.leader)
    if leaderReaped { cleanupLeader = nil }
    return FoundationCancellationObservation(
        leaderReaped: leaderReaped,
        descendantSurvived: descendantSurvived,
        descendantCleaned: descendantCleaned
    )
}

func assertCancellationOutcome(kind: TransportKind, tree: ProbeProcessTree) async throws {
    #expect(tree.leader == tree.processGroup)
    try await waitForProcessRecordAbsence(tree.leader)
    #expect(processRecordIsAbsent(tree.leader))
    try await waitForProcessRecordAbsence(tree.descendant)
    #expect(processRecordIsAbsent(tree.descendant))
}

func waitForProcessExit(_ processIdentifier: Int32) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        guard processIsRunning(processIdentifier) else { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func processRecordIsAbsent(_ processIdentifier: Int32) -> Bool {
    #if os(Linux)
        return !FileManager.default.fileExists(atPath: "/proc/\(processIdentifier)")
    #else
        return !processIsRunning(processIdentifier)
    #endif
}

func waitForProcessRecordAbsence(_ processIdentifier: Int32) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        if processRecordIsAbsent(processIdentifier) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

func processRecordBecomesAbsent(
    _ processIdentifier: Int32,
    within duration: Duration
) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        if processRecordIsAbsent(processIdentifier) { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return processRecordIsAbsent(processIdentifier)
}

#if os(Linux)
    func processHasExactArgument(
        _ processIdentifier: Int32,
        _ argument: String
    ) -> Bool {
        guard
            let data = FileManager.default.contents(
                atPath: "/proc/\(processIdentifier)/cmdline")
        else { return false }
        let arguments = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true)
        return arguments.contains(Substring(argument))
    }
#endif
