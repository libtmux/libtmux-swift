import Foundation
import Testing

@testable import FixtureBakeoff
@testable import PtyClientProbe
@testable import SpikeSupport
@testable import TransportBakeoff

#if canImport(Darwin)
    import Darwin
    import os
#else
    import Glibc
    import Synchronization
#endif

private enum BootstrapChildTestError: Error {
    case posix(operation: String, code: Int32)
}

private final class BootstrapSignalRecorder: Sendable {
    #if canImport(Darwin)
        private let signals = OSAllocatedUnfairLock(initialState: [Int32]())
    #else
        private let signals = Mutex([Int32]())
    #endif

    func record(_ signal: Int32) -> Int32 {
        signals.withLock { $0.append(signal) }
        return 0
    }

    var snapshot: [Int32] {
        signals.withLock { $0 }
    }

    /// Escalation runs on the owner's own task, so a caller that samples the
    /// moment a wait throws can observe the sequence half written.
    func waitForSnapshot(
        _ expected: [Int32],
        within duration: Duration = .seconds(30)
    ) async -> [Int32] {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            let observed = snapshot
            if observed == expected { return observed }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot
    }
}

/// The owner reaps its child after the last signal it sends, so a caller that
/// samples immediately can still see the child.
private func waitForChildReaped(
    _ processIdentifier: pid_t,
    within duration: Duration = .seconds(30)
) async {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        errno = 0
        var status: Int32 = 0
        if waitpid(processIdentifier, &status, WNOHANG) == -1, errno == ECHILD {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func spawnTerminalBootstrapChild(exitCode: Int32) throws -> pid_t {
    let process = try spawnPOSIX(
        request: ProcessRequest(
            executable: .path(try processProbePath()),
            arguments: ["exit", String(exitCode)],
            environment: ["LC_ALL": "C"],
            workingDirectory: nil,
            outputPolicy: .complete
        ),
        interactive: false
    )
    _ = close(process.standardOutput)
    _ = close(process.standardError)
    if let standardInput = process.standardInput { _ = close(standardInput) }
    return process.processIdentifier
}

private func spawnPtySupervisorChild(
    executable: String,
    arguments: [String]
) throws -> pid_t {
    let process = try spawnPOSIX(
        request: ProcessRequest(
            executable: .path(executable),
            arguments: arguments,
            environment: ["LC_ALL": "C"],
            workingDirectory: nil,
            outputPolicy: .complete
        ),
        interactive: true
    )
    _ = close(process.standardOutput)
    _ = close(process.standardError)
    if let standardInput = process.standardInput { _ = close(standardInput) }
    return process.processIdentifier
}

private func pinTerminalBootstrapChildForTest(_ child: pid_t) throws {
    var information = siginfo_t()
    var result: Int32
    repeat {
        errno = 0
        result = waitid(P_PID, id_t(child), &information, WEXITED | WNOWAIT)
    } while result != 0 && errno == EINTR
    guard result == 0,
        bootstrapSignalInfoProcessIdentifierForTest(information) == child
    else {
        throw BootstrapChildTestError.posix(operation: "waitid", code: errno)
    }
}

private func bootstrapSignalInfoProcessIdentifierForTest(
    _ information: siginfo_t
) -> pid_t {
    #if os(Linux)
        information._sifields._sigchld.si_pid
    #elseif canImport(Darwin)
        information.si_pid
    #else
        0
    #endif
}

private func cleanupBootstrapChildForTest(_ child: pid_t) {
    guard child > 0 else { return }
    var status: Int32 = 0
    var waited: pid_t
    repeat {
        errno = 0
        waited = waitpid(child, &status, WNOHANG)
    } while waited < 0 && errno == EINTR
    guard waited == 0 else { return }
    _ = kill(child, SIGKILL)
    repeat {
        waited = waitpid(child, &status, 0)
    } while waited < 0 && errno == EINTR
}

private enum ClientListRequestTransportError: Error, Sendable, Equatable {
    case unexpectedRequest(ProcessRequest)
}

private actor ClientListRequestTransport: ProcessTransport {
    private let expectedRequest: ProcessRequest
    private let reply: ProcessReply
    private(set) var requestCount = 0

    init(expectedRequest: ProcessRequest, reply: ProcessReply) {
        self.expectedRequest = expectedRequest
        self.reply = reply
    }

    func run(_ request: ProcessRequest) throws -> ProcessReply {
        guard request == expectedRequest else {
            throw ClientListRequestTransportError.unexpectedRequest(request)
        }
        requestCount += 1
        return reply
    }
}

@Suite(
    "PTY client probe contract",
    .timeLimit(.minutes(1))
)
struct PtyClientProbeTests {
    @Test("terminal bootstrap observation pins the exact child for one reap")
    func terminalBootstrapObservationPinsTheExactChildForOneReap() throws {
        let child = try spawnTerminalBootstrapChild(exitCode: 23)
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupBootstrapChildForTest(child) }
        }

        let observation = try observePtyBootstrapChild(child)
        #expect(observation == .terminalPinned)

        let status = try reapPinnedPtyBootstrapChild(child)
        cleanupRequired = false
        #expect(status & 0x7f == 0)
        #expect((status >> 8) & 0xff == 23)

        errno = 0
        var secondStatus: Int32 = 0
        #expect(waitpid(child, &secondStatus, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("waitid failure never signals a child already reaped by recovery")
    func waitIDFailureNeverSignalsAChildAlreadyReapedByRecovery() throws {
        let child = try spawnTerminalBootstrapChild(exitCode: 29)
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupBootstrapChildForTest(child) }
        }
        try pinTerminalBootstrapChildForTest(child)
        let signals = BootstrapSignalRecorder()

        do {
            _ = try observePtyBootstrapChild(
                child,
                hooks: PtyBootstrapObservationHooks(
                    waitForBootstrap: { _ in .failed(EINVAL) },
                    signalChild: { _, signal in signals.record(signal) }
                )
            )
            Issue.record("injected waitid failure returned an observation")
        } catch {}

        cleanupRequired = false
        #expect(signals.snapshot.isEmpty)
        errno = 0
        var status: Int32 = 0
        #expect(waitpid(child, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("outer waitid failure never signals a child reaped by recovery")
    func outerWaitIDFailureNeverSignalsAChildReapedByRecovery() async throws {
        let signals = BootstrapSignalRecorder()
        let owner = try PtyProbeProcessOwner.launch(
            executable: try processProbePath(),
            arguments: ["exit", "31"],
            environment: ["LC_ALL": "C"],
            waitHooks: PtyProbeWaitHooks(
                observeTerminal: { child in
                    do {
                        try pinTerminalBootstrapChildForTest(child)
                        return .failed(EINVAL)
                    } catch {
                        return .failed(EIO)
                    }
                },
                signalProcess: { _, signal in signals.record(signal) }
            )
        )

        do {
            _ = try await owner.waitIfComplete(within: .seconds(30))
            Issue.record("injected outer waitid failure returned a termination")
        } catch let PtyClientContractError.waitFailed(code) {
            #expect(code == EINVAL)
        }

        #expect(signals.snapshot.isEmpty)
        errno = 0
        var status: Int32 = 0
        #expect(waitpid(owner.processIdentifier, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("outer waitid failure signals a child still pinned for recovery")
    func outerWaitIDFailureSignalsAChildStillPinnedForRecovery() async throws {
        let signals = BootstrapSignalRecorder()
        let owner = try PtyProbeProcessOwner.launch(
            executable: try processProbePath(),
            arguments: ["delayed-exit", "30000"],
            environment: ["LC_ALL": "C"],
            waitHooks: PtyProbeWaitHooks(
                observeTerminal: { _ in .failed(EINVAL) },
                signalProcess: { processIdentifier, signal in
                    _ = signals.record(signal)
                    return kill(processIdentifier, signal) == 0 ? 0 : errno
                }
            )
        )

        do {
            _ = try await owner.waitIfComplete(within: .seconds(30))
            Issue.record("injected outer waitid failure returned a termination")
        } catch let PtyClientContractError.waitFailed(code) {
            #expect(code == EINVAL)
        }

        #expect(await signals.waitForSnapshot([SIGTERM]) == [SIGTERM])
        await waitForChildReaped(owner.processIdentifier)
        errno = 0
        var status: Int32 = 0
        #expect(waitpid(owner.processIdentifier, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("outer waitid failure escalates only while its child remains pinned")
    func outerWaitIDFailureEscalatesOnlyWhileItsChildRemainsPinned() async throws {
        let signals = BootstrapSignalRecorder()
        let owner = try PtyProbeProcessOwner.launch(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            environment: ["LC_ALL": "C"],
            waitHooks: PtyProbeWaitHooks(
                observeTerminal: { _ in .failed(EINVAL) },
                signalProcess: { processIdentifier, signal in
                    _ = signals.record(signal)
                    return kill(processIdentifier, signal) == 0 ? 0 : errno
                }
            )
        )

        do {
            _ = try await owner.waitIfComplete(within: .seconds(30))
            Issue.record("injected outer waitid failure returned a termination")
        } catch let PtyClientContractError.waitFailed(code) {
            #expect(code == EINVAL)
        }

        #expect(
            await signals.waitForSnapshot([SIGTERM, SIGKILL]) == [SIGTERM, SIGKILL]
        )
        await waitForChildReaped(owner.processIdentifier)
        errno = 0
        var status: Int32 = 0
        #expect(waitpid(owner.processIdentifier, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("inner waitid failure never signals a child reaped by recovery")
    func innerWaitIDFailureNeverSignalsAChildReapedByRecovery() throws {
        let child = try spawnPtySupervisorChild(
            executable: try processProbePath(),
            arguments: ["exit", "37"]
        )
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupBootstrapChildForTest(child) }
        }
        let signals = BootstrapSignalRecorder()
        let supervisor = PtyChildSupervisor(
            master: nil,
            child: child,
            processGroup: child,
            hooks: PtyChildSupervisorHooks(
                observeTerminal: { child in
                    do {
                        try pinTerminalBootstrapChildForTest(child)
                        return .failed(EINVAL)
                    } catch {
                        return .failed(EIO)
                    }
                },
                signalProcessGroup: { _, signal in signals.record(signal) }
            )
        )

        do {
            _ = try supervisor.stopAndReap(initialSignal: SIGTERM)
            Issue.record("injected inner waitid failure returned a status")
        } catch let PtyProbeError.posix(operation, code) {
            #expect(operation == "waitid")
            #expect(code == EINVAL)
        }

        cleanupRequired = false
        #expect(signals.snapshot.isEmpty)
        errno = 0
        var status: Int32 = 0
        #expect(waitpid(child, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("inner waitid failure signals only while its child remains pinned")
    func innerWaitIDFailureSignalsOnlyWhileItsChildRemainsPinned() throws {
        let child = try spawnPtySupervisorChild(
            executable: try processProbePath(),
            arguments: ["delayed-exit", "1000"]
        )
        var cleanupRequired = true
        defer {
            if cleanupRequired { cleanupBootstrapChildForTest(child) }
        }
        let signals = BootstrapSignalRecorder()
        let supervisor = PtyChildSupervisor(
            master: nil,
            child: child,
            processGroup: child,
            hooks: PtyChildSupervisorHooks(
                observeTerminal: { _ in .failed(EINVAL) },
                signalProcessGroup: { processGroup, signal in
                    guard kill(-processGroup, signal) == 0 else { return errno }
                    if signal == SIGTERM || signal == SIGKILL {
                        do {
                            try pinTerminalBootstrapChildForTest(child)
                        } catch {
                            return EIO
                        }
                    }
                    return signals.record(signal)
                }
            )
        )

        do {
            _ = try supervisor.stopAndReap(initialSignal: SIGTERM)
            Issue.record("injected inner waitid failure returned a status")
        } catch let PtyProbeError.posix(operation, code) {
            #expect(operation == "waitid")
            #expect(code == EINVAL)
        }

        cleanupRequired = false
        #expect(signals.snapshot == [SIGTERM, SIGCONT, SIGKILL])
        errno = 0
        var status: Int32 = 0
        #expect(waitpid(child, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test("list-clients forces UTF-8 in the closed C locale")
    func listClientsForcesUTF8InTheClosedCLocale() async throws {
        let runDirectory = URL(fileURLWithPath: "/fixture/run", isDirectory: true)
        let socketDirectory = runDirectory.appendingPathComponent("socket", isDirectory: true)
        let endpoint = TmuxEndpoint.socketPath(
            socketDirectory.appendingPathComponent("tmux.sock").path
        )
        let token = UUID(uuidString: "1A031D85-44E6-4AC3-AC9B-453E103EC88E")!
        let ownershipMarker = runDirectory.appendingPathComponent("owner")
        let fixture = TmuxFixture(
            runDirectory: runDirectory,
            socketDirectory: socketDirectory,
            configurationFile: runDirectory.appendingPathComponent("tmux.conf"),
            ownershipMarker: ownershipMarker,
            ownershipRecord: FixtureOwnershipRecord(marker: ownershipMarker, token: token),
            endpoint: endpoint,
            incarnation: try ServerIncarnationID(endpoint: endpoint, token: token)
        )
        let lane = TmuxLane(
            binary: "/fixture/bin/tmux-3.2a",
            root: URL(fileURLWithPath: "/fixture", isDirectory: true),
            path: "/fixture/bin:/usr/bin:/bin",
            developerDirectory: "/fixture/developer",
            sdkRoot: "/fixture/sdk"
        )
        let transport = ClientListRequestTransport(
            expectedRequest: try ProcessRequest(
                executable: .path("/fixture/bin/tmux-3.2a"),
                arguments: [
                    "-N", "-u", "-S", "/fixture/run/socket/tmux.sock",
                    "list-clients", "-F",
                    "#{client_name}\t#{client_pid}\t#{client_tty}\t#{client_control_mode}\t#{client_width}\t#{client_height}\t#{client_session}\t#{session_id}",
                ],
                environment: [
                    "DEVELOPER_DIR": "/fixture/developer",
                    "LC_ALL": "C",
                    "PATH": "/fixture/bin:/usr/bin:/bin",
                    "SDKROOT": "/fixture/sdk",
                    "TERM": "xterm-256color",
                    "TMPDIR": "/fixture/tmp",
                ],
                workingDirectory: nil,
                outputPolicy: .complete
            ),
            reply: ProcessReply(
                standardOutput: Array(
                    "client_name_with_underscores\t43210\t"
                        .utf8
                )
                    + Array(
                        "/dev/pts/client_tty_with_underscores\t0\t101\t37\t"
                            .utf8
                    ) + Array("session_name_with_underscores\t$17\n".utf8),
                standardError: [],
                termination: .exited(0)
            )
        )
        let records = try await tmuxClients(
            lane: lane,
            fixture: fixture,
            transport: transport
        )

        #expect(
            records
                == [
                    TmuxClientRecord(
                        name: "client_name_with_underscores",
                        processIdentifier: 43_210,
                        tty: "/dev/pts/client_tty_with_underscores",
                        controlMode: 0,
                        width: 101,
                        height: 37,
                        session: "session_name_with_underscores",
                        sessionIdentifier: "$17"
                    )
                ]
        )
        #expect(await transport.requestCount == 1)
    }

    @Test("natural exit drains all trailing PTY output")
    func naturalExitDrainsAllTrailingPtyOutput() async throws {
        let byteCount = 2 * 1_024 * 1_024

        try await withRunningPtyClient(
            executable: try processProbePath(),
            arguments: ["finite-stream", "stdout", String(byteCount)],
            environment: ["LC_ALL": "C"]
        ) { client in
            let termination = try await awaitPtyTermination(client)
            let transcript = await client.transcript.snapshot()

            #expect(termination == .exited(0))
            #expect(transcript.count == byteCount)
            #expect(transcript.allSatisfy { $0 == 0x45 })
        }
    }

    @Test("tmux client environment is closed and declares its terminal")
    func tmuxClientEnvironmentIsClosedAndDeclaresItsTerminal() {
        let laneRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-pty-environment"
        )
        let scratch = laneRoot.appendingPathComponent("tmp", isDirectory: true)
        let lane = TmuxLane(
            binary: "/usr/bin/tmux",
            root: laneRoot,
            path: "/usr/bin:/bin",
            developerDirectory: "/toolchain",
            sdkRoot: "/sdk"
        )

        #expect(
            lane.childEnvironment == [
                "DEVELOPER_DIR": "/toolchain",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
                "SDKROOT": "/sdk",
                "TERM": "xterm-256color",
                "TMPDIR": scratch.path,
            ]
        )

        let laneWithoutSDKSelectors = TmuxLane(
            binary: "/usr/bin/tmux",
            root: laneRoot,
            path: "/usr/bin:/bin",
            developerDirectory: nil,
            sdkRoot: nil
        )
        #expect(
            laneWithoutSDKSelectors.childEnvironment == [
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "TMPDIR": scratch.path,
            ]
        )
    }

    @Test("blocked reader cleanup closes its descriptor and joins its task")
    func blockedReaderCleanupClosesItsDescriptorAndJoinsItsTask() async throws {
        let probe = try BlockedPtyReaderCleanupProbe.start()
        try await probe.waitUntilReading()

        let cleanup = Task {
            await probe.cancelCloseAndJoin()
        }
        try await probe.waitUntilReaderExited()

        #expect(!(await probe.cleanupReturned()))
        await probe.allowReaderToFinish()
        await cleanup.value
        #expect(await probe.cleanupReturned())
        #expect(probe.descriptorIsClosed)
    }

    @Test("probe preserves exact argv and routes PTY output to stderr")
    func probePreservesExactArgvAndRoutesPtyOutputToStderr() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-pty-shell-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let arguments = [
            "literal ; /usr/bin/touch \(marker.path)",
            "$(printf shell-substitution)",
            "'*?[client]'",
            "line one\nline two",
        ]

        try await withRunningPtyClient(
            executable: try processProbePath(),
            arguments: ["argv"] + arguments,
            environment: ["LC_ALL": "C"]
        ) { client in
            let termination = try await awaitPtyTermination(client)
            guard termination == .exited(0) else {
                throw PtyClientContractError.sessionFailed
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(
                try decodeLengthPrefixedArguments(await client.transcript.snapshot())
                    == arguments
            )
            try await requireProcessRecordsAbsent([
                client.readiness.probePID,
                client.readiness.childPID,
            ])
        }
    }

    @Test("standard-input EOF reaps a TERM-ignoring child process group")
    func standardInputEOFReapsATermIgnoringChildProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-pty-eof-\(UUID().uuidString)"
        )
        var removeMarker = false
        defer {
            if removeMarker { try? FileManager.default.removeItem(at: marker) }
        }

        try await withRunningPtyClient(
            executable: try processProbePath(),
            arguments: ["block-stubborn-descendant", marker.path],
            environment: ["LC_ALL": "C"]
        ) { client in
            let tree = try await waitForProcessMarker(marker)
            try requireOwnedProcessTree(tree, client: client)

            try client.finishStandardInput()
            let termination = try await awaitPtyTermination(client)
            #expect(termination == .exited(0))
            try await requireProcessRecordsAbsent([
                client.readiness.probePID,
                tree.leader,
                tree.descendant,
            ])
            removeMarker = true
        }
    }

    @Test(
        "external signal is mirrored after the owned process group is reaped",
        arguments: [SIGHUP, SIGINT, SIGTERM]
    )
    func externalSignalIsMirroredAfterOwnedProcessGroupIsReaped(
        _ signal: Int32
    ) async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-pty-signal-\(signal)-\(UUID().uuidString)"
        )
        var removeMarker = false
        defer {
            if removeMarker { try? FileManager.default.removeItem(at: marker) }
        }

        try await withRunningPtyClient(
            executable: try processProbePath(),
            arguments: ["block-stubborn-descendant", marker.path],
            environment: ["LC_ALL": "C"]
        ) { client in
            let tree = try await waitForProcessMarker(marker)
            try requireOwnedProcessTree(tree, client: client)

            try sendSignalToOwnedProbe(signal, client: client)
            let termination = try await awaitPtyTermination(client)
            #expect(termination == .unhandledSignal(signal))
            try await requireProcessRecordsAbsent([
                client.readiness.probePID,
                tree.leader,
                tree.descendant,
            ])
            removeMarker = true
        }
    }

    @Test("semantic readiness rejection cleans the pinned inner process group")
    func semanticReadinessRejectionCleansPinnedInnerProcessGroup() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "libtmux-pty-invalid-readiness-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: marker) }
        let owner = try PtyProbeProcessOwner.launch(
            executable: try ptyClientProbePath(),
            arguments: ptyProbeArguments(
                executable: try processProbePath(),
                arguments: ["block-stubborn-descendant", marker.path]
            ),
            environment: ["LC_ALL": "C"]
        )
        do {
            let readiness = try await owner.waitForReadiness()
            let tree = try await waitForProcessMarker(marker)
            #if os(Linux)
                #expect(try actualParentProcessIdentifier(tree.leader) == readiness.probePID)
            #endif

            var observedError: PtyClientContractError?
            do {
                try requireReadiness(
                    readiness,
                    ownerProcessIdentifier: owner.processIdentifier,
                    rows: ptyRows + 1,
                    columns: ptyColumns
                )
            } catch let error as PtyClientContractError {
                observedError = error
            }
            #expect(observedError == .invalidReadiness)

            try owner.sendSignal(SIGSTOP)
            #if os(Linux)
                try await requireStoppedProcessRecord(readiness.probePID)
            #endif
            let rejectedCleanupReadiness = PtyClientReadiness(
                protocolVersion: readiness.protocolVersion,
                probePID: readiness.probePID,
                childPID: readiness.childPID,
                childParentPID: readiness.probePID + 1,
                childProcessGroupID: readiness.childProcessGroupID,
                childWasStoppedBeforeReadiness: readiness.childWasStoppedBeforeReadiness,
                ptyPath: readiness.ptyPath,
                rows: readiness.rows,
                columns: readiness.columns
            )
            do {
                _ = try await owner.stopAndReap(readiness: rejectedCleanupReadiness)
                Issue.record("invalid readiness unexpectedly completed cleanup")
            } catch let error as PtyClientContractError {
                #expect(error == .invalidProcessRelationship)
            }
            try await requireProcessRecordsAbsent([
                readiness.probePID,
                tree.leader,
                tree.descendant,
            ])
        } catch {
            _ = try? await owner.stopAndReap(readiness: nil)
            throw error
        }
    }

    @Test("natural child exit is mirrored", arguments: 0..<16)
    func naturalChildExitIsMirrored(_ iteration: Int) async throws {
        _ = iteration
        try await withRunningPtyClient(
            executable: try processProbePath(),
            arguments: ["exit", "23"],
            environment: ["LC_ALL": "C"]
        ) { client in
            let termination = try await awaitPtyTermination(client)
            #expect(termination == .exited(23))
            try await requireProcessRecordsAbsent([
                client.readiness.probePID,
                client.readiness.childPID,
            ])
        }
    }

    @Test("natural child signal is mirrored")
    func naturalChildSignalIsMirrored() async throws {
        try await withRunningPtyClient(
            executable: try processProbePath(),
            arguments: ["signal", String(SIGUSR1)],
            environment: ["LC_ALL": "C"]
        ) { client in
            let termination = try await awaitPtyTermination(client)
            #expect(termination == .unhandledSignal(SIGUSR1))
            try await requireProcessRecordsAbsent([
                client.readiness.probePID,
                client.readiness.childPID,
            ])
        }
    }
}

@Suite("tmux PTY lane transport")
struct TmuxPtyLaneTransportTests {
    @Test("selected one-shot transport is swift-subprocess")
    func selectedOneShotTransportIsSwiftSubprocess() {
        #expect(makeSelectedTmuxTransport() is SwiftSubprocessTransport)
    }
}

@Suite(
    "real tmux PTY client",
    .timeLimit(.minutes(1))
)
struct PtyClientTests {
    @Test("list-clients reports the requested PTY dimensions")
    func listClientsReportsTheRequestedPtyDimensions() async throws {
        let lane = try authenticatedTmuxLane()
        try await withRealTmuxFixture(lane: lane) { fixture in
            try await withAttachedTmuxClient(lane: lane, fixture: fixture) {
                client,
                session in
                let record = try await waitForTmuxClient(
                    lane: lane,
                    fixture: fixture,
                    processIdentifier: client.readiness.childPID
                )
                try requireAttachedClientIdentity(record, client: client, session: session)
                #expect(record.width == ptyColumns)
                #expect(record.height == ptyRows)
                #expect(record.width > 0)
                #expect(record.height > 0)
                try await detach(
                    client,
                    record: record,
                    lane: lane,
                    fixture: fixture
                )
            }
        }
    }

    @Test("targeted display-menu waits for its label before accepting a key")
    func targetedDisplayMenuWaitsForItsLabelBeforeAcceptingAKey() async throws {
        let lane = try authenticatedTmuxLane()
        try await withRealTmuxFixture(lane: lane) { fixture in
            try await withAttachedTmuxClient(lane: lane, fixture: fixture) {
                client,
                session in
                let record = try await waitForTmuxClient(
                    lane: lane,
                    fixture: fixture,
                    processIdentifier: client.readiness.childPID
                )
                try requireAttachedClientIdentity(record, client: client, session: session)
                let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                let label = "libtmux menu \(nonce)"
                let option = "@libtmux_swift_menu_\(nonce)"
                let selection = "selected-\(nonce)"
                let menu = launchTmuxRequest(
                    lane: lane,
                    fixture: fixture,
                    arguments: [
                        "-N", "-S", try socketPath(fixture),
                        "display-menu",
                        "-c", record.name,
                        "-t", session.pane,
                        "-T", label,
                        label, "x", "set-option -s \(option) \(selection)",
                    ]
                )

                do {
                    try await waitForTerminalText(label, client: client)
                    try client.writeStandardInput(Array("x".utf8))
                    let menuReply = try await awaitTmuxRequest(menu)
                    try requireSuccessfulTmuxReply(menuReply)
                } catch {
                    await cancelAndReapTmuxRequest(menu)
                    throw error
                }
                try await waitForServerOption(
                    lane: lane,
                    fixture: fixture,
                    option: option,
                    value: selection
                )
                try await detach(
                    client,
                    record: record,
                    lane: lane,
                    fixture: fixture
                )
            }
        }
    }

    @Test("detach removes the client and leaves the fixture server alive")
    func detachRemovesTheClientAndLeavesTheFixtureServerAlive() async throws {
        let lane = try authenticatedTmuxLane()
        try await withRealTmuxFixture(lane: lane) { fixture in
            try await withAttachedTmuxClient(lane: lane, fixture: fixture) {
                client,
                session in
                let record = try await waitForTmuxClient(
                    lane: lane,
                    fixture: fixture,
                    processIdentifier: client.readiness.childPID
                )
                try requireAttachedClientIdentity(record, client: client, session: session)
                try await detach(
                    client,
                    record: record,
                    lane: lane,
                    fixture: fixture
                )
                try await waitForTmuxClientAbsence(
                    lane: lane,
                    fixture: fixture,
                    name: record.name
                )
                let reply = try await runTmux(
                    lane: lane,
                    fixture: fixture,
                    arguments: [
                        "-N", "-S", try socketPath(fixture),
                        "has-session", "-t", session.identifier,
                    ]
                )
                try requireSuccessfulTmuxReply(reply)
            }
        }
    }

    @Test("fixture cleanup terminates a still-attached PTY client")
    func fixtureCleanupTerminatesAStillAttachedPtyClient() async throws {
        let lane = try authenticatedTmuxLane()
        let tracker = PtyClientTracker()
        do {
            let client = try await withRealTmuxFixture(lane: lane) { fixture in
                let session = try await soleLiveTmuxSession(lane: lane, fixture: fixture)
                let client = try await launchAttachedTmuxClient(
                    lane: lane,
                    fixture: fixture,
                    session: session
                )
                await tracker.store(client)
                let record = try await waitForTmuxClient(
                    lane: lane,
                    fixture: fixture,
                    processIdentifier: client.readiness.childPID
                )
                try requireAttachedClientIdentity(record, client: client, session: session)
                return client
            }
            _ = try await awaitPtyTermination(client)
            try await requireProcessRecordsAbsent([
                client.readiness.probePID,
                client.readiness.childPID,
            ])
            _ = await tracker.take()
        } catch {
            if let client = await tracker.take() {
                await stopAndReapPtyClient(client)
            }
            throw error
        }
    }
}
