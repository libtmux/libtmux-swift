package enum AsyncGateError: Error, Sendable, Equatable {
    case timedOut
}

package actor AsyncGate {
    private var isOpen: Bool
    private var waiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiterID = 0

    package init(open: Bool = false) {
        isOpen = open
    }

    /// The default timeout is a hang detector, not a latency budget. A gate
    /// opened by a task queued behind dozens of concurrent fixtures can be
    /// seconds late without anything being wrong; a suite time limit bounds a
    /// genuine hang.
    package func wait(timeout: Duration = .seconds(30)) async throws {
        try Task.checkCancellation()
        if isOpen { return }

        let waiterID = nextWaiterID
        nextWaiterID += 1
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitWithoutTimeout(id: waiterID) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AsyncGateError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw AsyncGateError.timedOut
            }
            return result
        }
    }

    package func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters.values
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func waitWithoutTimeout(id: Int) async throws {
        try Task.checkCancellation()
        if isOpen { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: Int) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
