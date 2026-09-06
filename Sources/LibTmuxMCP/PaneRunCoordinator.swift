import Foundation
import LibTmux

/// One `run_shell_command` per pane at a time.
///
/// Shared by every ``TmuxTools`` in the process, because the README and the
/// embedding example both build one at the point of use: an instance property
/// would give two requests two coordinators and let both drive the same pane.
/// Keyed by pane and daemon incarnation, so a reused pane id on a replacement
/// server is a different pane. The exclusion is process-local — a second
/// process embedding these tools is not held by it.
actor PaneRunCoordinator {
    private struct Key: Sendable, Hashable {
        let pane: PaneID
        let incarnation: ServerIncarnation

        init(_ pane: Pane) {
            self.pane = pane.id
            self.incarnation = pane.incarnation
        }
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var held: Set<Key> = []
    private var waiters: [Key: [Waiter]] = [:]

    func isHeld(_ pane: Pane) -> Bool {
        held.contains(Key(pane))
    }

    func acquire(_ pane: Pane) async throws {
        let key = Key(pane)
        try Task.checkCancellation()
        if held.insert(key).inserted { return }

        let token = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters[key, default: []].append(
                        Waiter(token: token, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(key, token: token) }
        }
        guard granted else { throw TmuxError.cancelled }
        if Task.isCancelled {
            release(key)
            throw TmuxError.cancelled
        }
    }

    func release(_ pane: Pane) {
        release(Key(pane))
    }

    private func release(_ key: Key) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters[key] = nil
            held.remove(key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.continuation.resume(returning: true)
    }

    private func cancel(_ key: Key, token: UUID) {
        guard var queued = waiters[key],
            let index = queued.firstIndex(where: { $0.token == token })
        else { return }
        let waiter = queued.remove(at: index)
        waiters[key] = queued.isEmpty ? nil : queued
        waiter.continuation.resume(returning: false)
    }
}
