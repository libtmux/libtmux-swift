package enum RecordingTransportError: Error, Sendable, Equatable {
    case missingLabel
    case cleanupLabelReleasedWithoutCancellation(String)
}

package actor RecordingTransport: ProcessTransport {
    private let blockingLabels: Set<String>
    private let cleanupAfterCancellationLabel: String?
    private let timeout: Duration
    private var startedLabels: [String] = []
    private var startedGates: [String: AsyncGate] = [:]
    private var releaseGates: [String: AsyncGate] = [:]
    private var cleanupStartedGates: [String: AsyncGate] = [:]
    private var cleanupReleaseGates: [String: AsyncGate] = [:]
    private var allReleased = false

    package init(
        blockingAt: Set<String> = [],
        cleanupAfterCancellationAt: String? = nil,
        timeout: Duration = .seconds(30)
    ) {
        blockingLabels = blockingAt
        cleanupAfterCancellationLabel = cleanupAfterCancellationAt
        self.timeout = timeout
    }

    package var started: [String] { startedLabels }

    package func run(_ request: ProcessRequest) async throws -> ProcessReply {
        guard let label = request.arguments.first else {
            throw RecordingTransportError.missingLabel
        }
        startedLabels.append(label)
        await startedGate(for: label).open()

        if blockingLabels.contains(label) || cleanupAfterCancellationLabel == label {
            do {
                try await releaseGate(for: label).wait(timeout: timeout)
                try Task.checkCancellation()
                if cleanupAfterCancellationLabel == label {
                    throw RecordingTransportError.cleanupLabelReleasedWithoutCancellation(label)
                }
            } catch is CancellationError {
                if cleanupAfterCancellationLabel == label {
                    await cleanupStartedGate(for: label).open()
                    let cleanupGate = cleanupReleaseGate(for: label)
                    let cleanupTimeout = timeout
                    let cleanup = Task.detached {
                        try await cleanupGate.wait(timeout: cleanupTimeout)
                    }
                    try await cleanup.value
                }
                throw CancellationError()
            }
        } else {
            try Task.checkCancellation()
        }
        return ProcessReply(
            standardOutput: [],
            standardError: [],
            termination: .exited(0)
        )
    }

    package func waitUntilStarted(_ label: String) async throws {
        try await startedGate(for: label).wait(timeout: timeout)
    }

    package func release(_ label: String) async {
        await releaseGate(for: label).open()
    }

    package func releaseAll() async {
        allReleased = true
        let gates = Array(releaseGates.values) + Array(cleanupReleaseGates.values)
        for gate in gates {
            await gate.open()
        }
    }

    package func waitUntilCleanupStarted(_ label: String) async throws {
        try await cleanupStartedGate(for: label).wait(timeout: timeout)
    }

    package func releaseCleanup(_ label: String) async {
        await cleanupReleaseGate(for: label).open()
    }

    private func startedGate(for label: String) -> AsyncGate {
        if let gate = startedGates[label] { return gate }
        let gate = AsyncGate()
        startedGates[label] = gate
        return gate
    }

    private func releaseGate(for label: String) -> AsyncGate {
        if let gate = releaseGates[label] { return gate }
        let gate = AsyncGate(open: allReleased)
        releaseGates[label] = gate
        return gate
    }

    private func cleanupStartedGate(for label: String) -> AsyncGate {
        if let gate = cleanupStartedGates[label] { return gate }
        let gate = AsyncGate()
        cleanupStartedGates[label] = gate
        return gate
    }

    private func cleanupReleaseGate(for label: String) -> AsyncGate {
        if let gate = cleanupReleaseGates[label] { return gate }
        let gate = AsyncGate(open: allReleased)
        cleanupReleaseGates[label] = gate
        return gate
    }
}
