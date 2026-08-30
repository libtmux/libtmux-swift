import Foundation

enum WaitWake: Sendable, Hashable {
    case output
    case scan
    case inspect
    case reattach
    case paneClosed
    case timedOut
    case connectionClosed
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

    func wait() async -> WaitWake {
        if let deadline = pending.firstIndex(of: .timedOut) {
            return pending.remove(at: deadline)
        }
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
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
