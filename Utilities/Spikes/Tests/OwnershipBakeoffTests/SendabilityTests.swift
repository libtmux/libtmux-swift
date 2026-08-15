import Testing

@testable import OwnershipBakeoff
@testable import SpikeSupport

private func requireSendable<Value: Sendable>(_ value: Value) {
    _ = value
}

@Suite("ownership sendability")
struct SendabilityTests {
    @Test("servers and value children satisfy Sendable")
    func serversAndChildrenAreSendable() async {
        let runtimeServer = RuntimeActorServer(
            locator: .fixture,
            transport: RecordingTransport(),
            schedulerObserver: SchedulerObserver()
        )
        let actorServer = ServerActor(
            locator: .fixture,
            transport: RecordingTransport(),
            schedulerObserver: SchedulerObserver()
        )
        let statelessServer = StatelessServer(
            locator: .fixture,
            transport: RecordingTransport(),
            scheduler: RuntimeScheduler(observer: SchedulerObserver())
        )

        requireSendable(runtimeServer)
        requireSendable(actorServer)
        requireSendable(statelessServer)
        requireSendable(runtimeServer.child())
        requireSendable(await actorServer.child())
        requireSendable(statelessServer.child())
    }

    @Test("copied handles cross throwing task groups")
    func copiedHandlesCrossThrowingTaskGroups() async throws {
        let transport = RecordingTransport()
        let server = RuntimeActorServer(
            locator: .fixture,
            transport: transport,
            schedulerObserver: SchedulerObserver()
        )
        let copy = server
        let child = server.child()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await copy.command(sendabilityRequest("server"))
            }
            group.addTask {
                _ = try await child.command(sendabilityRequest("child"))
            }
            try await group.waitForAll()
        }
        #expect(Set(await transport.started) == Set(["server", "child"]))
    }
}

private func sendabilityRequest(_ label: String) throws -> ProcessRequest {
    try ProcessRequest(
        executable: .name("ownership-probe"),
        arguments: [label],
        environment: [:],
        workingDirectory: nil,
        outputPolicy: .complete
    )
}
