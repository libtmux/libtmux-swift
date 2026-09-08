import Foundation

enum WaitWake: Sendable, Hashable {
    case output
    case scan
    case inspect
    case reattach
    case paneClosed
    case timedOut
    case connectionClosed
    case cancelled
    case failed(TmuxError)
}

/// Coalesces bursts without discarding terminal or topology events behind them.
actor WaitDoorbell {
    private var pending: [WaitWake]
    private var waiter: CheckedContinuation<WaitWake, Never>?

    init(primed: Bool = false) {
        pending = primed ? [.scan] : []
    }

    func ring(_ event: WaitWake) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: event)
        } else if !pending.contains(event) {
            pending.append(event)
        }
    }

    /// Whether a caller is parked on the doorbell rather than running.
    ///
    /// The cancellation case reads this to wait for the park it is about to
    /// interrupt, instead of guessing how long parking takes.
    var isWaiting: Bool { waiter != nil }

    /// The next wake, or `.cancelled` if the caller is cancelled while parked.
    ///
    /// Cancellation has to reach the continuation, because nothing else will.
    /// A time limit cancels a test and then waits for it to return, so a wait
    /// that parks here and ignores cancellation does not fail the test — it
    /// holds the entire run open. One CI lane spent six hours that way.
    func wait() async -> WaitWake {
        if let deadline = pending.firstIndex(of: .timedOut) {
            return pending.remove(at: deadline)
        }
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                waiter = continuation
            }
        } onCancel: {
            // Cancellation runs outside the actor, and the parked caller can
            // only be reached from inside it.
            Task { await self.releaseParkedWaiter() }
        }
    }

    private func releaseParkedWaiter() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: .cancelled)
    }
}

extension OutputWaitSession {
    private static let topologyNotifications: Set<String> = [
        "layout-change", "session-window-changed", "unlinked-window-add",
        "unlinked-window-close", "window-add", "window-close", "window-pane-changed",
    ]

    static func pumpWaitNotifications(
        _ notifications: ControlNotificationStream,
        for paneID: PaneID,
        into doorbell: WaitDoorbell
    ) async {
        do {
            for try await notification in notifications {
                if notification.name == "output",
                    notification.arguments.hasPrefix("\(paneID.rawValue) ")
                {
                    await doorbell.ring(.output)
                } else if topologyNotifications.contains(notification.name) {
                    await doorbell.ring(.inspect)
                }
            }
            await doorbell.ring(.connectionClosed)
        } catch {
            await doorbell.ring(.failed(normalizedTmuxError(error)))
        }
    }
}
