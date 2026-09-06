import Foundation
import LibTmux

struct PaneInputReservation: Sendable, Hashable {
    fileprivate let id: UUID
}

/// Process-wide exclusion for input dispatched to one endpoint and pane.
///
/// A reservation is atomic across a synchronized cohort and never queues.
/// Endpoint identity deliberately survives daemon replacement so cleanup for
/// an older run cannot overlap a reused pane id on the same route.
actor PaneRunCoordinator {
    private struct Key: Sendable, Hashable {
        let endpoint: Endpoint
        let pane: PaneID

        init(_ pane: Pane) {
            self.endpoint = pane.incarnation.endpoint
            self.pane = pane.id
        }
    }

    private var owners: [Key: UUID] = [:]
    private var keysByOwner: [UUID: Set<Key>] = [:]

    func reserve(_ panes: [Pane]) -> PaneInputReservation? {
        let keys = Set(panes.map(Key.init))
        guard !keys.isEmpty, keys.allSatisfy({ owners[$0] == nil }) else { return nil }
        let reservation = PaneInputReservation(id: UUID())
        for key in keys { owners[key] = reservation.id }
        keysByOwner[reservation.id] = keys
        return reservation
    }

    func permits(_ panes: [Pane], owner reservation: PaneInputReservation? = nil) -> Bool {
        let keys = Set(panes.map(Key.init))
        guard !keys.isEmpty else { return false }
        guard let reservation else {
            return keys.allSatisfy { owners[$0] == nil }
        }
        guard keysByOwner[reservation.id] == keys else { return false }
        return keys.allSatisfy { owners[$0] == reservation.id }
    }

    func release(_ reservation: PaneInputReservation) {
        guard let keys = keysByOwner.removeValue(forKey: reservation.id) else { return }
        for key in keys where owners[key] == reservation.id { owners[key] = nil }
    }

    func isHeld(_ pane: Pane) -> Bool {
        owners[Key(pane)] != nil
    }
}
