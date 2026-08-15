import Testing

@testable import OwnershipBakeoff
@testable import SpikeSupport

private enum SchedulerFixtureError: Error {
    case bodyFailed
    case cancellationWasNotObserved
    case timedOut
}

private actor OwnershipCheckpointGate {
    private let parkedGate = AsyncGate()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await parkedGate.open()
        if isOpen { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilParked() async throws {
        try await parkedGate.wait()
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

private actor InvocationCounter {
    private var count = 0

    func increment() { count += 1 }
    var value: Int { count }
}

private actor ReentrantTransport: ProcessTransport {
    private var callback: (@Sendable () async throws -> Void)?
    private var labels: [String] = []

    func install(callback: @escaping @Sendable () async throws -> Void) {
        self.callback = callback
    }

    func run(_ request: ProcessRequest) async throws -> ProcessReply {
        guard let label = request.arguments.first else {
            throw RecordingTransportError.missingLabel
        }
        labels.append(label)
        if label == "outer", let callback {
            try await callback()
        }
        return ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(0)
        )
    }

    var observedLabels: [String] { labels }
}

private func schedulerRequest(_ label: String) throws -> ProcessRequest {
    try ProcessRequest(
        executable: .name("ownership-probe"),
        arguments: [label],
        environment: [:],
        workingDirectory: nil,
        outputPolicy: .complete
    )
}

private func withOwnershipDeadline<Value: Sendable>(
    onTimeout: @escaping @Sendable () async -> Void = {},
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            await onTimeout()
            throw SchedulerFixtureError.timedOut
        }
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            throw SchedulerFixtureError.timedOut
        }
        return value
    }
}

private func finishSchedulerTasks(
    _ tasks: [Task<Void, any Error>],
    gates: [AsyncGate] = [],
    checkpoints: [OwnershipCheckpointGate] = []
) async {
    for task in tasks { task.cancel() }
    for gate in gates { await gate.open() }
    for checkpoint in checkpoints { await checkpoint.open() }
    for task in tasks { _ = try? await task.value }
}

@Suite("runtime scheduler")
struct SchedulerTests {
    @Test("many readers overlap before a writer")
    func manyReadersOverlapBeforeWriter() async throws {
        let observer = SchedulerObserver()
        let scheduler = RuntimeScheduler(observer: observer)
        let readerHold = AsyncGate()
        let readers = (0..<4).map { index in
            Task {
                try await scheduler.withPermit(mode: .shared, label: "reader-\(index)") {
                    try await readerHold.wait()
                }
            }
        }
        var writer: Task<Void, any Error>?
        do {
            for index in 0..<4 {
                try await observer.waitUntilGranted(label: "reader-\(index)", mode: .shared)
            }
            let writerTask = Task {
                try await scheduler.withPermit(mode: .exclusive, label: "writer") {}
            }
            writer = writerTask
            try await observer.waitUntilQueued(label: "writer", mode: .exclusive)
            #expect(await observer.events.filter { $0.phase == .granted }.count == 4)
            await readerHold.open()
            _ = try await withOwnershipDeadline(
                onTimeout: {
                    writerTask.cancel()
                    await readerHold.open()
                }
            ) {
                try await writerTask.value
            }
            for reader in readers { _ = try await reader.value }
        } catch {
            await finishSchedulerTasks(
                readers + [writer].compactMap { $0 },
                gates: [readerHold]
            )
            throw error
        }
    }

    @Test("a waiter cannot grant before its queued event is committed")
    func queuedEventPrecedesGrantDuringAdmissionReentry() async throws {
        let publication = OwnershipCheckpointGate()
        let observer = SchedulerObserver(beforeRecord: { event in
            if event.label == "writer" && event.phase == .queued {
                await publication.wait()
            }
        })
        let scheduler = RuntimeScheduler(observer: observer)
        let readerHold = AsyncGate()
        let reader = Task {
            try await scheduler.withPermit(mode: .shared, label: "reader") {
                try await readerHold.wait()
            }
        }
        var writer: Task<Void, any Error>?
        do {
            try await observer.waitUntilGranted(label: "reader", mode: .shared)
            let writerTask = Task {
                try await scheduler.withPermit(mode: .exclusive, label: "writer") {}
            }
            writer = writerTask
            try await publication.waitUntilParked()
            await readerHold.open()
            _ = try await reader.value
            let unpublishedEvents = await observer.events
            #expect(!unpublishedEvents.contains { $0.label == "writer" && $0.phase == .granted })
            await publication.open()
            _ = try await withOwnershipDeadline(
                onTimeout: {
                    writerTask.cancel()
                    await publication.open()
                }
            ) {
                try await writerTask.value
            }
            let events = await observer.events
            let queued = events.firstIndex { $0.label == "writer" && $0.phase == .queued }
            let granted = events.firstIndex { $0.label == "writer" && $0.phase == .granted }
            #expect(queued != nil)
            #expect(granted != nil)
            if let queued, let granted { #expect(queued < granted) }
        } catch {
            await finishSchedulerTasks(
                [reader] + [writer].compactMap { $0 },
                gates: [readerHold],
                checkpoints: [publication]
            )
            throw error
        }
    }

    @Test("cancellation during queued publication cannot become a grant")
    func cancellationDuringQueuedPublicationRemainsQueuedCancellation() async throws {
        let publication = OwnershipCheckpointGate()
        let observer = SchedulerObserver(beforeRecord: { event in
            if event.label == "cancelled" && event.phase == .queued {
                await publication.wait()
            }
        })
        let scheduler = RuntimeScheduler(observer: observer)
        let activeHold = AsyncGate()
        let active = Task {
            try await scheduler.withPermit(mode: .exclusive, label: "active") {
                try await activeHold.wait()
            }
        }
        var cancelled: Task<Void, any Error>?
        do {
            try await observer.waitUntilGranted(label: "active", mode: .exclusive)
            let cancelledTask = Task {
                try await scheduler.withPermit(mode: .shared, label: "cancelled") {}
            }
            cancelled = cancelledTask
            try await publication.waitUntilParked()
            cancelledTask.cancel()
            try await observer.waitUntilCancellationRequested(
                label: "cancelled",
                mode: .shared
            )
            await activeHold.open()
            _ = try await active.value
            await publication.open()
            do {
                _ = try await withOwnershipDeadline(
                    onTimeout: {
                        cancelledTask.cancel()
                        await publication.open()
                    }
                ) {
                    try await cancelledTask.value
                }
                throw SchedulerFixtureError.cancellationWasNotObserved
            } catch is CancellationError {
            }
            let events = await observer.events.filter { $0.label == "cancelled" }
            let queued = events.firstIndex { $0.phase == .queued }
            let terminalCancellation = events.firstIndex { $0.phase == .cancelled }
            #expect(queued != nil)
            #expect(terminalCancellation != nil)
            if let queued, let terminalCancellation {
                #expect(queued < terminalCancellation)
            }
            #expect(events.filter { $0.phase == .granted }.isEmpty)
            #expect(events.filter { $0.phase == .released }.isEmpty)
        } catch {
            await finishSchedulerTasks(
                [active] + [cancelled].compactMap { $0 },
                gates: [activeHold],
                checkpoints: [publication]
            )
            throw error
        }
    }

    @Test("queued writers form a barrier for later readers")
    func queuedWriterPrecedesLaterReaders() async throws {
        let observer = SchedulerObserver()
        let scheduler = RuntimeScheduler(observer: observer)
        let readerHold = AsyncGate()
        let writerHold = AsyncGate()
        let reader = Task {
            try await scheduler.withPermit(mode: .shared, label: "initial-reader") {
                try await readerHold.wait()
            }
        }
        var writer: Task<Void, any Error>?
        var lateReaders: [Task<Void, any Error>] = []
        do {
            try await observer.waitUntilGranted(label: "initial-reader", mode: .shared)
            let writerTask = Task {
                try await scheduler.withPermit(mode: .exclusive, label: "writer") {
                    try await writerHold.wait()
                }
            }
            writer = writerTask
            try await observer.waitUntilQueued(label: "writer", mode: .exclusive)
            lateReaders = (0..<3).map { index in
                Task {
                    try await scheduler.withPermit(mode: .shared, label: "late-\(index)") {}
                }
            }
            for index in 0..<3 {
                try await observer.waitUntilQueued(label: "late-\(index)", mode: .shared)
            }
            await readerHold.open()
            try await observer.waitUntilGranted(label: "writer", mode: .exclusive)
            let beforeWriterRelease = await observer.events
            #expect(
                !beforeWriterRelease.contains {
                    $0.phase == .granted && $0.label.hasPrefix("late-")
                }
            )
            await writerHold.open()
            _ = try await (reader.value, writerTask.value)
            for lateReader in lateReaders { _ = try await lateReader.value }
            let events = await observer.events
            let writerGrant = events.firstIndex {
                $0.phase == .granted && $0.label == "writer"
            }
            for index in 0..<3 {
                let lateGrant = events.firstIndex {
                    $0.phase == .granted && $0.label == "late-\(index)"
                }
                #expect(writerGrant != nil)
                #expect(lateGrant != nil)
                if let writerGrant, let lateGrant { #expect(writerGrant < lateGrant) }
            }
        } catch {
            await finishSchedulerTasks(
                [reader] + [writer].compactMap { $0 } + lateReaders,
                gates: [readerHold, writerHold]
            )
            throw error
        }
    }

    @Test("shared transport callbacks can reenter the runtime")
    func sharedTransportCallbackReentersRuntime() async throws {
        let transport = ReentrantTransport()
        let server = RuntimeActorServer(
            locator: .fixture,
            transport: transport,
            schedulerObserver: SchedulerObserver()
        )
        await transport.install {
            _ = try await server.command(schedulerRequest("inner"))
        }
        let task = Task { _ = try await server.command(schedulerRequest("outer")) }
        do {
            _ = try await withOwnershipDeadline(onTimeout: { task.cancel() }) {
                try await task.value
            }
        } catch {
            task.cancel()
            _ = try? await task.value
            throw error
        }
        #expect(await transport.observedLabels == ["outer", "inner"])
    }

    @Test("cancellation before acquisition emits no scheduler event")
    func cancellationBeforeAcquisitionEmitsNoEvent() async throws {
        let checkpoint = OwnershipCheckpointGate()
        let observer = SchedulerObserver()
        let scheduler = RuntimeScheduler(observer: observer)
        let body = InvocationCounter()
        let task = Task {
            await checkpoint.wait()
            try await scheduler.withPermit(mode: .shared, label: "cancelled-before") {
                await body.increment()
            }
        }
        do {
            try await checkpoint.waitUntilParked()
            task.cancel()
            await checkpoint.open()
            do {
                _ = try await withOwnershipDeadline(
                    onTimeout: {
                        task.cancel()
                        await checkpoint.open()
                    }
                ) {
                    try await task.value
                }
                throw SchedulerFixtureError.cancellationWasNotObserved
            } catch is CancellationError {
            }
            #expect(await observer.events.isEmpty)
            #expect(await body.value == 0)
        } catch {
            await finishSchedulerTasks([task], checkpoints: [checkpoint])
            throw error
        }
    }

    @Test("post-grant cancellation releases exactly once before later work")
    func postGrantCancellationReleasesExactlyOnce() async throws {
        let checkpoint = OwnershipCheckpointGate()
        let observer = SchedulerObserver()
        let body = InvocationCounter()
        let scheduler = RuntimeScheduler(
            observer: observer,
            postGrantCheckpoint: { lease in
                if lease.label == "cancelled-after-grant" {
                    await checkpoint.wait()
                }
            }
        )
        let cancelled = Task {
            try await scheduler.withPermit(
                mode: .exclusive,
                label: "cancelled-after-grant"
            ) {
                await body.increment()
            }
        }
        var later: Task<Void, any Error>?
        do {
            try await observer.waitUntilGranted(
                label: "cancelled-after-grant",
                mode: .exclusive
            )
            try await checkpoint.waitUntilParked()
            cancelled.cancel()
            await checkpoint.open()
            do {
                _ = try await withOwnershipDeadline(
                    onTimeout: {
                        cancelled.cancel()
                        await checkpoint.open()
                    }
                ) {
                    try await cancelled.value
                }
                throw SchedulerFixtureError.cancellationWasNotObserved
            } catch is CancellationError {
            }
            let laterTask = Task {
                try await scheduler.withPermit(mode: .shared, label: "later") {}
            }
            later = laterTask
            _ = try await withOwnershipDeadline(onTimeout: { laterTask.cancel() }) {
                try await laterTask.value
            }
            let events = await observer.events
            let admissionID = try #require(
                events.first { $0.label == "cancelled-after-grant" }?.admissionID
            )
            let cancelledEvents = events.filter { $0.admissionID == admissionID }
            #expect(cancelledEvents.filter { $0.phase == .granted }.count == 1)
            #expect(cancelledEvents.filter { $0.phase == .released }.count == 1)
            #expect(cancelledEvents.filter { $0.phase == .cancelled }.isEmpty)
            #expect(await body.value == 0)
            let release = events.firstIndex {
                $0.label == "cancelled-after-grant" && $0.phase == .released
            }
            let laterGrant = events.firstIndex {
                $0.label == "later" && $0.phase == .granted
            }
            #expect(release != nil)
            #expect(laterGrant != nil)
            if let release, let laterGrant { #expect(release < laterGrant) }
        } catch {
            await finishSchedulerTasks(
                [cancelled] + [later].compactMap { $0 },
                checkpoints: [checkpoint]
            )
            throw error
        }
    }

    @Test("queued cancellation resumes one admission exactly once")
    func queuedCancellationResumesExactlyOnce() async throws {
        let observer = SchedulerObserver()
        let scheduler = RuntimeScheduler(observer: observer)
        let hold = AsyncGate()
        let active = Task {
            try await scheduler.withPermit(mode: .exclusive, label: "active") {
                try await hold.wait()
            }
        }
        var cancelled: Task<Void, any Error>?
        var later: Task<Void, any Error>?
        do {
            try await observer.waitUntilGranted(label: "active", mode: .exclusive)
            let cancelledTask = Task {
                try await scheduler.withPermit(mode: .shared, label: "queued-cancel") {}
            }
            cancelled = cancelledTask
            try await observer.waitUntilQueued(label: "queued-cancel", mode: .shared)
            let admissionID = try #require(
                await observer.events.first { $0.label == "queued-cancel" }?.admissionID
            )
            cancelledTask.cancel()
            do {
                _ = try await withOwnershipDeadline(
                    onTimeout: {
                        cancelledTask.cancel()
                        await hold.open()
                    }
                ) {
                    try await cancelledTask.value
                }
                throw SchedulerFixtureError.cancellationWasNotObserved
            } catch is CancellationError {
            }
            try await observer.waitUntilCancelled(label: "queued-cancel", mode: .shared)
            let laterTask = Task {
                try await scheduler.withPermit(mode: .shared, label: "later") {}
            }
            later = laterTask
            try await observer.waitUntilQueued(label: "later", mode: .shared)
            await hold.open()
            _ = try await (active.value, laterTask.value)

            let admissionEvents = await observer.events.filter {
                $0.admissionID == admissionID
            }
            #expect(admissionEvents.filter { $0.phase == .attempted }.count == 1)
            #expect(admissionEvents.filter { $0.phase == .queued }.count == 1)
            #expect(admissionEvents.filter { $0.phase == .cancelled }.count == 1)
            #expect(admissionEvents.filter { $0.phase == .granted }.isEmpty)
            #expect(admissionEvents.filter { $0.phase == .released }.isEmpty)
        } catch {
            await finishSchedulerTasks(
                [active] + [cancelled, later].compactMap { $0 },
                gates: [hold]
            )
            throw error
        }
    }

    @Test("a thrown body releases before the next grant")
    func thrownBodyReleasesBeforeNextGrant() async throws {
        let observer = SchedulerObserver()
        let scheduler = RuntimeScheduler(observer: observer)
        do {
            _ = try await scheduler.withPermit(
                mode: .exclusive,
                label: "failing"
            ) { () async throws -> Void in
                throw SchedulerFixtureError.bodyFailed
            }
            Issue.record("failing body completed")
        } catch SchedulerFixtureError.bodyFailed {
        }
        try await scheduler.withPermit(mode: .shared, label: "next") {}
        let events = await observer.events
        let release = events.firstIndex {
            $0.label == "failing" && $0.phase == .released
        }
        let nextGrant = events.firstIndex {
            $0.label == "next" && $0.phase == .granted
        }
        #expect(release != nil)
        #expect(nextGrant != nil)
        if let release, let nextGrant { #expect(release < nextGrant) }
    }
}
