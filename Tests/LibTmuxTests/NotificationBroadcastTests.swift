import Testing

@testable import LibTmux

/// What a connection's fan-out promises, without a connection.
///
/// `ControlModeTests` proves the same fan-out over a live connection. These
/// establish their ordering by construction, so they fail the same way on an
/// idle machine as on a loaded one.
@Suite("notification broadcast", .timeLimit(.minutes(1)))
struct NotificationBroadcastTests {
    private static func window(_ index: Int) -> ControlNotification {
        ControlNotification(name: "window-add", arguments: "@\(index)")
    }

    /// Every notification the stream carries, which needs the broadcast to be
    /// finished first.
    private static func drain(
        _ notifications: ControlNotificationStream
    ) async throws -> [String] {
        var seen: [String] = []
        for try await notification in notifications { seen.append(notification.arguments) }
        return seen
    }

    @Test("every observer receives every notification, rather than a share")
    func observersDoNotDivideNotifications() async throws {
        let broadcast = NotificationBroadcast()
        let first = broadcast.subscribe()
        let second = broadcast.subscribe()
        broadcast.yield(Self.window(1))
        broadcast.yield(Self.window(2))
        broadcast.finish()

        #expect(try await Self.drain(first) == ["@1", "@2"])
        #expect(try await Self.drain(second) == ["@1", "@2"])
    }

    @Test("what arrived before the first observer is replayed to it alone")
    func backlogReachesTheFirstObserverOnly() async throws {
        let broadcast = NotificationBroadcast()
        broadcast.yield(Self.window(1))
        let first = broadcast.subscribe()
        let second = broadcast.subscribe()
        broadcast.finish()

        #expect(try await Self.drain(first) == ["@1"])
        #expect(try await Self.drain(second) == [])
    }

    @Test("an observer taken after a notification does not receive it")
    func laterObserverStartsWhereItSubscribed() async throws {
        let broadcast = NotificationBroadcast()
        let first = broadcast.subscribe()
        broadcast.yield(Self.window(1))
        let second = broadcast.subscribe()
        broadcast.yield(Self.window(2))
        broadcast.finish()

        #expect(try await Self.drain(first) == ["@1", "@2"])
        // A caller that subscribes after the command it wants the answer to is
        // waiting for something already delivered.
        #expect(try await Self.drain(second) == ["@2"])
    }

    @Test("an observer taken after the connection ended sees nothing and ends")
    func observerAfterFinishEndsAtOnce() async throws {
        let broadcast = NotificationBroadcast()
        broadcast.finish()

        #expect(try await Self.drain(broadcast.subscribe()) == [])
    }

    @Test("an oversized backlog preserves its prefix and reports overflow")
    func backlogOverflowIsExplicit() async throws {
        let broadcast = NotificationBroadcast(limit: 2)
        broadcast.yield(Self.window(1))
        broadcast.yield(Self.window(2))
        broadcast.yield(Self.window(3))

        var observer = broadcast.subscribe().makeAsyncIterator()
        #expect(try await observer.next()?.arguments == "@1")
        #expect(try await observer.next()?.arguments == "@2")
        await #expect(throws: TmuxError.notificationBufferOverflow(limit: 2)) {
            try await observer.next()
        }
    }

    @Test("one slow observer cannot lose data for a peer")
    func observerOverflowIsIsolated() async throws {
        let broadcast = NotificationBroadcast(limit: 2)
        var slow = broadcast.subscribe().makeAsyncIterator()
        var peer = broadcast.subscribe().makeAsyncIterator()
        for index in 1...3 {
            broadcast.yield(Self.window(index))
            #expect(try await peer.next()?.arguments == "@\(index)")
        }
        broadcast.finish()

        #expect(try await slow.next()?.arguments == "@1")
        #expect(try await slow.next()?.arguments == "@2")
        await #expect(throws: TmuxError.notificationBufferOverflow(limit: 2)) {
            try await slow.next()
        }
    }

    @Test("subscription changes preserve notification overflow")
    func changesPreserveOverflow() async throws {
        let control = ControlSession(write: { _ in }, notificationLimit: 2)
        var changes = control.changes(named: "cmd").makeAsyncIterator()
        for value in 1...3 {
            await control.consume("%subscription-changed cmd $0 @1 0 %0 : \(value)")
        }

        #expect(try await changes.next()?.value == "1")
        #expect(try await changes.next()?.value == "2")
        await #expect(throws: TmuxError.notificationBufferOverflow(limit: 2)) {
            try await changes.next()
        }
    }
}
