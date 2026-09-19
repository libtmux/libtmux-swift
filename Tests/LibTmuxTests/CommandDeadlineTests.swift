import Foundation
import Testing

@testable import LibTmux

/// Never observes cancellation, which a transport a consumer wrote may not.
private struct UncooperativeTransport: ProcessTransport {
    let work: Duration

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let deadline = ContinuousClock.now.advanced(by: work)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
    }
}

/// Each way a command leaves a ``Server``. A path that skips the bound is a
/// call that never returns once a daemon stops answering.
enum DispatchPath: String, CaseIterable, Sendable {
    case either, ownProcess, launchEnvironment, isolated, isolatedExpecting
    case isolatedGuarding, terminating, guarded
}

enum DispatchMode: String, CaseIterable, Sendable {
    case direct, connected
}

@Suite("command deadline", .hangLimit)
struct CommandDeadlineTests {
    private func bounded(_ transport: any ProcessTransport, _ bound: Duration) throws -> Server {
        try Server(
            socketPath: "/tmp/libtmux-swift-test/deadline-contract/socket",
            transport: transport
        ).withTimeout(bound)
    }

    @Test("a bound holds even when the transport ignores cancellation")
    func boundHoldsAgainstAnUncooperativeTransport() async throws {
        let bound = Duration.milliseconds(250)
        let server = try bounded(UncooperativeTransport(work: .seconds(3)), bound)
        let started = ContinuousClock.now

        var reported: Duration?
        do {
            _ = try await server.run(TmuxCommand("display-message"))
        } catch {
            if case let .timedOut(after) = error { reported = after }
        }

        // The bound is the claim. A transport that never checks cancellation
        // is exactly what it has to hold against: the cooperative case needs
        // no bound to return.
        let elapsed = started.duration(to: .now)
        #expect(reported != nil, "expected a timeout, took \(elapsed)")
        #expect(elapsed < .seconds(1), "bounded call took \(elapsed)")
    }

    @Test("a timeout never names a duration the call did not wait")
    func timeoutNamesWhatItActuallyWaited() async throws {
        let bound = Duration.milliseconds(250)
        let server = try bounded(UncooperativeTransport(work: .seconds(3)), bound)
        let started = ContinuousClock.now

        var reported: Duration?
        do {
            _ = try await server.run(TmuxCommand("display-message"))
        } catch {
            if case let .timedOut(after) = error { reported = after }
        }
        let elapsed = started.duration(to: .now)

        let named = try #require(reported)
        // Reporting 250ms after blocking for three seconds is a false
        // statement about what happened, whatever the bound was.
        #expect(elapsed < named + .milliseconds(500), "named \(named), took \(elapsed)")
    }

    @Test(
        "a bound holds on every dispatch path, in both modes",
        arguments: DispatchPath.allCases, DispatchMode.allCases
    )
    func boundHoldsOnEveryDispatchPath(path: DispatchPath, mode: DispatchMode) async throws {
        let bound = Duration.milliseconds(100)
        let socket = "/tmp/libtmux-swift-test/deadline-paths/socket"
        let endpoint = try Endpoint(socketPath: socket)
        var server = Server(endpoint: endpoint, transport: NeverAnsweringTransport())
        if mode == .connected {
            // Attached, and then silent: every write is accepted and nothing
            // is ever answered.
            let control = ControlSession(write: { _ in })
            await control.consume("%begin 1 1 0")
            await control.consume("%end 1 1 0")
            server = Server(server, dispatchingOver: control, attachedTo: "probe")
        }
        let bounded = server.withTimeout(bound)

        let incarnation = ServerIncarnation(
            endpoint: endpoint, socketPath: socket, processID: 1, startedAt: 1)
        let pane = Pane(
            id: "%1", index: 0, width: 80, height: 24, isActive: true, isDead: false,
            isInputOff: false, modeCount: 0, isSynchronized: false, currentCommand: "sh",
            currentPath: "/", windowID: "@1", incarnation: incarnation)
        let command = TmuxCommand("display-message")
        let extent = PaneCaptureBounds(
            historySize: 0, historyBytes: 0, paneHeight: 24, cursorRow: 0)

        // The outer deadline only ends a path that has none of its own, so
        // which bound the error names is the whole assertion.
        await #expect(throws: TmuxError.timedOut(after: bound)) {
            try await withCommandDeadline(.seconds(2)) {
                switch path {
                case .either:
                    _ = try await bounded.run(command)
                case .ownProcess:
                    _ = try await bounded.runInOwnProcess(rawArguments: command.argumentVector)
                case .launchEnvironment:
                    _ = try await bounded.run(command, launchEnvironment: [:])
                case .isolated:
                    _ = try await bounded.runIsolated(command, perStreamOutputLimit: 1_024)
                case .isolatedExpecting:
                    _ = try await bounded.runIsolated(
                        command, expecting: incarnation, perStreamOutputLimit: 1_024)
                case .isolatedGuarding:
                    _ = try await bounded.runIsolated(
                        command, guarding: pane, matching: extent, perStreamOutputLimit: 1_024)
                case .terminating:
                    _ = try await bounded.runTerminatingIsolated(
                        command, expecting: incarnation, perStreamOutputLimit: 1_024)
                case .guarded:
                    _ = try await bounded.runGuarded(command, by: [.pane(pane)])
                }
            }
        }
    }
}
