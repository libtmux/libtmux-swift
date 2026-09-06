import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct PaneInputReservation: Sendable, Hashable {
    fileprivate let id: UUID
}

/// Process-wide exclusion for input dispatched to one endpoint and pane.
///
/// A reservation is atomic across a synchronized cohort and never queues.
actor PaneRunCoordinator {
    private struct PhysicalSocket: Sendable, Hashable {
        let device: UInt64
        let inode: UInt64

        init?(_ path: String) {
            #if canImport(Darwin) || canImport(Glibc)
                var metadata = stat()
                let result = path.withCString { stat($0, &metadata) }
                guard result == 0 else { return nil }
                self.device = UInt64(metadata.st_dev)
                self.inode = UInt64(metadata.st_ino)
            #else
                return nil
            #endif
        }
    }

    private struct Key: Sendable, Hashable {
        let socket: PhysicalSocket
        let processID: Int
        let startedAt: Int
        let pane: PaneID

        init?(_ pane: Pane) {
            guard let socket = PhysicalSocket(pane.incarnation.socketPath) else { return nil }
            self.socket = socket
            self.processID = pane.incarnation.processID
            self.startedAt = pane.incarnation.startedAt
            self.pane = pane.id
        }
    }

    private var owners: [Key: UUID] = [:]
    private var keysByOwner: [UUID: Set<Key>] = [:]

    func reserve(_ panes: [Pane]) -> PaneInputReservation? {
        guard let keys = keys(for: panes) else { return nil }
        guard !keys.isEmpty, keys.allSatisfy({ owners[$0] == nil }) else { return nil }
        let reservation = PaneInputReservation(id: UUID())
        for key in keys { owners[key] = reservation.id }
        keysByOwner[reservation.id] = keys
        return reservation
    }

    func permits(_ panes: [Pane], owner reservation: PaneInputReservation? = nil) -> Bool {
        guard let keys = keys(for: panes) else { return false }
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
        guard let key = Key(pane) else { return false }
        return owners[key] != nil
    }

    private func keys(for panes: [Pane]) -> Set<Key>? {
        let keys = panes.compactMap(Key.init)
        guard keys.count == panes.count else { return nil }
        return Set(keys)
    }
}
