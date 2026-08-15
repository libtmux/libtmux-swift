import Foundation
import Testing

@testable import SpikeSupport
@testable import TransportBakeoff

private let hasTmuxLane = ProcessInfo.processInfo.environment["LIBTMUX_TMUX_BIN"] != nil

enum TmuxBoundaryError: Error {
    case missingLane
    case serverDeadline
    case clientDeadline
}

extension TransportBakeoffSuite {
    @Suite(
        "real tmux transport boundary",
        .enabled(if: hasTmuxLane, "runs inside the authenticated tmux matrix")
    )
    struct TmuxBoundaryTests {
        @Test(
            "bytes argv status and environment cross each transport",
            arguments: TransportKind.allCases)
        func bytesArgvStatusAndEnvironmentCrossEachTransport(_ kind: TransportKind) async throws {
            let executable = try tmuxExecutable()
            let transport = kind.transport()
            let version = try await transport.run(
                try tmuxRequest(executable: executable, arguments: ["-V"])
            )
            #expect(version.termination == .exited(0))
            #expect(version.standardOutput.starts(with: Array("tmux ".utf8)))

            try await withForegroundTmux(kind: kind, executable: executable) { socket, session in
                let payload = "literal ;$(false) '*?[x]'\nsecond"
                let display = try await transport.run(
                    try tmuxRequest(
                        executable: executable,
                        arguments: ["-S", socket, "display-message", "-p", "-t", session, payload]
                    )
                )
                #expect(display.standardOutput == Array("\(payload)\n".utf8))
                #expect(display.standardError.isEmpty)
                #expect(display.termination == .exited(0))

                let rejected = try await transport.run(
                    try tmuxRequest(
                        executable: executable,
                        arguments: ["-S", socket, "has-session", "-t", "missing-libtmux-session"]
                    )
                )
                if case .exited(0) = rejected.termination {
                    Issue.record("rejected tmux command reported success")
                }
                #expect(!rejected.standardError.isEmpty)

                let marker =
                    "LIBTMUX_CHILD_ONLY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                #expect(ProcessInfo.processInfo.environment[marker] == nil)
                var environment = ProcessInfo.processInfo.environment
                environment[marker] = "child-value"
                _ = try await transport.run(
                    try tmuxRequest(
                        executable: executable,
                        arguments: ["-S", socket, "display-message", "-p", "ok"],
                        environment: environment
                    )
                )
                #expect(ProcessInfo.processInfo.environment[marker] == nil)
            }
        }

        @Test(
            "blocked tmux cancellation reaps the exact client",
            arguments: [TransportKind.swiftSubprocess, .directSpawn]
        )
        func blockedTmuxCancellationReapsTheExactClient(_ kind: TransportKind) async throws {
            let executable = try tmuxExecutable()
            try await withForegroundTmux(kind: kind, executable: executable) { socket, _ in
                let channel = "libtmux-\(UUID().uuidString)"
                let task = Task {
                    try await kind.transport().run(
                        try tmuxRequest(
                            executable: executable,
                            arguments: ["-S", socket, "wait-for", channel]
                        )
                    )
                }
                defer { task.cancel() }
                let processIdentifier = try await waitForTmuxClient(
                    executable: executable,
                    socket: socket,
                    distinguishingArgument: channel
                )
                task.cancel()
                do {
                    _ = try await withContractDeadline(
                        operation: { try await task.value },
                        onTimeout: { _ = kill(-processIdentifier, SIGKILL) }
                    )
                    Issue.record("cancelled tmux client returned reply data")
                } catch is CancellationError {
                }
                try await waitForProcessRecordAbsence(processIdentifier)
                #expect(processRecordIsAbsent(processIdentifier))
            }
        }

        @Test("Foundation tmux cancellation is disqualified")
        func foundationTmuxCancellationIsDisqualified() {
            #expect(!FoundationProcessTransport.providesProcessGroupIsolation)
        }
    }
}

private func tmuxExecutable() throws -> String {
    guard let executable = ProcessInfo.processInfo.environment["LIBTMUX_TMUX_BIN"],
        executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable)
    else { throw TmuxBoundaryError.missingLane }
    return executable
}

private func tmuxRequest(
    executable: String,
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> ProcessRequest {
    try ProcessRequest(
        executable: .path(executable),
        arguments: arguments,
        environment: environment,
        workingDirectory: nil,
        outputPolicy: .complete
    )
}

private func withForegroundTmux<Result: Sendable>(
    kind: TransportKind,
    executable: String,
    body: (String, String) async throws -> Result
) async throws -> Result {
    let root =
        ProcessInfo.processInfo.environment["LIBTMUX_MATRIX_ROOT"]
        .map(URL.init(fileURLWithPath:)) ?? FileManager.default.temporaryDirectory
    let socket = root.appendingPathComponent("transport-\(UUID().uuidString).sock").path
    let sessionName = "transport-\(UUID().uuidString)"
    try? FileManager.default.removeItem(atPath: socket)
    let server = try await kind.launcher().launch(
        InteractiveProcessRequest(
            executable: .path(executable),
            arguments: ["-D", "-S", socket, "-f", "/dev/null"],
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: nil
        )
    )
    let serverOutput = Task { try await collect(server.standardOutput) }
    let serverError = Task { try await collect(server.standardError) }
    var serverProcessIdentifier: Int32?
    var paneProcessIdentifier: Int32?
    do {
        let transport = kind.transport()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var ready = false
        while ContinuousClock.now < deadline {
            let reply = try await transport.run(
                try tmuxRequest(
                    executable: executable,
                    arguments: [
                        "-N", "-S", socket, "-f", "/dev/null", "display-message", "-p",
                        "#{pid}",
                    ]
                )
            )
            if reply.termination == .exited(0),
                let processIdentifier = try? processIdentifier(from: reply.standardOutput),
                processIdentifier > 0
            {
                serverProcessIdentifier = processIdentifier
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard ready else { throw TmuxBoundaryError.serverDeadline }
        let created = try await transport.run(
            try tmuxRequest(
                executable: executable,
                arguments: [
                    "-S", socket, "new-session", "-d", "-s", sessionName, "sleep", "3600",
                ]
            )
        )
        guard created.termination == .exited(0) else { throw TmuxBoundaryError.serverDeadline }
        let panes = try await transport.run(
            try tmuxRequest(
                executable: executable,
                arguments: [
                    "-S", socket, "list-panes", "-t", sessionName, "-F", "#{pane_pid}",
                ]
            )
        )
        guard panes.termination == .exited(0),
            let ownedPane = try? processIdentifier(from: panes.standardOutput),
            ownedPane > 0
        else { throw TmuxBoundaryError.serverDeadline }
        paneProcessIdentifier = ownedPane
        let result = try await body(socket, sessionName)
        await shutDownForegroundTmux(
            kind: kind,
            executable: executable,
            socket: socket,
            server: server,
            serverProcessIdentifier: serverProcessIdentifier,
            paneProcessIdentifier: paneProcessIdentifier,
            sessionName: sessionName,
            serverOutput: serverOutput,
            serverError: serverError
        )
        try? FileManager.default.removeItem(atPath: socket)
        return result
    } catch {
        await shutDownForegroundTmux(
            kind: kind,
            executable: executable,
            socket: socket,
            server: server,
            serverProcessIdentifier: serverProcessIdentifier,
            paneProcessIdentifier: paneProcessIdentifier,
            sessionName: sessionName,
            serverOutput: serverOutput,
            serverError: serverError
        )
        try? FileManager.default.removeItem(atPath: socket)
        throw error
    }
}

private func shutDownForegroundTmux(
    kind: TransportKind,
    executable: String,
    socket: String,
    server: any InteractiveProcessSession,
    serverProcessIdentifier: Int32?,
    paneProcessIdentifier: Int32?,
    sessionName: String,
    serverOutput: Task<[UInt8], any Error>,
    serverError: Task<[UInt8], any Error>
) async {
    let killOwnedServer: @Sendable () -> Void = {
        guard let serverProcessIdentifier else { return }
        let target = kind == .foundation ? serverProcessIdentifier : -serverProcessIdentifier
        _ = kill(target, SIGKILL)
    }
    let transport = kind.transport()
    var ownedPane = paneProcessIdentifier
    if ownedPane == nil,
        let panes = try? await withContractDeadline(operation: {
            try await transport.run(
                try tmuxRequest(
                    executable: executable,
                    arguments: [
                        "-S", socket, "list-panes", "-t", sessionName, "-F", "#{pane_pid}",
                    ]
                )
            )
        }),
        panes.termination == .exited(0)
    {
        ownedPane = try? processIdentifier(from: panes.standardOutput)
    }
    _ = try? await withContractDeadline(
        operation: {
            try await transport.run(
                try tmuxRequest(
                    executable: executable,
                    arguments: ["-S", socket, "kill-session", "-t", sessionName]
                )
            )
        },
        onTimeout: killOwnedServer
    )
    if let ownedPane {
        await terminateOwnedProcess(ownedPane)
    }
    _ = try? await withContractDeadline(
        operation: { try await server.terminate() },
        onTimeout: killOwnedServer
    )
    _ = try? await withContractDeadline(
        operation: { try await server.waitForTermination() },
        onTimeout: killOwnedServer
    )
    _ = try? await withContractDeadline(
        operation: { try await serverOutput.value },
        onTimeout: killOwnedServer
    )
    _ = try? await withContractDeadline(
        operation: { try await serverError.value },
        onTimeout: killOwnedServer
    )
    if let serverProcessIdentifier {
        #expect(!processIsRunning(serverProcessIdentifier))
    }
}

private func terminateOwnedProcess(_ processIdentifier: Int32) async {
    guard processIdentifier > 0 else { return }
    if processIsRunning(processIdentifier) {
        _ = kill(processIdentifier, SIGTERM)
    }
    if !(await processExited(processIdentifier, within: .milliseconds(250))) {
        _ = kill(processIdentifier, SIGKILL)
    }
    #expect(await processExited(processIdentifier, within: .seconds(5)))
}

private func processExited(
    _ processIdentifier: Int32,
    within duration: Duration
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: duration)
    while ContinuousClock.now < deadline {
        if !processIsRunning(processIdentifier) { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return !processIsRunning(processIdentifier)
}

private func waitForTmuxClient(
    executable: String,
    socket: String,
    distinguishingArgument: String
) async throws -> Int32 {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < deadline {
        #if os(Linux)
            let taskDirectories = try FileManager.default.contentsOfDirectory(
                atPath: "/proc/self/task"
            )
            for task in taskDirectories {
                let childrenPath = "/proc/self/task/\(task)/children"
                guard let children = try? String(contentsOfFile: childrenPath, encoding: .utf8)
                else { continue }
                for field in children.split(whereSeparator: \Character.isWhitespace) {
                    guard let processIdentifier = Int32(field),
                        let commandData = try? Data(
                            contentsOf: URL(
                                fileURLWithPath: "/proc/\(processIdentifier)/cmdline"
                            )
                        )
                    else { continue }
                    let arguments = String(decoding: commandData, as: UTF8.self)
                        .split(separator: "\0").map(String.init)
                    if arguments.first == executable, arguments.contains(socket),
                        arguments.contains(distinguishingArgument)
                    {
                        return processIdentifier
                    }
                }
            }
        #endif
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TmuxBoundaryError.clientDeadline
}
