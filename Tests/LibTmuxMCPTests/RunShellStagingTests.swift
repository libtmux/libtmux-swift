import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@Suite("run shell staging", .hangLimit)
struct RunShellStagingTests {
    @Test(
        "local staging failures preserve foreign files and release input", arguments: [false, true])
    func stagingFailureDoesNotOwnPath(existingFile: Bool) async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let directory = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent(existingFile ? "script" : "missing/script")
            let foreign = Data("file belonging to another operation\n".utf8)
            if existingFile { try foreign.write(to: path) }
            let transport = PausedRunShellTransport()
            let surface = tools(fixture, transport: transport)
            let arguments = try arguments(for: pane, command: "printf 'must-not-run\\n'")

            await #expect(
                throws: TmuxError.invocationFailed(
                    reason: "run_shell_command could not stage its command")
            ) {
                try await surface.runShell(arguments, stagingAt: path.path)
            }

            #expect(await transport.inputDispatchCount == 0)
            if existingFile {
                #expect((try? Data(contentsOf: path)) == foreign)
            } else {
                #expect(!FileManager.default.fileExists(atPath: path.path))
            }
            try #require(!(await TmuxTools.paneRuns.isHeld(pane)))
            let next = try await surface.runShell(
                self.arguments(for: pane, command: "printf 'after-staging-failure\\n'")
            )
            #expect(next.structured["exitStatus"]?.intValue == 0)
            #expect(!(await TmuxTools.paneRuns.isHeld(pane)))
        }
    }

    @Test("an unsubmitted loader releases its owned file and reservation")
    func unsubmittedLoaderReleasesOwnership() async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let directory = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let path = directory.appendingPathComponent("script")
            let transport = PausedRunShellTransport(rejectFirstSubmission: true)
            let surface = tools(fixture, transport: transport)
            await #expect(throws: TmuxError.requestNotSubmitted) {
                try await surface.runShell(
                    arguments(for: pane, command: "printf 'must-not-run\\n'"),
                    stagingAt: path.path
                )
            }
            #expect(!(await transport.inputWasQueued))
            #expect(!FileManager.default.fileExists(atPath: path.path))
            try #require(!(await TmuxTools.paneRuns.isHeld(pane)))
            let next = try await surface.runShell(
                arguments(for: pane, command: "printf 'after-unsubmitted-loader\\n'")
            )
            #expect(next.structured["exitStatus"]?.intValue == 0)
        }
    }

    @Test(
        "queued shell input retains its file through interruption",
        arguments: StagedRunInterruption.allCases,
        ["/bin/bash", "/bin/sh"]
    )
    func interruptedBeforeConsumption(
        _ interruption: StagedRunInterruption,
        _ shell: String
    ) async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let directory = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let processFile = directory.appendingPathComponent("shell-pid")
            let flags = shell == "/bin/bash" ? " --noprofile --norc -i" : " -i"
            // tmux resumes stopped pane leaders. Keep the interactive shell a child.
            try await fixture.respawn(
                pane, running: ["/bin/sh", "-c", "\(shellQuoted(shell))\(flags); :"])
            try #require(
                try await waitUntil {
                    let command = try await fixture.panes().first(where: { $0.id == pane.id })?
                        .currentCommand
                    return command == "bash" || command == "sh" || command == "dash"
                }
            )
            try await fixture.sendKeys(
                ["printf '%s\\n' \"$$\" > \(shellQuoted(processFile.path))", "Enter"],
                to: pane
            )
            try #require(
                try await waitUntil {
                    (try? String(contentsOf: processFile, encoding: .utf8))?.hasSuffix("\n") == true
                }
            )
            let processText = try String(contentsOf: processFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let processID = try #require(Int32(processText))
            try #require(processID > 0)
            #expect(
                try await fixture.format("#{pane_pid}", addressing: pane.id.rawValue) != processText
            )
            defer { _ = kill(processID, SIGCONT) }
            let path = directory.appendingPathComponent("script")
            let transport = PausedRunShellTransport(
                processID: processID,
                failAfterSubmission: interruption == .ambiguousFailure
            )
            let surface = tools(fixture, transport: transport)
            let marker = "queued-run-\(UUID().uuidString)"
            let arguments = try arguments(
                for: pane,
                command: "printf '%s\\n' \(shellQuoted(marker))",
                timeoutMs: interruption == .timeout ? 1_000 : 20_000
            )
            let running = Task { try await surface.runShell(arguments, stagingAt: path.path) }
            defer { running.cancel() }
            let queued = try await waitUntil(within: .seconds(3)) { await transport.inputWasQueued }
            if !queued {
                _ = kill(processID, SIGCONT)
                running.cancel()
                do {
                    _ = try await running.value
                    Issue.record("run ended before the loader was queued")
                } catch {
                    Issue.record("loader was not queued: \(error)")
                }
            }
            try #require(queued)

            let interruptedAt = ContinuousClock.now
            switch interruption {
            case .cancel, .cancelThenTerminate:
                running.cancel()
                await #expect(throws: TmuxError.cancelled) { try await running.value }
            case .timeout:
                let outcome = try await running.value
                #expect(outcome.structured["timedOut"]?.boolValue == true)
            case .ambiguousFailure:
                await #expect(throws: TmuxError.invocationFailed(reason: "submitted reply lost")) {
                    try await running.value
                }
            }
            #expect(ContinuousClock.now - interruptedAt < .seconds(3))
            #expect(await transport.inputDispatchCount == 1)
            #expect(await TmuxTools.paneRuns.isHeld(pane))
            try #require(FileManager.default.fileExists(atPath: path.path))

            if interruption == .cancelThenTerminate {
                try await fixture.kill(pane)
                try #require(
                    try await waitUntil(within: .seconds(5)) {
                        !(await TmuxTools.paneRuns.isHeld(pane))
                            && !FileManager.default.fileExists(atPath: path.path)
                    }
                )
                return
            }

            #expect(kill(processID, SIGCONT) == 0)
            try #require(
                try await waitUntil(within: .seconds(5)) {
                    !(await TmuxTools.paneRuns.isHeld(pane))
                        && !FileManager.default.fileExists(atPath: path.path)
                }
            )
            #expect(try await fixture.capture(pane).contains(marker))
            let next = try await surface.runShell(
                self.arguments(for: pane, command: "printf 'after-delayed-consumption\\n'")
            )
            #expect(next.structured["exitStatus"]?.intValue == 0)
            #expect(!(await TmuxTools.paneRuns.isHeld(pane)))
        }
    }

    private func tools(_ fixture: Server, transport: PausedRunShellTransport) -> TmuxTools {
        TmuxTools(
            server: Server(
                endpoint: fixture.endpoint,
                tmuxExecutable: fixture.tmuxExecutable,
                transport: transport
            ),
            authority: ToolAuthority(toolsets: [.execute]),
            caller: nil
        )
    }

    private func arguments(for pane: Pane, command: String, timeoutMs: Int64 = 5_000) throws
        -> Arguments
    {
        let request = ToolCall(
            name: "run_shell_command",
            arguments: .object([
                "command": .string(command),
                "paneId": .string(pane.id.rawValue),
                "timeoutMs": .integer(timeoutMs),
            ])
        )
        return try Arguments(request, for: #require(TmuxTools.byName[request.name]))
    }

    private func stagingDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}

enum StagedRunInterruption: String, CaseIterable, Sendable {
    case cancel
    case cancelThenTerminate
    case timeout
    case ambiguousFailure
}

private actor PausedRunShellTransport: ProcessTransport {
    private let underlying = SubprocessTransport()
    private let processID: Int32?
    private let failAfterSubmission: Bool
    private let rejectFirstSubmission: Bool
    private(set) var inputDispatchCount = 0
    private(set) var inputWasQueued = false

    init(
        processID: Int32? = nil,
        failAfterSubmission: Bool = false,
        rejectFirstSubmission: Bool = false
    ) {
        self.processID = processID
        self.failAfterSubmission = failAfterSubmission
        self.rejectFirstSubmission = rejectFirstSubmission
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let firstInput =
            arguments.contains(where: { $0.contains("send-keys") })
            && inputDispatchCount == 0
        if arguments.contains(where: { $0.contains("send-keys") }) {
            inputDispatchCount += 1
        }
        if firstInput, rejectFirstSubmission { throw .requestNotSubmitted }
        if firstInput, let processID {
            guard kill(processID, SIGSTOP) == 0 else {
                throw .invocationFailed(reason: "could not pause fixture shell")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var stopped = false
            repeat {
                let state = try await underlying.run(
                    executable: "/bin/ps",
                    arguments: ["-o", "state=", "-p", String(processID)],
                    environment: environment,
                    perStreamOutputLimit: 1_024
                )
                stopped = state.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T")
                if !stopped { try? await Task.sleep(for: .milliseconds(5)) }
            } while !stopped && ContinuousClock.now < deadline
            guard stopped else { throw .invocationFailed(reason: "fixture shell did not stop") }
        }
        let reply = try await underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            perStreamOutputLimit: perStreamOutputLimit
        )
        if firstInput {
            inputWasQueued = true
            if failAfterSubmission { throw .invocationFailed(reason: "submitted reply lost") }
        }
        return reply
    }
}
