import Foundation

private let fixtureCapacity = TmuxFixtureCapacity(
    limit: max(4, min(8, (ProcessInfo.processInfo.activeProcessorCount + 1) / 2))
)

private enum TmuxFixtureContext {
    @TaskLocal static var lease: TmuxFixtureLease?
}

func withTmuxFixtureCapacity<Result>(
    _ operation: () async throws -> Result
) async throws -> Result {
    if let lease = TmuxFixtureContext.lease, await lease.retain() {
        do {
            let result = try await operation()
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }
    try await fixtureCapacity.acquire()
    let lease = TmuxFixtureLease(capacity: fixtureCapacity)
    return try await TmuxFixtureContext.$lease.withValue(lease) {
        do {
            let result = try await operation()
            await lease.closeOwner()
            return result
        } catch {
            await lease.closeOwner()
            throw error
        }
    }
}

private actor TmuxFixtureLease {
    private let capacity: TmuxFixtureCapacity
    private var ownerIsActive = true
    private var users = 1

    init(capacity: TmuxFixtureCapacity) {
        self.capacity = capacity
    }

    func retain() -> Bool {
        guard ownerIsActive else { return false }
        users += 1
        return true
    }

    func release() async {
        precondition(users > 0)
        users -= 1
        if users == 0 { await capacity.release() }
    }

    func closeOwner() async {
        precondition(ownerIsActive)
        ownerIsActive = false
        await release()
    }
}

private actor TmuxFixtureCapacity {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = limit
        self.available = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        guard available == 0 else {
            available -= 1
            return
        }

        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        guard granted else { throw CancellationError() }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            precondition(available < limit)
            available += 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
