import Testing

@testable import OwnershipBakeoff
@testable import SpikeSupport

enum OwnershipContender: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case runtimeActor
    case serverActor
    case stateless

    var testDescription: String { rawValue }

    func makeServer(
        transport: RecordingTransport,
        observer: SchedulerObserver
    ) -> OwnershipServerAdapter {
        switch self {
        case .runtimeActor:
            .runtimeActor(
                RuntimeActorServer(
                    locator: .fixture,
                    transport: transport,
                    schedulerObserver: observer
                )
            )
        case .serverActor:
            .serverActor(
                ServerActor(
                    locator: .fixture,
                    transport: transport,
                    schedulerObserver: observer
                )
            )
        case .stateless:
            .stateless(
                StatelessServer(
                    locator: .fixture,
                    transport: transport,
                    scheduler: RuntimeScheduler(observer: observer)
                )
            )
        }
    }
}

private enum OwnershipContractFailure: Error {
    case cancellationWasNotObserved(String)
}

enum OwnershipServerAdapter: Sendable {
    case runtimeActor(RuntimeActorServer)
    case serverActor(ServerActor)
    case stateless(StatelessServer)

    var locator: ServerLocator {
        switch self {
        case let .runtimeActor(server): server.locator
        case let .serverActor(server): server.locator
        case let .stateless(server): server.locator
        }
    }

    func command(_ request: ProcessRequest) async throws -> ProcessReply {
        switch self {
        case let .runtimeActor(server): try await server.command(request)
        case let .serverActor(server): try await server.command(request)
        case let .stateless(server): try await server.command(request)
        }
    }

    func run(_ requests: [ProcessRequest]) async throws -> [ProcessReply] {
        switch self {
        case let .runtimeActor(server): try await server.run(requests)
        case let .serverActor(server): try await server.run(requests)
        case let .stateless(server): try await server.run(requests)
        }
    }

    func child() async -> OwnershipChildAdapter {
        switch self {
        case let .runtimeActor(server): .runtimeActor(server.child())
        case let .serverActor(server): .serverActor(await server.child())
        case let .stateless(server): .stateless(server.child())
        }
    }
}

enum OwnershipChildAdapter: Sendable {
    case runtimeActor(RuntimeActorChild)
    case serverActor(ServerActorChild)
    case stateless(StatelessChild)

    func command(_ request: ProcessRequest) async throws -> ProcessReply {
        switch self {
        case let .runtimeActor(child): try await child.command(request)
        case let .serverActor(child): try await child.command(request)
        case let .stateless(child): try await child.command(request)
        }
    }
}

private func request(_ label: String) throws -> ProcessRequest {
    try ProcessRequest(
        executable: .name("ownership-probe"),
        arguments: [label],
        environment: [:],
        workingDirectory: nil,
        outputPolicy: .complete
    )
}

private func finish(
    _ tasks: [Task<Void, any Error>],
    transport: RecordingTransport
) async {
    for task in tasks { task.cancel() }
    await transport.releaseAll()
    for task in tasks { _ = try? await task.value }
}

@Suite("ownership bakeoff")
struct OwnershipContractTests {
    @Test(
        "copied servers share exclusive scheduling",
        arguments: OwnershipContender.allCases
    )
    func copiedServersShareExclusiveScheduling(_ contender: OwnershipContender) async throws {
        let transport = RecordingTransport(blockingAt: ["first"])
        let observer = SchedulerObserver()
        let server = contender.makeServer(transport: transport, observer: observer)
        let copy = server
        #expect(copy.locator == server.locator)

        let program = Task { _ = try await copy.run([request("first"), request("second")]) }
        var competing: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("first")
            let competingTask = Task { _ = try await server.command(request("competing")) }
            competing = competingTask
            try await observer.waitUntilQueued(label: "competing", mode: .shared)
            await transport.release("first")
            _ = try await (program.value, competingTask.value)
            #expect(await transport.started == ["first", "second", "competing"])
        } catch {
            await finish([program] + [competing].compactMap { $0 }, transport: transport)
            throw error
        }
    }

    @Test("exclusive programs do not interleave", arguments: OwnershipContender.allCases)
    func exclusiveProgramsDoNotInterleave(_ contender: OwnershipContender) async throws {
        let transport = RecordingTransport(blockingAt: ["first"])
        let observer = SchedulerObserver()
        let server = contender.makeServer(transport: transport, observer: observer)
        let program = Task { _ = try await server.run([request("first"), request("second")]) }
        var competing: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("first")
            let competingTask = Task { _ = try await server.command(request("competing")) }
            competing = competingTask
            try await observer.waitUntilQueued(label: "competing", mode: .shared)
            await transport.release("first")
            _ = try await (program.value, competingTask.value)
            #expect(await transport.started == ["first", "second", "competing"])
        } catch {
            await finish([program] + [competing].compactMap { $0 }, transport: transport)
            throw error
        }
    }

    @Test("independent commands overlap", arguments: OwnershipContender.allCases)
    func independentCommandsOverlap(_ contender: OwnershipContender) async throws {
        let transport = RecordingTransport(blockingAt: ["left", "right"])
        let server = contender.makeServer(transport: transport, observer: SchedulerObserver())
        let left = Task { _ = try await server.command(request("left")) }
        let right = Task { _ = try await server.command(request("right")) }
        do {
            try await transport.waitUntilStarted("left")
            try await transport.waitUntilStarted("right")
            #expect(Set(await transport.started) == Set(["left", "right"]))
            await transport.releaseAll()
            _ = try await (left.value, right.value)
        } catch {
            await finish([left, right], transport: transport)
            throw error
        }
    }

    @Test("exclusive programs are FIFO", arguments: OwnershipContender.allCases)
    func exclusiveProgramsAreFIFO(_ contender: OwnershipContender) async throws {
        let transport = RecordingTransport(blockingAt: ["reader"])
        let observer = SchedulerObserver()
        let server = contender.makeServer(transport: transport, observer: observer)
        let reader = Task { _ = try await server.command(request("reader")) }
        var first: Task<Void, any Error>?
        var second: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("reader")
            let firstTask = Task { _ = try await server.run([request("a1"), request("a2")]) }
            first = firstTask
            try await observer.waitUntilQueued(label: "a1", mode: .exclusive)
            let secondTask = Task { _ = try await server.run([request("b1"), request("b2")]) }
            second = secondTask
            try await observer.waitUntilQueued(label: "b1", mode: .exclusive)
            await transport.release("reader")
            _ = try await (reader.value, firstTask.value, secondTask.value)
            #expect(await transport.started == ["reader", "a1", "a2", "b1", "b2"])
        } catch {
            await finish(
                [reader] + [first, second].compactMap { $0 },
                transport: transport
            )
            throw error
        }
    }

    @Test("queued cancellation does not starve later work", arguments: OwnershipContender.allCases)
    func queuedCancellationDoesNotStarveLaterWork(_ contender: OwnershipContender) async throws {
        let transport = RecordingTransport(blockingAt: ["held"])
        let observer = SchedulerObserver()
        let server = contender.makeServer(transport: transport, observer: observer)
        let held = Task { _ = try await server.run([request("held")]) }
        var cancelled: Task<Void, any Error>?
        var later: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("held")
            let cancelledTask = Task { _ = try await server.command(request("cancelled")) }
            cancelled = cancelledTask
            try await observer.waitUntilQueued(label: "cancelled", mode: .shared)
            cancelledTask.cancel()
            do {
                _ = try await cancelledTask.value
                throw OwnershipContractFailure.cancellationWasNotObserved("queued waiter")
            } catch is CancellationError {
            }
            try await observer.waitUntilCancelled(label: "cancelled", mode: .shared)
            let laterTask = Task { _ = try await server.command(request("later")) }
            later = laterTask
            try await observer.waitUntilQueued(label: "later", mode: .shared)
            await transport.release("held")
            _ = try await (held.value, laterTask.value)
            #expect(await transport.started == ["held", "later"])
        } catch {
            await finish(
                [held] + [cancelled, later].compactMap { $0 },
                transport: transport
            )
            throw error
        }
    }

    @Test(
        "active cancellation releases after transport cleanup",
        arguments: OwnershipContender.allCases
    )
    func activeCancellationReleasesAfterTransportCleanup(
        _ contender: OwnershipContender
    ) async throws {
        let transport = RecordingTransport(cleanupAfterCancellationAt: "active")
        let observer = SchedulerObserver()
        let server = contender.makeServer(transport: transport, observer: observer)
        let active = Task { _ = try await server.run([request("active")]) }
        var competing: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("active")
            active.cancel()
            try await transport.waitUntilCleanupStarted("active")
            let competingTask = Task { _ = try await server.command(request("competing")) }
            competing = competingTask
            try await observer.waitUntilQueued(label: "competing", mode: .shared)
            #expect(await transport.started == ["active"])
            await transport.releaseCleanup("active")
            do {
                _ = try await active.value
                throw OwnershipContractFailure.cancellationWasNotObserved("active program")
            } catch is CancellationError {
            }
            _ = try await competingTask.value
            #expect(await transport.started == ["active", "competing"])
            let events = await observer.events
            let activeRelease = events.firstIndex {
                $0.phase == .released && $0.label == "active" && $0.mode == .exclusive
            }
            let competingGrant = events.firstIndex {
                $0.phase == .granted && $0.label == "competing" && $0.mode == .shared
            }
            #expect(activeRelease != nil)
            #expect(competingGrant != nil)
            if let activeRelease, let competingGrant {
                #expect(activeRelease < competingGrant)
            }
        } catch {
            await finish([active] + [competing].compactMap { $0 }, transport: transport)
            throw error
        }
    }

    @Test("child values share coordination", arguments: OwnershipContender.allCases)
    func childValuesShareCoordination(_ contender: OwnershipContender) async throws {
        let transport = RecordingTransport(blockingAt: ["first"])
        let observer = SchedulerObserver()
        let server = contender.makeServer(transport: transport, observer: observer)
        let child = await server.child()
        let program = Task { _ = try await server.run([request("first"), request("second")]) }
        var childCommand: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("first")
            let childTask = Task { _ = try await child.command(request("child")) }
            childCommand = childTask
            try await observer.waitUntilQueued(label: "child", mode: .shared)
            await transport.release("first")
            _ = try await (program.value, childTask.value)
            #expect(await transport.started == ["first", "second", "child"])
        } catch {
            await finish([program] + [childCommand].compactMap { $0 }, transport: transport)
            throw error
        }
    }

    @Test(
        "server and child values cross task-group boundaries",
        arguments: OwnershipContender.allCases
    )
    func serverAndChildValuesCrossTaskGroupBoundaries(
        _ contender: OwnershipContender
    ) async throws {
        let transport = RecordingTransport()
        let server = contender.makeServer(transport: transport, observer: SchedulerObserver())
        let copy = server
        let child = await server.child()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await copy.command(request("server")) }
            group.addTask { _ = try await child.command(request("child")) }
            try await group.waitForAll()
        }
        #expect(Set(await transport.started) == Set(["server", "child"]))
    }

    @Test("stateless values interleave without shared coordination")
    func statelessValuesInterleaveWithoutSharedCoordination() async throws {
        let transport = RecordingTransport(blockingAt: ["first"])
        let server = StatelessServer.uncoordinated(locator: .fixture, transport: transport)
        let copy = server
        let program = Task { _ = try await copy.run([request("first"), request("second")]) }
        var competing: Task<Void, any Error>?
        do {
            try await transport.waitUntilStarted("first")
            let competingTask = Task { _ = try await server.command(request("competing")) }
            competing = competingTask
            try await transport.waitUntilStarted("competing")
            await transport.release("first")
            _ = try await (program.value, competingTask.value)
            #expect(await transport.started == ["first", "competing", "second"])
        } catch {
            await finish([program] + [competing].compactMap { $0 }, transport: transport)
            throw error
        }
    }

    @Test("runtime actor owns an immutable capability snapshot")
    func runtimeActorOwnsAnImmutableCapabilitySnapshot() async {
        let server = RuntimeActorServer(
            locator: .fixture,
            transport: RecordingTransport(),
            schedulerObserver: SchedulerObserver()
        )
        #expect(await server.capabilities == .fixture)
    }
}
