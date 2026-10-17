import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

// MARK: - Rules that need no process

@Suite("tmux version check rules")
struct VersionCheckRuleTests {
    /// Every version string tmux has reported, against the 3.3a floor.
    @Test(
        "the version grammar accepts what tmux reports at or above the floor",
        arguments: [
            "3.3a", "3.4", "3.7d", "3.8", "3.10", "4.0", "3.4-rc", "3.8-rc", "3.8-rc2",
            "next-3.4", "next-3.9",
        ]
    )
    func acceptsReportedVersions(_ token: String) throws {
        #expect(try Support.Versions.requireCore(token).token == token)
    }

    @Test(
        "the version grammar refuses a release below the floor",
        arguments: ["3.3", "3.2a", "3.3-rc", "3.2-rc5", "next-3.3"]
    )
    func refusesBelowTheFloor(_ token: String) {
        #expect(
            throws: TmuxError.unsupportedTmuxVersion(
                reported: token, required: "3.3a", operation: "any command")
        ) { try Support.Versions.requireCore(token) }
    }

    @Test(
        "the version grammar refuses what tmux never reports",
        arguments: [
            "master", "openbsd-7.6", "", "3", "garbage", "3.3a garbage", "3.3a-master",
            "3.3a-dev", "next-3.3a", "next-3.9-master", "3.4-master", "3.4-rcx",
        ]
    )
    func refusesUnreportedForms(_ token: String) {
        #expect(throws: TmuxError.self) { try Support.Versions.requireCore(token) }
    }

    @Test("a refusal names the release it saw and the one it wants")
    func refusalNamesBothReleases() {
        #expect(
            throws: TmuxError.unsupportedTmuxVersion(
                reported: "3.3", required: "3.3a", operation: "any command")
        ) { try Support.Versions.requireCore("3.3") }
    }

    @Test(
        "a token that cannot be a release never reaches a format condition",
        arguments: ["", "3.4,}", "3.4 #{x}", "3.4\n", "tmux", "master", "openbsd-7.5"]
    )
    func unreadableTokensAreRefused(_ token: String) {
        #expect(throws: TmuxError.self) { try Support.Versions.requireCore(token) }
    }

    @Test("the probe's answer is the parse error tmux prints")
    func probeReadsTheParseError() {
        let marker = "libtmux-version-abc"
        func reply(_ error: String, exit: Int32 = 1) -> TmuxReply {
            TmuxReply(standardOutput: [], standardError: Array(error.utf8), exitCode: exit)
        }
        #expect(
            Support.Versions.interpret(
                probe: reply("unknown command: libtmux-version-abc-3.3a\n"), marker: marker)
                == .version("3.3a"))
        #expect(
            Support.Versions.interpret(
                probe: reply("unknown command: libtmux-version-abc-next-3.9\n"), marker: marker)
                == .version("next-3.9"))
        for absent in [
            "no server running on /tmp/s\n",
            "error connecting to /tmp/s (No such file or directory)\n",
            "error connecting to /tmp/s (Connection refused)\n",
        ] {
            #expect(Support.Versions.interpret(probe: reply(absent), marker: marker) == .absent)
        }
        // Anything else is an error, not an absent server.
        #expect(
            Support.Versions.interpret(
                probe: reply("error connecting to /tmp/s (Permission denied)\n"), marker: marker)
                == .failed("error connecting to /tmp/s (Permission denied)"))
        // Another marker's answer is not this probe's.
        #expect(
            Support.Versions.interpret(
                probe: reply("unknown command: libtmux-version-other-3.4\n"), marker: marker)
                == .failed("unknown command: libtmux-version-other-3.4"))
        // A successful exit carries no answer.
        #expect(
            Support.Versions.interpret(probe: reply("", exit: 0), marker: marker)
                == .failed("exit status 0"))
    }

    @Test("a daemon without run-shell -C is older than the floor, not a parse error")
    func probeReadsThePreThreeTwoFlagError() {
        let marker = "libtmux-version-abc"
        for error in [
            "command run-shell: unknown flag -C\n",
            "usage: run-shell [-b] [-t target-pane] shell-command\n",
            "server version is too old for client\n",
        ] {
            let reply = TmuxReply(standardOutput: [], standardError: Array(error.utf8), exitCode: 1)
            #expect(Support.Versions.interpret(probe: reply, marker: marker) == .predatesProbe)
        }
        // A client that rejects -N never reached the daemon, so the executable
        // is what gets judged.
        let oldClient = TmuxReply(
            standardOutput: [],
            standardError: Array(
                "tmux: unknown option -- N\nusage: tmux [-2CDluvV] [-c shell-command]\n".utf8),
            exitCode: 1)
        #expect(Support.Versions.interpret(probe: oldClient, marker: marker) == .clientRejectsFlag)
        // A permission error is still a failure, not a version.
        let denied = TmuxReply(
            standardOutput: [],
            standardError: Array("error connecting to /s (Permission denied)\n".utf8),
            exitCode: 1)
        #expect(Support.Versions.interpret(probe: denied, marker: marker) != .predatesProbe)
    }

    @Test(
        "a report that names no release is unrecognized, not a release below the floor",
        arguments: ["master", "openbsd-7.6", "3.3a-dev", "3.3a-master", "next-3.3a"]
    )
    func unrecognizedReportsAreNotBelowTheFloor(_ token: String) {
        do {
            _ = try Support.Versions.requireCore(token)
            Issue.record("\(token) was accepted")
        } catch let error {
            guard case let .invocationFailed(reason) = error else {
                Issue.record("\(token) was refused as \(error), not as unrecognized")
                return
            }
            #expect(!reason.contains("needs"))
            #expect(reason.contains("requires tmux 3.3a or newer"))
        }
    }

    @Test("a refusal tells the reader what to do and that nothing was sent")
    func refusalCarriesTheRemedy() {
        let text = TmuxError.unsupportedVersionMessage(
            reported: "3.2a", required: "3.3a", operation: "any command")
        #expect(text.contains("Nothing was sent"))
        #expect(text.contains("Upgrade tmux and restart the server, or pin the previous"))
    }

    @Test("the probe is a command no after-hook belongs to")
    func probeIsHookFree() {
        let arguments = Support.Versions.probeArguments(marker: "libtmux-version-abc")
        #expect(arguments == ["-N", "run-shell", "-C", "libtmux-version-abc-#{version}"])
        #expect(!arguments.contains("display-message"))
    }

    @Test("3.3a prints the name it was started as")
    func executableBannerAcceptsItsOwnName() {
        func token(_ banner: String, _ executable: String) -> String? {
            Support.Versions.executableToken(banner: banner, executable: executable)
        }
        #expect(token("tmux 3.4\n", "/usr/bin/tmux") == "3.4")
        #expect(token("tmux-3.3a 3.3a\n", "/opt/tmux-3.3a") == "3.3a")
        #expect(token("tmux next-3.9\n", "/usr/bin/tmux") == "next-3.9")
        // Only the executable's own name is accepted in place of `tmux`.
        #expect(token("other 3.4\n", "/usr/bin/tmux") == nil)
        #expect(token("3.4\n", "/usr/bin/tmux") == nil)
    }

    @Test("the fence holds a batch to one release and refuses with a marker")
    func fenceShape() throws {
        let checked = try Support.Versions.requireCore("3.4")
        let fenced = Support.Versions.fence(
            ["new-session", "-d", ";", "list-sessions"], to: checked, marker: "libtmux-version-x")
        #expect(
            fenced == [
                "if-shell", "-F", "#{==:#{version},3.4}", "", "libtmux-version-x", ";",
                "new-session", "-d", ";", "list-sessions",
            ])
        let refused = TmuxReply(
            standardOutput: [], standardError: Array("unknown command: libtmux-version-x\n".utf8),
            exitCode: 1)
        #expect(Support.Versions.isRefusal(refused, marker: "libtmux-version-x"))
        #expect(!Support.Versions.isRefusal(refused, marker: "libtmux-version-y"))
    }
}

// MARK: - Version check against a scripted process boundary

@Suite("tmux version check dispatch", .timeLimit(.minutes(5)))
struct VersionCheckDispatchTests {
    private func server(_ transport: VersionScript) throws -> Server {
        Server(
            endpoint: try Endpoint(
                socketPath:
                    "/tmp/libtmux-swift-test/version-script-\(UUID().uuidString.prefix(8))/socket"
            ),
            tmuxExecutable: "/usr/bin/tmux", transport: transport, checkingVersions: true)
    }

    @Test("a running daemon is asked once and every batch is fenced to its release")
    func liveDaemonIsCheckedOnce() async throws {
        let script = VersionScript(daemon: "3.4", executable: "3.4")
        let server = try server(script)
        _ = try await server.run(TmuxCommand("list-sessions"))
        _ = try await server.run(TmuxCommand("list-windows", ["-a"]))
        let calls = await script.calls
        #expect(calls.count == 3)
        #expect(calls[0].contains("run-shell") && calls[0].contains("-N"))
        for batch in calls.dropFirst() {
            // `-N` keeps a vanished daemon from restarting under an older
            // client; the fence keeps a replaced one from being used.
            #expect(batch.contains("-N"))
            #expect(batch.contains("#{==:#{version},3.4}"))
        }
    }

    @Test("a daemon below the floor is refused before the command is sent")
    func oldDaemonIsRefusedBeforeDispatch() async throws {
        let script = VersionScript(daemon: "3.2a", executable: "3.7")
        let server = try server(script)
        let refusal = TmuxError.unsupportedTmuxVersion(
            reported: "3.2a", required: "3.3a", operation: "any command")
        await #expect(throws: refusal) { try await server.run(TmuxCommand("new-session", ["-d"])) }
        await #expect(throws: refusal) {
            try await server.run(TmuxCommandList([TmuxCommand("kill-server")]))
        }
        await #expect(throws: refusal) { try await server.buffers() }
        await #expect(throws: refusal) { _ = try await server.isRunning() }
        #expect(await script.calls.allSatisfy { $0.contains("run-shell") })
    }

    @Test("a tmux 3.1c daemon is refused as unsupported before anything is sent")
    func threeOneDaemonIsRefusedAsUnsupported() async throws {
        let script = VersionScript(daemon: "3.1c", executable: "3.7")
        let server = try server(script)
        let refusal = TmuxError.unsupportedTmuxVersion(
            reported: "older than 3.2", required: "3.3a", operation: "any command")
        await #expect(throws: refusal) { try await server.run(TmuxCommand("new-session", ["-d"])) }
        #expect(await script.calls.allSatisfy { $0.contains("run-shell") })
        #expect(await script.ran("new-session") == false)
    }

    @Test("with no daemon the executable is checked and starts the server unfenced by -N")
    func coldEndpointValidatesTheExecutable() async throws {
        let script = VersionScript(daemon: nil, executable: "3.4")
        let server = try server(script)
        _ = try await server.run(TmuxCommand("new-session", ["-d"]))
        let calls = await script.calls
        #expect(calls.count == 3)
        #expect(calls[1].last == "-V")
        #expect(!calls[2].contains("-N"))
        #expect(calls[2].contains("#{==:#{version},3.4}"))

        let old = VersionScript(daemon: nil, executable: "3.3")
        let refused = try self.server(old)
        await #expect(throws: TmuxError.self) {
            try await refused.run(TmuxCommand("new-session", ["-d"]))
        }
        #expect(await old.calls.count == 2)
    }

    @Test("stopping a server that is not there is not a version question")
    func killingAnAbsentServerIsANoOp() async throws {
        let script = VersionScript(daemon: nil, executable: "3.2a")
        let server = try server(script)
        let reply = try await server.run(TmuxCommand("kill-server"))
        #expect(!reply.isSuccess)
        let calls = await script.calls
        #expect(calls.count == 2)
        #expect(calls[1].contains("-N") && calls[1].last == "kill-server")
    }

    @Test("a daemon replaced after the check refuses the batch, and the replacement is judged")
    func replacedDaemonDoesNotInheritVersion() async throws {
        let script = VersionScript(daemon: "3.4", executable: "3.4")
        let server = try server(script)
        _ = try await server.run(TmuxCommand("list-sessions"))
        await script.replaceDaemon(with: "3.2a")
        await #expect(
            throws: TmuxError.unsupportedTmuxVersion(
                reported: "3.2a", required: "3.3a", operation: "any command")
        ) { try await server.run(TmuxCommand("new-session", ["-d"])) }
        #expect(await script.ran("new-session") == false)

        // A replacement that is still supported is checked afresh.
        await script.replaceDaemon(with: "3.7b")
        _ = try await server.run(TmuxCommand("new-session", ["-d"]))
        #expect(await script.ran("new-session"))
        #expect(try await server.daemonVersion() == TmuxVersion(parsing: "3.7b"))
    }

    @Test("a daemon that exits after the check is not restarted by the checked client")
    func vanishedDaemonIsNotRestarted() async throws {
        let script = VersionScript(daemon: "3.4", executable: "3.4")
        let server = try server(script)
        _ = try await server.run(TmuxCommand("list-sessions"))
        await script.removeDaemon()
        _ = try await server.run(TmuxCommand("new-session", ["-d"]))
        let batches = await script.calls.filter { $0.contains("new-session") }
        #expect(batches.count == 2)
        #expect(batches[0].contains("-N"))
        #expect(!batches[1].contains("-N"))
    }
}

/// A process boundary that answers like tmux would: a probe with the daemon's
/// release, a fenced batch only when the fence's release matches, and a
/// missing daemon with tmux's own words.
actor VersionScript: ProcessTransport {
    private var daemon: String?
    private let executable: String
    private(set) var calls: [[String]] = []
    private var ranCommands: [String] = []

    init(daemon: String?, executable: String) {
        self.daemon = daemon
        self.executable = executable
    }

    func replaceDaemon(with release: String) { daemon = release }
    func removeDaemon() { daemon = nil }
    func ran(_ command: String) -> Bool { ranCommands.contains(command) }

    func run(
        executable _: String, arguments: [String], environment _: [String: String],
        perStreamOutputLimit _: Int
    ) async throws(TmuxError) -> TmuxReply {
        calls.append(arguments)
        func reply(_ out: String = "", _ error: String = "", exit: Int32 = 0) -> TmuxReply {
            TmuxReply(
                standardOutput: Array(out.utf8), standardError: Array(error.utf8), exitCode: exit)
        }
        let absent = reply(
            "", "no server running on /tmp/libtmux-swift-test/version-script/socket\n", exit: 1)
        if arguments.last == "-V" { return reply("tmux \(executable)\n") }
        if let probe = arguments.firstIndex(of: "-C"), arguments[probe - 1] == "run-shell" {
            guard let daemon else { return absent }
            // tmux 3.1c parses run-shell with `bt:`, so -C is an unknown flag.
            if daemon == "3.1c" {
                return reply("", "command run-shell: unknown flag -C\n", exit: 1)
            }
            return reply(
                "",
                "unknown command: \(arguments[probe + 1].replacingOccurrences(of: "#{version}", with: daemon))\n",
                exit: 1)
        }
        guard let fence = arguments.firstIndex(of: "if-shell") else {
            return daemon == nil ? absent : reply()
        }
        let live = arguments.contains("-N")
        guard let daemon else {
            if live { return absent }
            ranCommands.append(contentsOf: arguments[(fence + 6)...])
            daemon = executable
            return reply()
        }
        let condition = arguments[fence + 2]
        let marker = arguments[fence + 4]
        guard condition == "#{==:#{version},\(daemon)}" else {
            return reply("", "unknown command: \(marker)\n", exit: 1)
        }
        ranCommands.append(contentsOf: arguments[(fence + 6)...])
        return reply()
    }
}

// MARK: - Version check against real tmux

/// A tmux at or above the floor, set by the jobs that stand an old daemon up
/// behind a newer client.
private let newerClient: String? = {
    let selected = ProcessInfo.processInfo.environment["LIBTMUX_TMUX_CLIENT_BIN"]
    guard let selected, !selected.isEmpty,
        let result = spawnCapturing(selected, ["-V"]),
        let token = Support.Versions.executableToken(banner: result.output, executable: selected),
        TmuxVersion(parsing: token)?.isCoreSupported == true
    else { return nil }
    return selected
}()

private enum RefusalOutcome: Equatable {
    case refused, accepted, failed(String), timedOut
}

/// Delivers the first of several results and drops the rest.
private final class FirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RefusalOutcome, Never>?

    init(_ continuation: CheckedContinuation<RefusalOutcome, Never>) {
        self.continuation = continuation
    }

    func deliver(_ outcome: RefusalOutcome) {
        lock.lock()
        let taken = continuation
        continuation = nil
        lock.unlock()
        taken?.resume(returning: outcome)
    }
}

/// What a listing on `server` comes to within `limit`.
///
/// The deadline runs on a dispatch queue, not on the task pool: a transport
/// that blocks a pool thread on a stdout pipe that never closes cannot be
/// cancelled, so a deadline that waited for it would never fire and the case
/// would end in the job's own timeout instead of in a failed assertion.
private func listingOutcome(_ server: Server, within limit: Duration) async -> RefusalOutcome {
    await withCheckedContinuation { continuation in
        let first = FirstResult(continuation)
        Task {
            do {
                _ = try await server.sessions()
                first.deliver(.accepted)
            } catch let error as TmuxError {
                if case .unsupportedTmuxVersion = error {
                    first.deliver(.refused)
                } else {
                    first.deliver(.failed(String(describing: error)))
                }
            } catch {
                first.deliver(.failed(String(describing: error)))
            }
        }
        let seconds = Double(limit.components.seconds)
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            first.deliver(.timedOut)
        }
    }
}

let laneIsBelowFloor = tmuxLaneRelease().map { !$0.isCoreSupported } ?? false
let laneIsSupported = tmuxLaneRelease().map(\.isCoreSupported) ?? false

/// A daemon started by the lane's tmux directly, so a release this library
/// refuses can still be stood up and watched from outside.
private struct NativeDaemon {
    let socket: String

    @discardableResult
    func tmux(_ arguments: [String]) async throws -> TmuxReply {
        try await SubprocessTransport().run(
            executable: tmuxExecutablePath(), arguments: ["-S", socket] + arguments,
            environment: TmuxProcessEnvironment.variables(), perStreamOutputLimit: 1_048_576)
    }

    func sessionNames() async throws -> [String] {
        let reply = try await tmux(["list-sessions", "-F", "#{session_name}"])
        return reply.isSuccess ? reply.text.split(separator: "\n").map(String.init) : []
    }

    var server: Server {
        get throws {
            try Server(socketPath: socket, tmuxExecutable: tmuxExecutablePath())
        }
    }
}

private func withNativeDaemon<Result>(
    started: Bool = true,
    _ body: (NativeDaemon) async throws -> Result
) async throws -> Result {
    let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
        .appendingPathComponent("adm-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let daemon = NativeDaemon(socket: root.appendingPathComponent("s").path)
    if started {
        try await daemon.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "anchor"])
        // A second invocation: the daemon a first one forks keeps that client's
        // pipes open on some releases, and the run would never see them close.
        try await daemon.tmux(reaperCommand(root: root).argumentVector)
    }
    do {
        let result = try await body(daemon)
        _ = try? await daemon.tmux(["kill-server"])
        return result
    } catch {
        _ = try? await daemon.tmux(["kill-server"])
        throw error
    }
}

@Suite("tmux version check against the lane's tmux", .serialized, .timeLimit(.minutes(5)))
struct VersionCheckLaneTests {
    private func refusal(_ error: TmuxError) -> Bool {
        if case .unsupportedTmuxVersion = error { return true }
        return false
    }

    private func refused(_ error: any Error) -> Bool {
        (error as? TmuxError).map(refusal) ?? false
    }

    @Test("the refusal comes back while a stale process holds stdout open")
    func refusalDoesNotWaitForStdout() async throws {
        let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("held-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        // Answers like a 3.0a daemon behind a newer client: the version line on
        // stderr, exit 1, and a child that keeps stdout open after the exit.
        let client = root.appendingPathComponent("tmux")
        let script = """
            #!/bin/sh
            sleep 25 2>/dev/null &
            echo 'server version is too old for client' >&2
            exit 1
            """
        try script.write(to: client, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: client.path)
        let server = try Server(
            socketPath: root.appendingPathComponent("s").path, tmuxExecutable: client.path)
        #expect(await listingOutcome(server, within: .seconds(10)) == .refused)
    }

    @Test("a CI run names its tmux, and the refusal job runs on a refused release")
    func ciNamesItsLane() {
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] != nil {
            #expect(environment["LIBTMUX_TMUX_BIN"]?.isEmpty == false, "CI must select its tmux")
        }
        if environment["LIBTMUX_EXPECT_REFUSAL"]?.isEmpty == false {
            #expect(laneIsBelowFloor, "the refusal job ran on a supported tmux")
            #expect(newerClient != nil, "the refusal job has no client at the floor")
        } else if environment["CI"] != nil {
            #expect(laneIsSupported, "a supported lane ran on a tmux below the floor")
            #expect(newerClient != nil, "a supported lane has no second tmux as a client")
        }
    }

    @Test(
        "a daemon below the floor is refused by every entry point with no effect",
        .enabled(if: laneIsBelowFloor, "needs a tmux older than the floor")
    )
    func oldDaemonIsRefusedEverywhere() async throws {
        try await withNativeDaemon { daemon in
            let server = try daemon.server
            // Sentinels the refused calls must leave exactly as they found them.
            try await daemon.tmux(["set-option", "-g", "@sentinel", "kept"])
            try await daemon.tmux(["set-buffer", "-b", "sentinel", "kept"])
            func refused<T: Sendable>(_ operation: () async throws -> T) async -> Bool {
                do {
                    _ = try await operation()
                    return false
                } catch let error as TmuxError {
                    return refusal(error)
                } catch {
                    return false
                }
            }
            #expect(
                await refused {
                    try await server.run(TmuxCommand("new-session", ["-d", "-s", "sentinel"]))
                })
            #expect(
                await refused {
                    try await server.run(
                        TmuxCommandList([
                            TmuxCommand("new-session", ["-d", "-s", "sentinel"]),
                            TmuxCommand("set-buffer", ["-b", "sentinel", "x"]),
                        ]))
                })
            #expect(await refused { try await server.newSession(named: "sentinel") })
            #expect(await refused { try await server.setBuffer("x", named: "sentinel") })
            #expect(await refused { try await server.setOption("@sentinel", to: "changed") })
            #expect(await refused { try await server.deleteBuffer(named: "sentinel") })
            // Lenient listings propagate the refusal instead of reading as empty.
            #expect(await refused { try await server.buffers() })
            #expect(await refused { try await server.sessions() })
            #expect(await refused { try await server.isRunning() })
            #expect(await refused { try await server.hasSession("anchor") })
            #expect(await refused { try await server.snapshot() })
            #expect(
                await refused { try await server.connected(attachingTo: "anchor") { _, _ in 0 } })
            // The raw native view shows nothing was done.
            #expect(try await daemon.sessionNames() == ["anchor"])
            #expect(try await daemon.tmux(["show-options", "-gv", "@sentinel"]).text == "kept\n")
            #expect(try await daemon.tmux(["show-buffer", "-b", "sentinel"]).text == "kept")
            #expect(
                try await daemon.tmux(["list-buffers", "-F", "#{buffer_name}"]).text == "sentinel\n"
            )
            #expect(try await daemon.tmux(["list-clients"]).text.isEmpty)
        }
    }

    @Test(
        "a daemon below the floor is refused promptly behind a newer client",
        .enabled(
            if: laneIsBelowFloor && newerClient != nil, "needs an old daemon and a newer client")
    )
    func oldDaemonBehindNewerClientIsRefusedPromptly() async throws {
        try await withNativeDaemon { daemon in
            let server = try Server(
                socketPath: daemon.socket, tmuxExecutable: try #require(newerClient))
            #expect(await listingOutcome(server, within: .seconds(15)) == .refused)
            #expect(try await daemon.sessionNames() == ["anchor"])
        }
    }

    @Test(
        "an executable below the floor is refused before it can start a server",
        .enabled(if: laneIsBelowFloor, "needs a tmux older than the floor")
    )
    func oldExecutableIsRefusedOnAColdEndpoint() async throws {
        try await withNativeDaemon(started: false) { daemon in
            let server = try daemon.server
            await #expect(throws: TmuxError.self) {
                try await server.newSession(named: "sentinel")
            }
            #expect(!FileManager.default.fileExists(atPath: daemon.socket))
            // Stopping nothing is not a version question.
            let stopped = try await server.run(TmuxCommand("kill-server"))
            #expect(!stopped.isSuccess)
            // Diagnostics still answer below the floor.
            #expect(try await server.version() == tmuxLaneRelease())
        }
    }

    @Test(
        "a daemon replaced behind the endpoint does not inherit the previous version check",
        .enabled(
            if: laneIsBelowFloor && newerClient != nil, "needs an old daemon and a newer client")
    )
    func replacementDaemonIsJudgedAfresh() async throws {
        try await withNativeDaemon { daemon in
            // The fence is `-N`, which a client older than 3.2 rejects itself.
            let server = try Server(
                socketPath: daemon.socket, tmuxExecutable: try #require(newerClient))
            // The server last saw a supported daemon at this endpoint.
            await server.presumeSupported(try Support.Versions.requireCore("3.4"))
            await #expect(throws: TmuxError.self) {
                try await server.run(TmuxCommand("new-session", ["-d", "-s", "sentinel"]))
            }
            #expect(try await daemon.sessionNames() == ["anchor"])
        }
    }

    @Test(
        "a supported daemon replaces a stale version check and the command runs once",
        .enabled(if: laneIsSupported, "needs a supported tmux")
    )
    func staleVersionIsRepaired() async throws {
        try await withNativeDaemon { daemon in
            let server = try daemon.server
            // Any other supported release makes the first fence refuse.
            let other = tmuxLaneRelease() == TmuxVersion(parsing: "3.3a") ? "3.4" : "3.3a"
            await server.presumeSupported(try Support.Versions.requireCore(other))
            _ = try await server.run(TmuxCommand("new-session", ["-d", "-s", "marker"]))
            #expect(try await daemon.sessionNames().sorted() == ["anchor", "marker"])
        }
    }

    @Test(
        "the version check fires no after-hook and no command-error hook",
        .enabled(if: laneIsSupported, "needs a supported tmux")
    )
    func versionCheckIsHookFree() async throws {
        try await withNativeDaemon { daemon in
            let log = URL(fileURLWithPath: daemon.socket + ".hooks")
            defer { try? FileManager.default.removeItem(at: log) }
            let record = { (name: String) in "run-shell 'echo \(name) >> \(log.path)'" }
            try await daemon.tmux(["set-hook", "-g", "after-display-message", record("display")])
            // `command-error` exists from tmux 3.5; older releases refuse to
            // set it, and then there is nothing for the version check to fire.
            let hasCommandError = try await daemon.tmux(
                ["set-hook", "-g", "command-error", record("error")]
            ).isSuccess

            let server = try daemon.server
            _ = try await server.daemonVersion()
            _ = try await server.run(TmuxCommand("list-sessions"))
            // The identity read is library-owned too, and over a connection.
            let identity = try await server.incarnation()
            #expect(identity.socketPath == daemon.socket)
            if laneSupportsControl {
                _ = try await server.connected(attachingTo: "anchor") { connected, _ in
                    try await connected.incarnation()
                }
            }

            // Controls: an ordinary display-message fires its hook, and on
            // 3.5 and later an ordinary failing command fires the error hook.
            try await daemon.tmux(["display-message", "-p", "control"])
            if hasCommandError { try await daemon.tmux(["kill-session", "-t", "=nonexistent"]) }
            let expected = hasCommandError ? ["display", "error"] : ["display"]
            let arrived = try await waitUntil {
                guard let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
                return Set(text.split(separator: "\n").map(String.init)) == Set(expected)
            }
            #expect(arrived, "the controls did not reach the hook log")
            // Let any hook the check fired settle, then count what ran.
            try await Task.sleep(for: .milliseconds(300))
            let lines =
                (try? String(contentsOf: log, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            #expect(lines.sorted() == expected.sorted())
        }
    }

    @Test(
        "a client that reports another release can use a daemon it can speak to",
        .enabled(
            if: laneIsSupported
                && ProcessInfo.processInfo.environment["LIBTMUX_TMUX_CLIENT_BIN"] != nil,
            "needs a supported lane and a second tmux in LIBTMUX_TMUX_CLIENT_BIN")
    )
    func daemonReleaseNotClientRelease() async throws {
        try await withNativeDaemon { daemon in
            let client = try #require(
                ProcessInfo.processInfo.environment["LIBTMUX_TMUX_CLIENT_BIN"])
            let server = try Server(socketPath: daemon.socket, tmuxExecutable: client)
            let reported = try await server.daemonVersion()
            #expect(reported == tmuxLaneRelease())
            _ = try await server.run(TmuxCommand("new-session", ["-d", "-s", "viaclient"]))
            #expect(try await daemon.sessionNames().contains("viaclient"))
        }
    }
}

@Suite("control attach version fence", .timeLimit(.minutes(1)))
struct ControlAttachFenceTests {
    /// A stand-in for tmux that reports 3.8 to the probe, attaches a control
    /// client, and answers the first command sent over it as a daemon that
    /// was replaced after the check would: the fence's marker, unparsed.
    private func standIn(in root: URL) throws -> URL {
        let script = root.appendingPathComponent("tmux")
        try #"""
        #!/bin/sh
        echo "$@" >> "$0.args"
        case "$*" in
        *run-shell*)
            for word in "$@"; do last=$word; done
            echo "unknown command: ${last%-#\{version\}}-3.8" >&2
            exit 1 ;;
        *attach-session*)
            echo "%begin 1 1 0"
            echo "%end 1 1 0"
            read line
            for word in $line; do last=$word; done
            echo "%begin 2 2 1"
            echo "unknown command: $(echo "$last" | tr -d "'\"")"
            echo "%error 2 2 1"
            sleep 3 ;;
        esac
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func withStandIn(
        _ body: (Server, URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
            .appendingPathComponent("fence-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try standIn(in: root)
        let server = try Server(
            socketPath: root.appendingPathComponent("s").path, tmuxExecutable: script.path)
        try await body(server, URL(fileURLWithPath: script.path + ".args"))
    }

    @Test("a connection to a daemon that is not the one checked never enters its body")
    func attachIsFencedToTheCheckedDaemon() async throws {
        try await withStandIn { server, _ in
            let entered = EnteredControlBody()
            await #expect(throws: TmuxError.serverRestarted) {
                try await server.withControlMode(attachingTo: "main") { _ in
                    await entered.mark()
                }
            }
            #expect(await !entered.value, "the body ran against an unchecked daemon")
        }
    }

    @Test("a connection to a checked daemon is attached with -N")
    func attachDoesNotStartADaemon() async throws {
        try await withStandIn { server, arguments in
            _ = try? await server.withControlMode(attachingTo: "main") { _ in }
            let log = (try? String(contentsOf: arguments, encoding: .utf8)) ?? ""
            let attach = try #require(
                log.split(separator: "\n").first { $0.contains("attach-session") })
            #expect(attach.split(separator: " ").contains("-N"), "attached without -N: \(attach)")
        }
    }
}

private actor EnteredControlBody {
    private(set) var value = false

    func mark() { value = true }
}

/// What tmux answers an identity read with: the expansion, as the first word
/// of a command it cannot parse. Nil when `arguments` is not an identity read.
func scriptedIdentityReply(
    to arguments: [String], socketPath: String, processID: Int, startedAt: Int
) -> TmuxReply? {
    guard let index = arguments.firstIndex(of: "-C"), arguments.indices.contains(index + 1),
        arguments[index + 1].hasSuffix("#{pid},#{start_time},#{q:socket_path}")
    else { return nil }
    let marker = arguments[index + 1].replacingOccurrences(
        of: "#{pid},#{start_time},#{q:socket_path}", with: "")
    return TmuxReply(
        standardOutput: [],
        standardError: Array(
            "unknown command: \(marker)\(processID),\(startedAt),\(socketPath)\n".utf8),
        exitCode: 1)
}
