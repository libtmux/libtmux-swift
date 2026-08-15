private actor AdmissionSignal {
    private enum Outcome {
        case pending
        case granted(RuntimeLease)
        case cancelled
    }

    private var outcome: Outcome = .pending
    private var continuation: CheckedContinuation<RuntimeLease, any Error>?

    func wait() async throws -> RuntimeLease {
        switch outcome {
        case .pending:
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        case let .granted(lease):
            return lease
        case .cancelled:
            throw CancellationError()
        }
    }

    func grant(_ lease: RuntimeLease) {
        guard case .pending = outcome else { return }
        outcome = .granted(lease)
        continuation?.resume(returning: lease)
        continuation = nil
    }

    func cancel() {
        guard case .pending = outcome else { return }
        outcome = .cancelled
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

package struct RuntimeLease: Sendable, Equatable {
    package let admissionID: SchedulerAdmissionID
    package let label: String
    package let mode: SchedulerMode
}

package actor RuntimeScheduler {
    package typealias PostGrantCheckpoint = @Sendable (RuntimeLease) async -> Void

    private struct Waiter {
        let lease: RuntimeLease
        let signal: AdmissionSignal
        var isPublished: Bool
        var cancellationRequested: Bool
    }

    private let observer: SchedulerObserver
    private let postGrantCheckpoint: PostGrantCheckpoint?
    private var nextAdmissionID = 0
    private var activeShared = 0
    private var activeExclusive = false
    private var isScheduling = false
    private var waiters: [Waiter] = []

    package init(
        observer: SchedulerObserver,
        postGrantCheckpoint: PostGrantCheckpoint? = nil
    ) {
        self.observer = observer
        self.postGrantCheckpoint = postGrantCheckpoint
    }

    package func withPermit<Value: Sendable>(
        mode: SchedulerMode,
        label: String,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        let lease = try await acquire(mode: mode, label: label)
        do {
            if let postGrantCheckpoint {
                await postGrantCheckpoint(lease)
            }
            try Task.checkCancellation()
            let value = try await operation()
            await release(lease)
            return value
        } catch {
            await release(lease)
            throw error
        }
    }

    private func acquire(mode: SchedulerMode, label: String) async throws -> RuntimeLease {
        try Task.checkCancellation()
        let lease = RuntimeLease(
            admissionID: SchedulerAdmissionID(rawValue: nextAdmissionID),
            label: label,
            mode: mode
        )
        nextAdmissionID += 1

        if !isScheduling && waiters.isEmpty && canGrant(mode) {
            markGranted(mode)
            await observer.record(event(for: lease, phase: .attempted))
            await observer.record(event(for: lease, phase: .granted))
            return lease
        }

        let signal = AdmissionSignal()
        return try await withTaskCancellationHandler {
            waiters.append(
                Waiter(
                    lease: lease,
                    signal: signal,
                    isPublished: false,
                    cancellationRequested: false
                )
            )
            await observer.record(event(for: lease, phase: .attempted))
            await observer.record(event(for: lease, phase: .queued))
            await publishQueuedAdmission(lease.admissionID)
            return try await signal.wait()
        } onCancel: {
            Task { await self.requestCancellation(lease.admissionID) }
        }
    }

    private func release(_ lease: RuntimeLease) async {
        switch lease.mode {
        case .shared:
            guard activeShared > 0 else { return }
            activeShared -= 1
        case .exclusive:
            guard activeExclusive else { return }
            activeExclusive = false
        }
        await observer.record(event(for: lease, phase: .released))
        await scheduleWaiters()
    }

    private func requestCancellation(_ admissionID: SchedulerAdmissionID) async {
        let index = waiters.firstIndex { $0.lease.admissionID == admissionID }
        guard let index else { return }
        guard waiters[index].isPublished else {
            waiters[index].cancellationRequested = true
            await observer.record(
                event(for: waiters[index].lease, phase: .cancellationRequested)
            )
            return
        }
        let waiter = waiters.remove(at: index)
        await observer.record(event(for: waiter.lease, phase: .cancelled))
        await waiter.signal.cancel()
        await scheduleWaiters()
    }

    private func publishQueuedAdmission(_ admissionID: SchedulerAdmissionID) async {
        let index = waiters.firstIndex { $0.lease.admissionID == admissionID }
        guard let index else { return }
        if waiters[index].cancellationRequested {
            let waiter = waiters.remove(at: index)
            await observer.record(event(for: waiter.lease, phase: .cancelled))
            await waiter.signal.cancel()
            await scheduleWaiters()
            return
        }
        waiters[index].isPublished = true
        await scheduleWaiters()
    }

    private func scheduleWaiters() async {
        guard !isScheduling, !activeExclusive, let first = waiters.first,
            first.isPublished
        else {
            return
        }
        isScheduling = true
        switch first.lease.mode {
        case .exclusive:
            guard activeShared == 0 else {
                isScheduling = false
                return
            }
            let waiter = waiters.removeFirst()
            activeExclusive = true
            await observer.record(event(for: waiter.lease, phase: .granted))
            await waiter.signal.grant(waiter.lease)
        case .shared:
            var sharedWaiters: [Waiter] = []
            while waiters.first?.lease.mode == .shared && waiters.first?.isPublished == true {
                sharedWaiters.append(waiters.removeFirst())
            }
            activeShared += sharedWaiters.count
            for waiter in sharedWaiters {
                await observer.record(event(for: waiter.lease, phase: .granted))
            }
            for waiter in sharedWaiters {
                await waiter.signal.grant(waiter.lease)
            }
        }
        isScheduling = false
        await scheduleWaiters()
    }

    private func canGrant(_ mode: SchedulerMode) -> Bool {
        switch mode {
        case .shared: !activeExclusive
        case .exclusive: !activeExclusive && activeShared == 0
        }
    }

    private func markGranted(_ mode: SchedulerMode) {
        switch mode {
        case .shared: activeShared += 1
        case .exclusive: activeExclusive = true
        }
    }

    private func event(
        for lease: RuntimeLease,
        phase: SchedulerEventPhase
    ) -> SchedulerEvent {
        SchedulerEvent(
            admissionID: lease.admissionID,
            phase: phase,
            label: lease.label,
            mode: lease.mode
        )
    }
}
