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
    @Test("the shell deadline bounds every setup read", arguments: RunShellSetupRead.allCases)
    func setupReadDeadline(_ read: RunShellSetupRead) async throws {
        try await withTmuxServer { fixture in
            let pane = try #require(try await fixture.panes().first)
            let directory = try stagingDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let recorder = RunShellSetupTransport()
            let recording = tools(fixture, transport: recorder)
            let initial = try await recording.preflightPaneInput(
                pane.id.rawValue, scope: .singularPOSIXShell, force: false,
                operation: "run_shell_command")
            try await recording.server.using(.direct) { server in
                _ = try await server.captureBounded(
                    initial.source, since: nil, maximumLines: 1,
                    perStreamOutputLimit: PaneOutputBudget.sourceBytes)
                _ = try await server.formatGlobal("#{pane_width}", for: initial.source)
            }
            _ = try await recording.preflightPaneInput(
                pane.id.rawValue, scope: .singularPOSIXShell, force: false,
                transitionFrom: initial, operation: "run_shell_command")
            _ = try await recording.server.formatGlobal(
                "#{session_id}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}", for: initial.source)
            // Replay daemon reads so process startup does not spend the timeout.
            let reads = await recorder.reads
            let stalledIndex = try #require(read.index(in: reads))
            let transport = RunShellSetupTransport(
                replaying: reads, stallingAt: stalledIndex,
                ignoringCancellation: read == .lifecycleIgnoresCancellation)
            let surface = tools(fixture, transport: transport)
            let staged = directory.appendingPathComponent("must-not-exist")

            let arguments = try arguments(for: pane, command: "true", timeoutMs: 100)
            let running = Task { try await surface.runShell(arguments, stagingAt: staged.path) }
            do {
                _ = try await withCommandDeadline(.seconds(1)) { try await running.value }
                Issue.record("a stalled setup read completed without a timeout")
            } catch let TmuxError.timedOut(after) {
                #expect(after > .zero && after <= .milliseconds(100))
            } catch {
                await transport.releaseStall()
                running.cancel()
                _ = await running.result
                throw error
            }
            await transport.releaseStall()
            running.cancel()
            _ = await running.result
            #expect(await transport.didStall)
            #expect(await transport.inputDispatchCount == 0)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(!(await TmuxTools.paneRuns.isHeld(pane)))
        }
    }

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
            try await fixture.send(
                [.key("printf '%s\\n' \"$$\" > \(shellQuoted(processFile.path))"), .key("Enter")],
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

    private func tools(_ fixture: Server, transport: any ProcessTransport) -> TmuxTools {
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

enum RunShellSetupRead: String, CaseIterable, Sendable {
    case initialPreflight, capture, width, finalPreflight, lifecycle, lifecycleIgnoresCancellation

    fileprivate func index(in reads: [RunShellSetupTransport.Read]) -> Int? {
        switch self {
        case .initialPreflight:
            reads.firstIndex { $0.arguments.contains("list-panes") }
        case .capture:
            reads.firstIndex { $0.arguments.contains { $0.contains("capture-pane") } }
        case .width:
            reads.firstIndex {
                $0.arguments.contains {
                    $0.contains("#{pane_id}\(FormatProjection.separator)#{pane_width}")
                }
            }
        case .finalPreflight:
            reads.lastIndex { $0.arguments.contains("list-panes") }
        case .lifecycle, .lifecycleIgnoresCancellation:
            reads.firstIndex { read in
                read.arguments.contains { $0.contains("#{pane_pid}\t#{pane_dead}") }
            }
        }
    }
}

private actor RunShellSetupTransport: ProcessTransport {
    struct Read: Sendable {
        let arguments: [String]
        let reply: TmuxReply
    }

    private let underlying = SubprocessTransport()
    private let replay: [Read]?
    private let stalledIndex: Int?
    private let ignoringCancellation: Bool
    private var stalled: CheckedContinuation<Void, Never>?
    private var index = 0
    private(set) var reads: [Read] = []
    private(set) var didStall = false
    private(set) var inputDispatchCount = 0

    init(
        replaying reads: [Read]? = nil, stallingAt index: Int? = nil,
        ignoringCancellation: Bool = false
    ) {
        self.replay = reads
        self.stalledIndex = index
        self.ignoringCancellation = ignoringCancellation
    }

    func releaseStall() {
        stalled?.resume()
        stalled = nil
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        if arguments.contains(where: { $0.contains("send-keys") }) {
            inputDispatchCount += 1
            throw .requestNotSubmitted
        }
        if let replay {
            guard index < replay.count,
                replay[index].arguments.map(Self.withoutNonce) == arguments.map(Self.withoutNonce)
            else { throw .invocationFailed(reason: "unexpected setup read during replay") }
            let read = replay[index]
            let shouldStall = index == stalledIndex
            index += 1
            if shouldStall {
                didStall = true
                if ignoringCancellation {
                    await withCheckedContinuation { stalled = $0 }
                    throw .cancelled
                }
                let (events, continuation) = AsyncStream<Void>.makeStream()
                defer { continuation.finish() }
                for await _ in events {}
                throw .cancelled
            }
            // Guarded replies carry a new nonce on each invocation.
            guard let oldNonce = Self.nonce(in: read.arguments),
                let newNonce = Self.nonce(in: arguments)
            else { return read.reply }
            func rebind(_ bytes: [UInt8]) -> [UInt8] {
                Array(
                    String(decoding: bytes, as: UTF8.self)
                        .replacingOccurrences(of: oldNonce, with: newNonce).utf8)
            }
            return TmuxReply(
                standardOutput: rebind(read.reply.standardOutput),
                standardError: rebind(read.reply.standardError), exitCode: read.reply.exitCode)
        }
        let reply = try await underlying.run(
            executable: executable, arguments: arguments, environment: environment,
            perStreamOutputLimit: perStreamOutputLimit)
        reads.append(Read(arguments: arguments, reply: reply))
        return reply
    }

    private static let noncePattern = "__libtmux_request_[a-f0-9]{32}"

    private static func withoutNonce(_ argument: String) -> String {
        argument.replacingOccurrences(
            of: noncePattern, with: "request", options: .regularExpression)
    }

    private static func nonce(in arguments: [String]) -> String? {
        for argument in arguments {
            if let range = argument.range(of: noncePattern, options: .regularExpression) {
                return String(argument[range])
            }
        }
        return nil
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
