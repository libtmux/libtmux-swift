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
        _ notifications: AsyncStream<ControlNotification>
    ) async -> [String] {
        var seen: [String] = []
        for await notification in notifications { seen.append(notification.arguments) }
        return seen
    }

    @Test("two observers each see every notification, rather than half each")
    func observersDoNotDivideNotifications() async {
        let broadcast = NotificationBroadcast()
        let first = broadcast.subscribe()
        let second = broadcast.subscribe()
        broadcast.yield(Self.window(1))
        broadcast.yield(Self.window(2))
        broadcast.finish()

        #expect(await Self.drain(first) == ["@1", "@2"])
        #expect(await Self.drain(second) == ["@1", "@2"])
    }

    @Test("what arrived before the first observer is replayed to it alone")
    func backlogReachesTheFirstObserverOnly() async {
        let broadcast = NotificationBroadcast()
        broadcast.yield(Self.window(1))
        let first = broadcast.subscribe()
        let second = broadcast.subscribe()
        broadcast.finish()

        #expect(await Self.drain(first) == ["@1"])
        #expect(await Self.drain(second) == [])
    }

    @Test("an observer taken after a notification does not receive it")
    func laterObserverStartsWhereItSubscribed() async {
        let broadcast = NotificationBroadcast()
        let first = broadcast.subscribe()
        broadcast.yield(Self.window(1))
        let second = broadcast.subscribe()
        broadcast.yield(Self.window(2))
        broadcast.finish()

        #expect(await Self.drain(first) == ["@1", "@2"])
        // A caller that subscribes after the command it wants the answer to is
        // waiting for something already delivered.
        #expect(await Self.drain(second) == ["@2"])
    }

    @Test("an observer taken after the connection ended sees nothing and ends")
    func observerAfterFinishEndsAtOnce() async {
        let broadcast = NotificationBroadcast()
        broadcast.finish()

        #expect(await Self.drain(broadcast.subscribe()) == [])
    }
}
