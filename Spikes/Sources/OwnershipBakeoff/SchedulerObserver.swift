import SpikeSupport

package enum SchedulerMode: Sendable, Equatable, Hashable {
    case shared
    case exclusive
}

package enum SchedulerEventPhase: Sendable, Equatable, Hashable {
    case attempted
    case queued
    case cancellationRequested
    case granted
    case cancelled
    case released
}

package struct SchedulerAdmissionID: Sendable, Equatable, Hashable {
    package let rawValue: Int
}

package struct SchedulerEvent: Sendable, Equatable {
    package let admissionID: SchedulerAdmissionID
    package let phase: SchedulerEventPhase
    package let label: String
    package let mode: SchedulerMode
}

package actor SchedulerObserver {
    package typealias EventCheckpoint = @Sendable (SchedulerEvent) async -> Void

    private struct EventKey: Hashable {
        let phase: SchedulerEventPhase
        let label: String
        let mode: SchedulerMode
    }

    private var recordedEvents: [SchedulerEvent] = []
    private var eventGates: [EventKey: AsyncGate] = [:]
    private let beforeRecord: EventCheckpoint?

    package init(beforeRecord: EventCheckpoint? = nil) {
        self.beforeRecord = beforeRecord
    }

    package var events: [SchedulerEvent] { recordedEvents }

    package func record(_ event: SchedulerEvent) async {
        if let beforeRecord {
            await beforeRecord(event)
        }
        recordedEvents.append(event)
        await eventGate(
            phase: event.phase,
            label: event.label,
            mode: event.mode
        ).open()
    }

    package func waitUntilQueued(label: String, mode: SchedulerMode) async throws {
        try await waitUntil(phase: .queued, label: label, mode: mode)
    }

    package func waitUntilCancelled(label: String, mode: SchedulerMode) async throws {
        try await waitUntil(phase: .cancelled, label: label, mode: mode)
    }

    package func waitUntilCancellationRequested(
        label: String,
        mode: SchedulerMode
    ) async throws {
        try await waitUntil(phase: .cancellationRequested, label: label, mode: mode)
    }

    package func waitUntilGranted(label: String, mode: SchedulerMode) async throws {
        try await waitUntil(phase: .granted, label: label, mode: mode)
    }

    package func waitUntilReleased(label: String, mode: SchedulerMode) async throws {
        try await waitUntil(phase: .released, label: label, mode: mode)
    }

    private func waitUntil(
        phase: SchedulerEventPhase,
        label: String,
        mode: SchedulerMode
    ) async throws {
        if recordedEvents.contains(where: {
            $0.phase == phase && $0.label == label && $0.mode == mode
        }) {
            return
        }
        try await eventGate(phase: phase, label: label, mode: mode).wait()
    }

    private func eventGate(
        phase: SchedulerEventPhase,
        label: String,
        mode: SchedulerMode
    ) -> AsyncGate {
        let key = EventKey(phase: phase, label: label, mode: mode)
        if let gate = eventGates[key] { return gate }
        let gate = AsyncGate()
        eventGates[key] = gate
        return gate
    }
}
