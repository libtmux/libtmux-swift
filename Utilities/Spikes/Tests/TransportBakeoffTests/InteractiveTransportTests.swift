import Foundation
import Testing

@testable import SpikeSupport
@testable import TransportBakeoff

extension TransportBakeoffSuite {
    @Suite("interactive transport contract")
    struct InteractiveTransportTests {
        @Test(
            "framed writes reach both arbitrarily chunked streams",
            arguments: TransportKind.allCases)
        func framedWritesReachBothArbitrarilyChunkedStreams(_ kind: TransportKind) async throws {
            try await withAwaitedInteractiveTestSession(
                launcher: kind.launcher(),
                request: InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["framed-echo"],
                    environment: [:],
                    workingDirectory: nil
                )
            ) { session, standardOutput, standardError in
                let frames = [
                    frame(Array("first".utf8)), frame([0, 255, 1]),
                    frame(Array("last\n".utf8)),
                ]
                let expected = frames.flatMap { $0 }
                for frame in frames {
                    let split = max(1, frame.count / 2)
                    try await session.writeStandardInput(Array(frame[..<split]))
                    try await session.writeStandardInput(Array(frame[split...]))
                }
                try await session.finishStandardInput()
                try await session.finishStandardInput()
                do {
                    try await session.writeStandardInput([0])
                    Issue.record("write after input finish succeeded")
                } catch let error as InteractiveProcessError {
                    #expect(error == .inputFinished)
                }

                #expect(try await session.waitForTermination() == .exited(0))
                #expect(try await session.waitForTermination() == .exited(0))
                #expect(try await standardOutput.value == expected)
                #expect(try await standardError.value == expected)
            }
        }

        @Test(
            "termination while blocked is explicit and idempotent",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func terminationWhileBlockedIsExplicitAndIdempotent(_ kind: TransportKind) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupProcessGroup: Int32?
            let session = try await kind.launcher().launch(
                InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["block", marker.path],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            defer {
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForInteractiveProbeMarker(marker, session: session, kind: kind)
            cleanupProcessGroup = tree.processGroup
            let terminate = Task { try await session.terminate() }
            try await withContractDeadline(
                operation: { try await terminate.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            try await session.terminate()
            let termination = try await withContractDeadline(
                operation: { try await session.waitForTermination() },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )

            switch termination {
            case .unhandledSignal:
                break
            case .exited:
                Issue.record("termination was flattened to an ordinary exit")
            }
            try await assertInteractiveTreeExited(tree)
            cleanupProcessGroup = nil
        }

        @Test("swift-subprocess forces group shutdown after both streams close")
        func swiftSubprocessForcesGroupShutdownAfterBothStreamsClose() async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                var cleanupTree: ProbeProcessTree?
                let session = try await SwiftSubprocessInteractive().launch(
                    InteractiveProcessRequest(
                        executable: .path(try processProbePath()),
                        arguments: ["close-output-block", marker.path],
                        environment: [:],
                        workingDirectory: nil
                    )
                )
                let output = Task { try await collect(session.standardOutput) }
                let error = Task { try await collect(session.standardError) }
                defer {
                    output.cancel()
                    error.cancel()
                    if let cleanupTree { killAuthenticatedTree(cleanupTree, marker: marker) }
                    try? FileManager.default.removeItem(at: marker)
                }

                let tree = try await waitForInteractiveProbeMarker(
                    marker,
                    session: session,
                    kind: .swiftSubprocess
                )
                cleanupTree = tree
                let killOwnedTree: @Sendable () -> Void = {
                    killAuthenticatedTree(tree, marker: marker)
                }
                let standardOutput = try await withContractDeadline(
                    operation: { try await output.value },
                    onTimeout: killOwnedTree
                )
                let standardError = try await withContractDeadline(
                    operation: { try await error.value },
                    onTimeout: killOwnedTree
                )
                #expect(try processIdentifier(from: standardOutput) == tree.leader)
                #expect(standardError.isEmpty)

                let terminate = Task { try await session.terminate() }
                try await withContractDeadline(
                    operation: { try await terminate.value },
                    onTimeout: killOwnedTree
                )
                let termination = try await withContractDeadline {
                    try await session.waitForTermination()
                }
                if case .exited = termination {
                    Issue.record("blocked process returned an ordinary exit")
                }
                try await assertInteractiveTreeExited(tree)
                cleanupTree = nil
            #endif
        }

        @Test("pending terminate succeeds when process completion wins the race")
        func pendingTerminateSucceedsWhenProcessCompletionWinsTheRace() async throws {
            let state = InteractiveSessionState()
            await state.launched()
            let lifecycleMessage = Task {
                var iterator = state.lifecycleMessages.makeAsyncIterator()
                return await iterator.next()
            }
            let terminate = Task { try await state.terminate() }
            defer {
                lifecycleMessage.cancel()
                terminate.cancel()
            }

            let message = try await withContractDeadline { await lifecycleMessage.value }
            guard case .terminate = message else {
                Issue.record("terminate did not publish a lifecycle request")
                return
            }
            await state.complete(.success(.unhandledSignal(SIGKILL)))
            try await withContractDeadline { try await terminate.value }
        }

        @Test(
            "cancelled launch cleans post-spawn ownership before throwing",
            arguments: interactiveLaunchCancellationCases
        )
        func cancelledLaunchCleansPostSpawnOwnershipBeforeThrowing(
            _ cancellationCase: InteractiveLaunchCancellationCase
        ) async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                let (checkpointEvents, checkpointContinuation) = AsyncStream<Void>.makeStream()
                let checkpointGate = NonCancellationGate()
                let launcher = cancellationCase.kind.launcher {
                    checkpointContinuation.yield()
                    await checkpointGate.wait()
                }
                var cleanupTree: ProbeProcessTree?
                let launch = Task {
                    try await launcher.launch(
                        InteractiveProcessRequest(
                            executable: .path(try processProbePath()),
                            arguments: [cancellationCase.mode, marker.path],
                            environment: [:],
                            workingDirectory: nil
                        )
                    )
                }
                defer {
                    checkpointContinuation.finish()
                    if let cleanupTree {
                        killAuthenticatedLaunchOwnership(
                            cleanupTree,
                            marker: marker,
                            kind: cancellationCase.kind
                        )
                    }
                    try? FileManager.default.removeItem(at: marker)
                }

                do {
                    try await withContractDeadline {
                        for await _ in checkpointEvents { return }
                        throw ContractDeadlineError.exceeded
                    }
                    await checkpointGate.waitUntilParked()
                    let tree = try await waitForProbeMarker(marker)
                    cleanupTree = tree
                    launch.cancel()
                    await checkpointGate.open()
                    do {
                        let session = try await withContractDeadline(
                            operation: { try await launch.value },
                            onTimeout: {
                                killAuthenticatedLaunchOwnership(
                                    tree,
                                    marker: marker,
                                    kind: cancellationCase.kind
                                )
                            }
                        )
                        await cleanUpUnexpectedPublishedSession(
                            session,
                            tree: tree,
                            marker: marker,
                            kind: cancellationCase.kind
                        )
                        Issue.record("cancelled launch returned a session")
                    } catch is CancellationError {
                    }

                    let ownedProcessIdentifiers = [tree.leader, tree.descendant].filter { $0 > 0 }
                    let ownershipWasReleased = try await processRecordsBecomeAbsent(
                        ownedProcessIdentifiers,
                        within: .seconds(5)
                    )
                    #expect(ownershipWasReleased)
                    if !ownershipWasReleased {
                        killAuthenticatedLaunchOwnership(
                            tree,
                            marker: marker,
                            kind: cancellationCase.kind
                        )
                        _ = try await processRecordsBecomeAbsent(
                            ownedProcessIdentifiers,
                            within: .seconds(5)
                        )
                    }
                    if ownedProcessIdentifiers.allSatisfy(processRecordIsAbsent) {
                        cleanupTree = nil
                    }
                } catch {
                    launch.cancel()
                    await checkpointGate.open()
                    await cleanUpCancelledLaunch(
                        launch,
                        tree: cleanupTree,
                        marker: marker,
                        kind: cancellationCase.kind
                    )
                    throw error
                }
            #endif
        }

        @Test("interactive test scope awaits cleanup before rethrowing a body error")
        func interactiveTestScopeAwaitsCleanupBeforeRethrowingABodyError() async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                defer {
                    if let tree = probeProcessTree(from: marker) {
                        killAuthenticatedLaunchOwnership(
                            tree,
                            marker: marker,
                            kind: .directSpawn
                        )
                    }
                    try? FileManager.default.removeItem(at: marker)
                }

                do {
                    let _: Void = try await withContractDeadline(
                        operation: {
                            try await withAwaitedInteractiveTestSession(
                                launcher: DirectSpawnInteractive(),
                                request: InteractiveProcessRequest(
                                    executable: .path(try processProbePath()),
                                    arguments: ["block", marker.path],
                                    environment: [:],
                                    workingDirectory: nil
                                )
                            ) { session, _, _ in
                                _ = try await waitForInteractiveProbeMarker(
                                    marker,
                                    session: session,
                                    kind: .directSpawn
                                )
                                throw InjectedInteractiveTestBodyError.sentinel
                            }
                        },
                        onTimeout: {
                            if let tree = probeProcessTree(from: marker) {
                                killAuthenticatedLaunchOwnership(
                                    tree,
                                    marker: marker,
                                    kind: .directSpawn
                                )
                            }
                        }
                    )
                    Issue.record("sentinel body error did not escape the session scope")
                } catch let error as InjectedInteractiveTestBodyError {
                    #expect(error == .sentinel)
                }

                let tree = try #require(probeProcessTree(from: marker))
                let processIdentifiers = [tree.leader, tree.descendant].filter { $0 > 0 }
                #expect(
                    try await processRecordsBecomeAbsent(
                        processIdentifiers,
                        within: .seconds(1)
                    )
                )
            #endif
        }

        @Test("cancelled consumers do not own process cleanup", arguments: TransportKind.allCases)
        func cancelledConsumersDoNotOwnProcessCleanup(_ kind: TransportKind) async throws {
            try await withAwaitedInteractiveTestSession(
                launcher: kind.launcher(),
                request: InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["framed-echo"],
                    environment: [:],
                    workingDirectory: nil
                )
            ) { session, standardOutput, standardError in
                standardOutput.cancel()
                standardError.cancel()
                try await session.writeStandardInput(frame(Array("still-owned".utf8)))
                try await session.finishStandardInput()

                #expect(try await session.waitForTermination() == .exited(0))
                _ = try? await withContractDeadline { try await standardOutput.value }
                _ = try? await withContractDeadline { try await standardError.value }
            }
        }

        @Test("concurrent writes serialize whole frames", arguments: TransportKind.allCases)
        func concurrentWritesSerializeWholeFrames(_ kind: TransportKind) async throws {
            try await withAwaitedInteractiveTestSession(
                launcher: kind.launcher(),
                request: InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["framed-echo"],
                    environment: [:],
                    workingDirectory: nil
                )
            ) { session, standardOutput, standardError in
                let payloads = (0..<12).map {
                    Array("frame-\($0)-\(String(repeating: "x", count: 257))".utf8)
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for payload in payloads {
                        group.addTask { try await session.writeStandardInput(frame(payload)) }
                    }
                    try await group.waitForAll()
                }
                try await session.finishStandardInput()
                #expect(try await session.waitForTermination() == .exited(0))

                let outputFrames = try parseFrames(try await standardOutput.value)
                let errorFrames = try parseFrames(try await standardError.value)
                #expect(Set(outputFrames) == Set(payloads))
                #expect(Set(errorFrames) == Set(payloads))
                #expect(outputFrames.count == payloads.count)
                #expect(errorFrames.count == payloads.count)
            }
        }

        @Test(
            "natural exit completes wait without finishing stdin", arguments: TransportKind.allCases
        )
        func naturalExitCompletesWaitWithoutFinishingStdin(_ kind: TransportKind) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupLeader: Int32?
            let session = try await kind.launcher().launch(
                InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["exit-marker", marker.path, "23"],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            defer {
                if let cleanupLeader { _ = kill(cleanupLeader, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForInteractiveProbeMarker(marker, session: session, kind: kind)
            cleanupLeader = tree.leader
            #expect(
                try await withContractDeadline(
                    operation: { try await session.waitForTermination() },
                    onTimeout: { _ = kill(tree.leader, SIGKILL) }
                ) == .exited(23)
            )
            try await waitForProcessRecordAbsence(tree.leader)
            #expect(processRecordIsAbsent(tree.leader))
            if processRecordIsAbsent(tree.leader) { cleanupLeader = nil }
        }

        @Test(
            "terminate remains responsive during a full-pipe write",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func terminateRemainsResponsiveDuringAFullPipeWrite(_ kind: TransportKind) async throws {
            let markerDirectory = try makeMarkerDirectory()
            let marker = markerDirectory.appendingPathComponent("ownership")
            let inputReady = markerDirectory.appendingPathComponent("input-ready")
            var cleanupProcessGroup: Int32?
            let session = try await kind.launcher().launch(
                InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["block-input-after-byte", marker.path, inputReady.path],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            defer {
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: markerDirectory)
            }
            let tree = try await waitForInteractiveProbeMarker(marker, session: session, kind: kind)
            cleanupProcessGroup = tree.processGroup
            let writer = Task {
                try await session.writeStandardInput([UInt8](repeating: 0x61, count: 1024 * 1024))
            }
            defer { writer.cancel() }
            _ = try await waitForInteractiveProbeMarker(
                inputReady,
                session: session,
                kind: kind
            )
            let terminate = Task { try await session.terminate() }
            try await withContractDeadline(
                operation: { try await terminate.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            _ = try? await withContractDeadline(
                operation: { try await writer.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            let status = try await withContractDeadline(
                operation: { try await session.waitForTermination() },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            if case .unhandledSignal = status {
            } else {
                Issue.record("blocked process did not report signal termination")
            }
            try await assertInteractiveTreeExited(tree)
            cleanupProcessGroup = nil
        }

        @Test(
            "finish terminate and wait race resumes once",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func finishTerminateAndWaitRaceResumesOnce(_ kind: TransportKind) async throws {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            var cleanupProcessGroup: Int32?
            let session = try await kind.launcher().launch(
                InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["block", marker.path],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            defer {
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: marker)
            }
            let tree = try await waitForInteractiveProbeMarker(marker, session: session, kind: kind)
            cleanupProcessGroup = tree.processGroup
            let finish = Task { try await session.finishStandardInput() }
            let terminate = Task { try await session.terminate() }
            let wait = Task { try await session.waitForTermination() }
            _ = try? await withContractDeadline(
                operation: { try await finish.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            _ = try? await withContractDeadline(
                operation: { try await terminate.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            _ = try await withContractDeadline(
                operation: { try await wait.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )
            try await assertInteractiveTreeExited(tree)
            cleanupProcessGroup = nil
        }

        @Test("Foundation interactive termination leaves its descendant alive")
        func foundationInteractiveTerminationLeavesItsDescendantAlive() async throws {
            let observation = try await observeFoundationInteractiveDisqualification()

            #expect(observation.leaderReaped)
            #expect(observation.descendantSurvived)
            #expect(observation.descendantCleaned)
        }

        @Test("direct stdin EPIPE cannot signal the host")
        func directStdinEPIPECannotSignalTheHost() async throws {
            let helper = try sacrificialProbePath()
            let markerDirectory = try makeMarkerDirectory()
            let marker = markerDirectory.appendingPathComponent("ownership")
            var cleanupProcessGroup: Int32?
            let task = Task {
                try await FoundationProcessTransport().run(
                    ProcessRequest(
                        executable: .path(helper),
                        arguments: [],
                        environment: [
                            "LIBTMUX_PROCESS_PROBE": try processProbePath(),
                            "LIBTMUX_SIGPIPE_MARKER": marker.path,
                        ],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: markerDirectory)
            }
            let tree = try await waitForNestedProbeMarker(
                marker,
                in: markerDirectory,
                cancelOuter: { task.cancel() },
                waitForOuter: { _ = try await task.value }
            )
            cleanupProcessGroup = tree.processGroup
            let reply = try await withContractDeadline(
                operation: { try await task.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )

            #expect(reply.termination == .exited(0))
            #expect(reply.standardError.isEmpty)
            #expect(tree.leader == tree.processGroup)
            try await waitForProcessRecordAbsence(tree.leader)
            #expect(processRecordIsAbsent(tree.leader))
            if processRecordIsAbsent(tree.leader) { cleanupProcessGroup = nil }
        }

        @Test("outer marker timeout cannot strand the nested process group")
        func outerMarkerTimeoutCannotStrandTheNestedProcessGroup() async throws {
            #if os(Linux)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                let marker = root.appendingPathComponent("ownership")
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false
                )
                var cleanupProcessIdentifiers: [Int32] = []
                let task = Task {
                    try await FoundationProcessTransport().run(
                        ProcessRequest(
                            executable: .path(try sacrificialProbePath()),
                            arguments: ["delayed-marker"],
                            environment: [
                                "LIBTMUX_PROCESS_PROBE": try processProbePath(),
                                "LIBTMUX_SIGPIPE_MARKER": marker.path,
                            ],
                            workingDirectory: nil,
                            outputPolicy: .complete
                        )
                    )
                }
                defer {
                    task.cancel()
                    for processIdentifier in cleanupProcessIdentifiers
                    where processIsRunning(processIdentifier)
                        && processHasExactArgument(processIdentifier, marker.path)
                    {
                        _ = kill(-processIdentifier, SIGKILL)
                    }
                    try? FileManager.default.removeItem(at: root)
                }

                cleanupProcessIdentifiers = try await discoverNestedProbeProcesses(
                    withExactArgument: marker.path,
                    count: 1,
                    within: .seconds(5),
                    marker: marker,
                    in: root,
                    cancelOuter: { task.cancel() },
                    waitForOuter: { _ = try await task.value }
                )
                do {
                    _ = try await waitForNestedProbeMarker(
                        marker,
                        in: root,
                        within: .milliseconds(50),
                        cancelOuter: { task.cancel() },
                        waitForOuter: { _ = try await task.value }
                    )
                    Issue.record("delayed marker unexpectedly became readable")
                } catch is ContractFixtureError {
                }
                let cleaned = try await processRecordsBecomeAbsent(
                    cleanupProcessIdentifiers,
                    within: .seconds(1)
                )
                #expect(cleaned)
                if !cleaned {
                    for processIdentifier in cleanupProcessIdentifiers
                    where processIsRunning(processIdentifier)
                        && processHasExactArgument(processIdentifier, marker.path)
                    {
                        _ = kill(-processIdentifier, SIGKILL)
                    }
                }
                for processIdentifier in cleanupProcessIdentifiers {
                    try await waitForProcessRecordAbsence(processIdentifier)
                }
                _ = try? await withContractDeadline { try await task.value }
                if cleanupProcessIdentifiers.allSatisfy(processRecordIsAbsent) {
                    cleanupProcessIdentifiers = []
                }
            #endif
        }

        @Test("direct EPIPE preserves a pre-existing pending SIGPIPE")
        func directEPIPEPreservesAPreExistingPendingSIGPIPE() async throws {
            let task = Task {
                try await FoundationProcessTransport().run(
                    ProcessRequest(
                        executable: .path(try sacrificialProbePath()),
                        arguments: ["pending-sigpipe"],
                        environment: [:],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            defer { task.cancel() }
            let reply = try await withContractDeadline { try await task.value }

            #expect(reply.termination == .exited(0))
            #expect(reply.standardOutput.isEmpty)
            #expect(reply.standardError.isEmpty)
        }

        @Test("direct EPIPE does not wait when SIGPIPE is ignored")
        func directEPIPEDoesNotWaitWhenSIGPIPEIsIgnored() async throws {
            let task = Task {
                try await FoundationProcessTransport().run(
                    ProcessRequest(
                        executable: .path(try sacrificialProbePath()),
                        arguments: ["ignored-sigpipe"],
                        environment: [:],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            defer { task.cancel() }
            let reply = try await withContractDeadline { try await task.value }

            #expect(reply.termination == .exited(0))
            #expect(reply.standardOutput.isEmpty)
            #expect(reply.standardError.isEmpty)
        }

        @Test("Foundation stdin EPIPE remains terminable")
        func foundationStdinEPIPERemainsTerminable() async throws {
            let markerDirectory = try makeMarkerDirectory()
            let marker = markerDirectory.appendingPathComponent("ownership")
            var cleanupProcessGroup: Int32?
            let task = Task {
                try await DirectSpawnTransport().run(
                    ProcessRequest(
                        executable: .path(try sacrificialProbePath()),
                        arguments: ["foundation-epipe"],
                        environment: [
                            "LIBTMUX_PROCESS_PROBE": try processProbePath(),
                            "LIBTMUX_SIGPIPE_MARKER": marker.path,
                        ],
                        workingDirectory: nil,
                        outputPolicy: .complete
                    )
                )
            }
            defer {
                task.cancel()
                if let cleanupProcessGroup { _ = kill(-cleanupProcessGroup, SIGKILL) }
                try? FileManager.default.removeItem(at: markerDirectory)
            }
            let tree = try await waitForNestedProbeMarker(
                marker,
                in: markerDirectory,
                cancelOuter: { task.cancel() },
                waitForOuter: { _ = try await task.value }
            )
            cleanupProcessGroup = tree.processGroup
            let reply = try await withContractDeadline(
                operation: { try await task.value },
                onTimeout: { _ = kill(-tree.processGroup, SIGKILL) }
            )

            #expect(reply.termination == .exited(0))
            #expect(reply.standardError.isEmpty)
            try await waitForProcessRecordAbsence(tree.leader)
            try await waitForProcessRecordAbsence(tree.processGroup)
            #expect(processRecordIsAbsent(tree.leader))
            #expect(processRecordIsAbsent(tree.processGroup))
            if processRecordIsAbsent(tree.leader), processRecordIsAbsent(tree.processGroup) {
                cleanupProcessGroup = nil
            }
        }

        @Test("swift-subprocess body error kills its owned process group")
        func swiftSubprocessBodyErrorKillsItsOwnedProcessGroup() async throws {
            #if os(Linux)
                let markerDirectory = try makeMarkerDirectory()
                let marker = markerDirectory.appendingPathComponent("ownership")
                var cleanupTree: ProbeProcessTree?
                let task = Task {
                    try await FoundationProcessTransport().run(
                        ProcessRequest(
                            executable: .path(try sacrificialProbePath()),
                            arguments: ["swift-subprocess-epipe"],
                            environment: [
                                "LIBTMUX_PROCESS_PROBE": try processProbePath(),
                                "LIBTMUX_SIGPIPE_MARKER": marker.path,
                            ],
                            workingDirectory: nil,
                            outputPolicy: .complete
                        )
                    )
                }
                defer {
                    task.cancel()
                    if let cleanupTree { killAuthenticatedTree(cleanupTree, marker: marker) }
                    try? FileManager.default.removeItem(at: markerDirectory)
                }
                let tree = try await waitForNestedProbeMarker(
                    marker,
                    in: markerDirectory,
                    cancelOuter: { task.cancel() },
                    waitForOuter: { _ = try await task.value }
                )
                cleanupTree = tree
                let killOwnedTree: @Sendable () -> Void = {
                    killAuthenticatedTree(tree, marker: marker)
                }
                let reply = try await withContractDeadline(
                    operation: { try await task.value },
                    onTimeout: killOwnedTree
                )
                if reply.termination != .exited(0) { killOwnedTree() }

                #expect(reply.termination == .exited(0))
                #expect(reply.standardError.isEmpty)
                try await assertInteractiveTreeExited(tree)
                cleanupTree = nil
            #endif
        }

        @Test("swift-subprocess spawn failures close the owned input pipe")
        func swiftSubprocessSpawnFailuresCloseTheOwnedInputPipe() async throws {
            let request = InteractiveProcessRequest(
                executable: .path("/missing-libtmux-swift-interactive-probe"),
                arguments: [],
                environment: [:],
                workingDirectory: nil
            )
            _ = try? await SwiftSubprocessInteractive().launch(request)
            let before = try descriptorSnapshot()
            let beforeCounts = transportDescriptorCounts(from: before)
            for _ in 0..<32 {
                do {
                    _ = try await SwiftSubprocessInteractive().launch(request)
                    Issue.record("missing executable unexpectedly launched")
                } catch {
                }
            }
            let immediate = try descriptorSnapshot()
            let settled = try await leakRelevantDescriptorsReturn(to: beforeCounts)
            let settledCounts = transportDescriptorCounts(from: settled)
            let evidence =
                "baseline [\(beforeCounts); \(before)]; immediate [\(immediate)]; "
                + "settled [\(settledCounts); \(settled)]"
            #expect(
                settledCounts.doesNotExceed(beforeCounts),
                Comment(rawValue: evidence)
            )
        }

        @Test("swift-subprocess repeated sessions bound descriptors")
        func swiftSubprocessRepeatedSessionsBoundDescriptors() async throws {
            try await assertRepeatedSessionsAreBounded(.swiftSubprocess)
        }

        @Test("Foundation repeated sessions bound descriptors")
        func foundationRepeatedSessionsBoundDescriptors() async throws {
            try await assertRepeatedSessionsAreBounded(.foundation)
        }

        @Test("direct spawn repeated sessions bound descriptors")
        func directSpawnRepeatedSessionsBoundDescriptors() async throws {
            try await assertRepeatedSessionsAreBounded(.directSpawn)
        }

        @Test("transport descriptor oracle detects a held pipe")
        func transportDescriptorOracleDetectsAHeldPipe() throws {
            let before = try transportDescriptorCounts()
            let heldPipe = try makeCLOEXECPipe()
            defer { closePipe(heldPipe) }

            let whileHeld = try transportDescriptorCounts()

            #expect(whileHeld.pipeCount == before.pipeCount + 2)
            #expect(whileHeld.socketCount == before.socketCount)
            #expect(whileHeld.processDescriptorCount == before.processDescriptorCount)
        }

        @Test("transport descriptor oracle detects a held other-class descriptor")
        func transportDescriptorOracleDetectsAHeldOtherClassDescriptor() throws {
            let before = try transportDescriptorCounts()
            let heldDescriptor = try openCLOEXECAboveStandardDescriptors("/dev/null")
            defer { closePipe([heldDescriptor]) }

            let whileHeld = try transportDescriptorCounts()

            #expect(whileHeld.otherCount == before.otherCount + 1)
        }

        @Test("transport descriptor oracle excludes exact runtime descriptors")
        func transportDescriptorOracleExcludesExactRuntimeDescriptors() {
            #expect(descriptorTargetClass("anon_inode:[eventfd]") == .runtime)
            #expect(descriptorTargetClass("anon_inode:[eventpoll]") == .runtime)
            #expect(descriptorTargetClass("anon_inode:[timerfd]") == .runtime)
            #expect(descriptorTargetClass("anon_inode:[pidfd]") == .processDescriptor)
            #expect(descriptorTargetClass("pipe:[123]") == .pipe)
            #expect(descriptorTargetClass("socket:[456]") == .socket)
            #expect(descriptorTargetClass("anon_inode:[eventfd-extra]") == .other)
            #expect(descriptorTargetClass("<live-unresolved>") == .other)
        }

        private func assertRepeatedSessionsAreBounded(_ kind: TransportKind) async throws {
            var processIdentifiers: [Int32] = []
            for _ in 0..<32 {
                processIdentifiers.append(try await runTrackedEmptyInteractiveSession(kind))
            }
            let before = try descriptorSnapshot()
            let beforeCounts = transportDescriptorCounts(from: before)
            for batch in 1...3 {
                for _ in 0..<16 {
                    processIdentifiers.append(try await runTrackedEmptyInteractiveSession(kind))
                }
                let immediate = try descriptorSnapshot()
                let immediateCounts = transportDescriptorCounts(from: immediate)
                let settled = try await leakRelevantDescriptorsReturn(to: beforeCounts)
                let settledCounts = transportDescriptorCounts(from: settled)
                let evidence =
                    "baseline [\(beforeCounts); \(before)]; batch \(batch) "
                    + "immediate [\(immediateCounts); \(immediate)]; "
                    + "settled [\(settledCounts); \(settled)]"
                #expect(
                    settledCounts.doesNotExceed(beforeCounts),
                    Comment(rawValue: evidence)
                )
            }
            #expect(processIdentifiers.allSatisfy(processRecordIsAbsent))
        }
        @Test(
            "marker publication failure reaps the session tree", arguments: TransportKind.allCases
        )
        func markerPublicationFailureReapsTheSessionTree(_ kind: TransportKind) async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            let ownershipMarker = root.appendingPathComponent("ownership")
            let invalidMarker = root.appendingPathComponent("marker-directory")
            try FileManager.default.createDirectory(
                at: invalidMarker, withIntermediateDirectories: true)
            var cleanupTree: ProbeProcessTree?
            let session = try await kind.launcher().launch(
                InteractiveProcessRequest(
                    executable: .path(try processProbePath()),
                    arguments: ["marker-write-failure", ownershipMarker.path, invalidMarker.path],
                    environment: [:],
                    workingDirectory: nil
                )
            )
            let output = Task { try await collect(session.standardOutput) }
            let error = Task { try await collect(session.standardError) }
            defer {
                output.cancel()
                error.cancel()
                if let cleanupTree {
                    if kind == .foundation {
                        if processIsRunning(cleanupTree.leader) {
                            _ = kill(cleanupTree.leader, SIGKILL)
                        }
                        if processIsRunning(cleanupTree.descendant) {
                            _ = kill(cleanupTree.descendant, SIGKILL)
                        }
                    } else if processIsRunning(cleanupTree.leader)
                        || processIsRunning(cleanupTree.descendant)
                    {
                        _ = kill(-cleanupTree.processGroup, SIGKILL)
                    }
                }
                try? FileManager.default.removeItem(at: root)
            }

            let tree = try await waitForInteractiveProbeMarker(
                ownershipMarker,
                session: session,
                kind: kind
            )
            cleanupTree = tree
            do {
                _ = try await waitForInteractiveProbeMarker(
                    invalidMarker,
                    session: session,
                    kind: kind,
                    within: .milliseconds(100)
                )
                Issue.record("invalid marker unexpectedly became readable")
            } catch is ContractFixtureError {
            }
            #expect(try await session.waitForTermination() == .exited(64))
            _ = try await (output.value, error.value)
            try await waitForProcessRecordAbsence(tree.leader)
            try await waitForProcessRecordAbsence(tree.descendant)
            #expect(processRecordIsAbsent(tree.leader))
            #expect(processRecordIsAbsent(tree.descendant))
            if processRecordIsAbsent(tree.leader), processRecordIsAbsent(tree.descendant) {
                cleanupTree = nil
            }
        }

        @Test("pre-publication timeout cannot strand a descendant")
        func prePublicationTimeoutCannotStrandADescendant() async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                let token = marker.path
                var cleanupProcessIdentifiers: [Int32] = []
                let session = try await FoundationInteractive().launch(
                    InteractiveProcessRequest(
                        executable: .path(try processProbePath()),
                        arguments: ["pre-marker-block", token],
                        environment: [:],
                        workingDirectory: nil
                    )
                )
                let output = Task { try await collect(session.standardOutput) }
                let error = Task { try await collect(session.standardError) }
                defer {
                    output.cancel()
                    error.cancel()
                    for processIdentifier in cleanupProcessIdentifiers
                    where processIsRunning(processIdentifier)
                        && processHasExactArgument(processIdentifier, token)
                    {
                        _ = kill(processIdentifier, SIGKILL)
                    }
                    try? FileManager.default.removeItem(at: marker)
                }

                cleanupProcessIdentifiers = try await discoverPrePublicationProcesses(
                    withExactArgument: token,
                    count: 2,
                    within: .seconds(5),
                    session: session,
                    output: output,
                    standardError: error
                )
                do {
                    _ = try await waitForInteractiveProbeMarker(
                        marker,
                        session: session,
                        kind: .foundation,
                        within: .milliseconds(100)
                    )
                    Issue.record("unpublished marker unexpectedly became readable")
                } catch is ContractFixtureError {
                }
                #expect(
                    try await processRecordsBecomeAbsent(
                        cleanupProcessIdentifiers,
                        within: .seconds(1)
                    )
                )
                _ = try await (output.value, error.value)
                if cleanupProcessIdentifiers.allSatisfy(processRecordIsAbsent) {
                    cleanupProcessIdentifiers = []
                }
            #endif
        }

        @Test("pre-publication discovery failure cleans the session")
        func prePublicationDiscoveryFailureCleansTheSession() async throws {
            #if os(Linux)
                let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                let token = marker.path
                let session = try await FoundationInteractive().launch(
                    InteractiveProcessRequest(
                        executable: .path(try processProbePath()),
                        arguments: ["pre-marker-block", token],
                        environment: [:],
                        workingDirectory: nil
                    )
                )
                let output = Task { try await collect(session.standardOutput) }
                let error = Task { try await collect(session.standardError) }
                defer {
                    output.cancel()
                    error.cancel()
                    try? FileManager.default.removeItem(at: marker)
                }

                do {
                    _ = try await discoverPrePublicationProcesses(
                        withExactArgument: token,
                        count: 3,
                        within: .milliseconds(50),
                        session: session,
                        output: output,
                        standardError: error
                    )
                    Issue.record("impossible process count unexpectedly appeared")
                } catch is ContractDeadlineError {
                }
                let stranded = processIdentifiers(withExactArgument: token)
                #expect(stranded.isEmpty)
                _ = try? await withContractDeadline { try await session.terminate() }
                for processIdentifier in processIdentifiers(withExactArgument: token) {
                    _ = kill(processIdentifier, SIGKILL)
                }
                _ = try? await withContractDeadline { try await session.waitForTermination() }
                for processIdentifier in stranded {
                    try? await waitForProcessRecordAbsence(processIdentifier)
                }
                _ = try? await withContractDeadline { try await output.value }
                _ = try? await withContractDeadline { try await error.value }
            #endif
        }

        @Test("nested discovery failure quarantines before cancellation")
        func nestedDiscoveryFailureQuarantinesBeforeCancellation() async throws {
            #if os(Linux)
                let root = try makeMarkerDirectory()
                let marker = root.appendingPathComponent("ownership")
                let task = Task {
                    try await FoundationProcessTransport().run(
                        ProcessRequest(
                            executable: .path(try sacrificialProbePath()),
                            arguments: ["delayed-marker"],
                            environment: [
                                "LIBTMUX_PROCESS_PROBE": try processProbePath(),
                                "LIBTMUX_SIGPIPE_MARKER": marker.path,
                            ],
                            workingDirectory: nil,
                            outputPolicy: .complete
                        )
                    )
                }
                defer {
                    task.cancel()
                    try? FileManager.default.removeItem(at: root)
                }

                do {
                    _ = try await discoverNestedProbeProcesses(
                        withExactArgument: marker.path,
                        count: 2,
                        within: .milliseconds(50),
                        marker: marker,
                        in: root,
                        cancelOuter: { task.cancel() },
                        waitForOuter: { _ = try await task.value }
                    )
                    Issue.record("impossible process count unexpectedly appeared")
                } catch is ContractDeadlineError {
                }
                let stranded = processIdentifiers(withExactArgument: marker.path)
                #expect(stranded.isEmpty)
                _ = try? await waitForNestedProbeMarker(
                    marker,
                    in: root,
                    within: .zero,
                    cancelOuter: { task.cancel() },
                    waitForOuter: { _ = try await task.value }
                )
                for processIdentifier in stranded {
                    try? await waitForProcessRecordAbsence(processIdentifier)
                }
            #endif
        }
    }
}

private func withAwaitedInteractiveTestSession<Result>(
    launcher: any InteractiveProcessLauncher,
    request: InteractiveProcessRequest,
    body: (
        any InteractiveProcessSession,
        Task<[UInt8], any Error>,
        Task<[UInt8], any Error>
    ) async throws -> Result
) async throws -> Result {
    let session = try await launcher.launch(request)
    let standardOutput = Task { try await collect(session.standardOutput) }
    let standardError = Task { try await collect(session.standardError) }
    do {
        return try await body(session, standardOutput, standardError)
    } catch {
        let cleanup = Task.detached {
            try? await session.terminate()
            _ = try? await session.waitForTermination()
        }
        await cleanup.value
        standardOutput.cancel()
        standardError.cancel()
        _ = try? await withContractDeadline { try await standardOutput.value }
        _ = try? await withContractDeadline { try await standardError.value }
        throw error
    }
}

private func assertInteractiveTreeExited(_ tree: ProbeProcessTree) async throws {
    #expect(tree.leader == tree.processGroup)
    try await waitForProcessRecordAbsence(tree.leader)
    try await waitForProcessRecordAbsence(tree.descendant)
    #expect(processRecordIsAbsent(tree.leader))
    #expect(processRecordIsAbsent(tree.descendant))
}

#if os(Linux)
    private func killAuthenticatedTree(_ tree: ProbeProcessTree, marker: URL) {
        let ownedProcessRemains = [tree.leader, tree.descendant].contains { processIdentifier in
            processIsRunning(processIdentifier)
                && processHasExactArgument(processIdentifier, marker.path)
        }
        if ownedProcessRemains { _ = kill(-tree.processGroup, SIGKILL) }
    }

    private func killAuthenticatedLaunchOwnership(
        _ tree: ProbeProcessTree?,
        marker: URL,
        kind: TransportKind
    ) {
        let processIdentifiers =
            tree.map { [$0.leader, $0.descendant] }
            ?? processIdentifiers(withExactArgument: marker.path)
        let authenticated = processIdentifiers.filter { processIdentifier in
            processIdentifier > 0
                && processIsRunning(processIdentifier)
                && processHasExactArgument(processIdentifier, marker.path)
        }
        if kind != .foundation, let tree,
            tree.processGroup == tree.leader,
            authenticated.contains(tree.leader),
            getpgid(tree.leader) == tree.processGroup
        {
            _ = kill(-tree.processGroup, SIGKILL)
        }
        for processIdentifier in authenticated
        where processHasExactArgument(processIdentifier, marker.path) {
            _ = kill(processIdentifier, SIGKILL)
        }
    }

    private func cleanUpUnexpectedPublishedSession(
        _ session: any InteractiveProcessSession,
        tree: ProbeProcessTree?,
        marker: URL,
        kind: TransportKind
    ) async {
        let killOwnedProcesses: @Sendable () -> Void = {
            killAuthenticatedLaunchOwnership(tree, marker: marker, kind: kind)
        }
        _ = try? await withContractDeadline(
            operation: { try await session.terminate() },
            onTimeout: killOwnedProcesses
        )
        _ = try? await withContractDeadline(
            operation: { try await session.waitForTermination() },
            onTimeout: killOwnedProcesses
        )
    }

    private func cleanUpCancelledLaunch(
        _ launch: Task<any InteractiveProcessSession, any Error>,
        tree: ProbeProcessTree?,
        marker: URL,
        kind: TransportKind
    ) async {
        let killOwnedProcesses: @Sendable () -> Void = {
            killAuthenticatedLaunchOwnership(tree, marker: marker, kind: kind)
        }
        do {
            let session = try await withContractDeadline(
                operation: { try await launch.value },
                onTimeout: killOwnedProcesses
            )
            await cleanUpUnexpectedPublishedSession(
                session,
                tree: tree,
                marker: marker,
                kind: kind
            )
        } catch {
            killOwnedProcesses()
        }
    }
#endif

private func waitForInteractiveProbeMarker(
    _ marker: URL,
    session: any InteractiveProcessSession,
    kind: TransportKind,
    within duration: Duration = .seconds(5)
) async throws -> ProbeProcessTree {
    do {
        return try await waitForProbeMarker(marker, within: duration)
    } catch {
        let tree = probeProcessTree(from: marker)
        let killOwnedProcesses: @Sendable () -> Void = {
            guard let tree else { return }
            if kind == .foundation {
                if processIsRunning(tree.leader) { _ = kill(tree.leader, SIGKILL) }
                if tree.descendant > 0, processIsRunning(tree.descendant) {
                    _ = kill(tree.descendant, SIGKILL)
                }
            } else if processIsRunning(tree.leader)
                || (tree.descendant > 0 && processIsRunning(tree.descendant))
            {
                _ = kill(-tree.processGroup, SIGKILL)
            }
        }
        _ = try? await withContractDeadline(
            operation: { try await session.terminate() },
            onTimeout: killOwnedProcesses
        )
        _ = try? await withContractDeadline(
            operation: { try await session.waitForTermination() },
            onTimeout: killOwnedProcesses
        )
        if let tree {
            if kind == .foundation, tree.descendant > 0, processIsRunning(tree.descendant) {
                _ = kill(tree.descendant, SIGKILL)
            }
            try? await waitForProcessRecordAbsence(tree.leader)
            if tree.descendant > 0 {
                try? await waitForProcessRecordAbsence(tree.descendant)
            }
        }
        throw error
    }
}

private func makeMarkerDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    return directory
}

private func waitForNestedProbeMarker(
    _ marker: URL,
    in directory: URL,
    within duration: Duration = .seconds(5),
    cancelOuter: @escaping @Sendable () -> Void,
    waitForOuter: @escaping @Sendable () async throws -> Void
) async throws -> ProbeProcessTree {
    do {
        return try await waitForProbeMarker(marker, within: duration)
    } catch {
        try await quarantineAndCleanupNestedProbe(
            marker: marker,
            in: directory,
            cancelOuter: cancelOuter,
            waitForOuter: waitForOuter
        )
        throw error
    }
}

private func quarantineAndCleanupNestedProbe(
    marker: URL,
    in directory: URL,
    cancelOuter: @escaping @Sendable () -> Void,
    waitForOuter: @escaping @Sendable () async throws -> Void
) async throws {
    let quarantine = directory.deletingLastPathComponent().appendingPathComponent(
        "\(directory.lastPathComponent)-quarantine-\(UUID().uuidString)"
    )
    do {
        try FileManager.default.moveItem(at: directory, to: quarantine)
    } catch let quarantineError {
        cancelOuter()
        _ = try? await withContractDeadline { try await waitForOuter() }
        throw quarantineError
    }
    defer { try? FileManager.default.removeItem(at: quarantine) }

    let quarantinedMarker = quarantine.appendingPathComponent(marker.lastPathComponent)
    let tree = probeProcessTree(from: quarantinedMarker)
    let killOwnedProcessGroup: @Sendable () -> Void = {
        guard let tree, processIsRunning(tree.leader) else { return }
        _ = kill(-tree.processGroup, SIGKILL)
    }
    killOwnedProcessGroup()
    cancelOuter()
    _ = try? await withContractDeadline(
        operation: waitForOuter,
        onTimeout: killOwnedProcessGroup
    )
    if let tree {
        try? await waitForProcessRecordAbsence(tree.leader)
        if tree.descendant > 0 {
            try? await waitForProcessRecordAbsence(tree.descendant)
        }
    }
}

#if os(Linux)
    private func discoverPrePublicationProcesses(
        withExactArgument argument: String,
        count: Int,
        within duration: Duration,
        session: any InteractiveProcessSession,
        output: Task<[UInt8], any Error>,
        standardError: Task<[UInt8], any Error>
    ) async throws -> [Int32] {
        do {
            return try await waitForProcessIdentifiers(
                withExactArgument: argument,
                count: count,
                within: duration
            )
        } catch {
            _ = try? await withContractDeadline { try await session.terminate() }
            _ = try? await withContractDeadline { try await session.waitForTermination() }
            _ = try? await withContractDeadline { try await output.value }
            _ = try? await withContractDeadline { try await standardError.value }
            throw error
        }
    }

    private func discoverNestedProbeProcesses(
        withExactArgument argument: String,
        count: Int,
        within duration: Duration,
        marker: URL,
        in directory: URL,
        cancelOuter: @escaping @Sendable () -> Void,
        waitForOuter: @escaping @Sendable () async throws -> Void
    ) async throws -> [Int32] {
        do {
            return try await waitForProcessIdentifiers(
                withExactArgument: argument,
                count: count,
                within: duration
            )
        } catch {
            try await quarantineAndCleanupNestedProbe(
                marker: marker,
                in: directory,
                cancelOuter: cancelOuter,
                waitForOuter: waitForOuter
            )
            throw error
        }
    }

    private func waitForProcessIdentifiers(
        withExactArgument argument: String,
        count: Int,
        within duration: Duration = .seconds(5)
    ) async throws -> [Int32] {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            let identifiers = processIdentifiers(withExactArgument: argument)
            if identifiers.count == count { return identifiers }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ContractDeadlineError.exceeded
    }

    private func processIdentifiers(withExactArgument argument: String) -> [Int32] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return entries.compactMap { entry in
            guard let processIdentifier = Int32(entry),
                processHasExactArgument(processIdentifier, argument)
            else { return nil }
            return processIdentifier
        }.sorted()
    }

    private func processRecordsBecomeAbsent(
        _ processIdentifiers: [Int32],
        within duration: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            if processIdentifiers.allSatisfy(processRecordIsAbsent) { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return processIdentifiers.allSatisfy(processRecordIsAbsent)
    }
#endif

private func observeFoundationInteractiveDisqualification() async throws
    -> FoundationCancellationObservation
{
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var cleanupLeader: Int32?
    var cleanupDescendant: Int32?
    let session = try await FoundationInteractive().launch(
        InteractiveProcessRequest(
            executable: .path(try processProbePath()),
            arguments: ["block", marker.path],
            environment: [:],
            workingDirectory: nil
        )
    )
    let output = Task { try await collect(session.standardOutput) }
    let error = Task { try await collect(session.standardError) }
    defer {
        output.cancel()
        error.cancel()
        if let cleanupLeader { _ = kill(cleanupLeader, SIGKILL) }
        if let cleanupDescendant { _ = kill(cleanupDescendant, SIGKILL) }
        try? FileManager.default.removeItem(at: marker)
    }

    let tree = try await waitForInteractiveProbeMarker(
        marker,
        session: session,
        kind: .foundation
    )
    cleanupLeader = tree.leader
    cleanupDescendant = tree.descendant
    try await withContractDeadline(
        operation: { try await session.terminate() },
        onTimeout: { _ = kill(tree.leader, SIGKILL) }
    )
    try await waitForProcessExit(tree.leader)
    guard !processIsRunning(tree.leader) else { throw ContractDeadlineError.exceeded }
    let descendantSurvived = processIsRunning(tree.descendant)
    if descendantSurvived {
        _ = kill(tree.descendant, SIGKILL)
    } else if processRecordIsAbsent(tree.descendant) {
        cleanupDescendant = nil
    }
    try await waitForProcessRecordAbsence(tree.descendant)
    let descendantCleaned = processRecordIsAbsent(tree.descendant)
    if descendantCleaned { cleanupDescendant = nil }

    let termination = try await withContractDeadline(
        operation: { try await session.waitForTermination() },
        onTimeout: { _ = kill(tree.leader, SIGKILL) }
    )
    if case .exited(0) = termination {
        throw ContractFixtureError.invalidProbeReply
    }
    let standardOutput = try await withContractDeadline { try await output.value }
    let standardError = try await withContractDeadline { try await error.value }
    guard try processIdentifier(from: standardOutput) == tree.leader,
        standardError.isEmpty
    else { throw ContractFixtureError.invalidProbeReply }

    try await waitForProcessRecordAbsence(tree.leader)
    let leaderReaped = processRecordIsAbsent(tree.leader)
    if leaderReaped { cleanupLeader = nil }
    return FoundationCancellationObservation(
        leaderReaped: leaderReaped,
        descendantSurvived: descendantSurvived,
        descendantCleaned: descendantCleaned
    )
}

private func runTrackedEmptyInteractiveSession(_ kind: TransportKind) async throws -> Int32 {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var cleanupProcessIdentifier: Int32?
    let session = try await kind.launcher().launch(
        InteractiveProcessRequest(
            executable: .path(try processProbePath()),
            arguments: ["exit-marker", marker.path, "0"],
            environment: [:],
            workingDirectory: nil
        )
    )
    let output = Task { try await collect(session.standardOutput) }
    let error = Task { try await collect(session.standardError) }
    defer {
        output.cancel()
        error.cancel()
        if let cleanupProcessIdentifier {
            _ = kill(cleanupProcessIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: marker)
    }

    let tree = try await waitForInteractiveProbeMarker(marker, session: session, kind: kind)
    cleanupProcessIdentifier = tree.leader
    let termination = try await withContractDeadline(
        operation: { try await session.waitForTermination() },
        onTimeout: { _ = kill(tree.leader, SIGKILL) }
    )
    let standardOutput = try await withContractDeadline(
        operation: { try await output.value },
        onTimeout: { _ = kill(tree.leader, SIGKILL) }
    )
    let standardError = try await withContractDeadline(
        operation: { try await error.value },
        onTimeout: { _ = kill(tree.leader, SIGKILL) }
    )
    let reportedProcessIdentifier = try processIdentifier(from: standardOutput)

    #expect(termination == .exited(0))
    #expect(standardError.isEmpty)
    #expect(reportedProcessIdentifier == tree.leader)
    try await waitForProcessRecordAbsence(tree.leader)
    #expect(processRecordIsAbsent(tree.leader))
    if processRecordIsAbsent(tree.leader) { cleanupProcessIdentifier = nil }
    return tree.leader
}

func frame(_ payload: [UInt8]) -> [UInt8] {
    withUnsafeBytes(of: UInt32(payload.count).bigEndian, Array.init) + payload
}

func collect(_ stream: AsyncThrowingStream<[UInt8], any Error>) async throws -> [UInt8] {
    var bytes: [UInt8] = []
    for try await chunk in stream {
        bytes.append(contentsOf: chunk)
    }
    return bytes
}

func firstProcessIdentifier(
    from stream: AsyncThrowingStream<[UInt8], any Error>
) async throws -> Int32 {
    for try await chunk in stream {
        return try processIdentifier(from: chunk)
    }
    throw ContractFixtureError.invalidProbeReply
}

func parseFrames(_ bytes: [UInt8]) throws -> [[UInt8]] {
    var frames: [[UInt8]] = []
    var remainder = bytes[...]
    while !remainder.isEmpty {
        guard remainder.count >= 4 else { throw ContractFixtureError.invalidProbeReply }
        let length = remainder.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        remainder = remainder.dropFirst(4)
        guard remainder.count >= Int(length) else { throw ContractFixtureError.invalidProbeReply }
        frames.append(Array(remainder.prefix(Int(length))))
        remainder = remainder.dropFirst(Int(length))
    }
    return frames
}
