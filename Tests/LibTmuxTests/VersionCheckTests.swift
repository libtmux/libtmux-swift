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
    /// Every version string tmux has reported, as the shared vector table
    /// lists them, against the 3.3a floor.
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
                reported: token, required: "3.3a", operation: "ordinary tmux operations")
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
                reported: "3.3", required: "3.3a", operation: "ordinary tmux operations")
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
            endpoint: try Endpoint(socketPath: "/tmp/libtmux-swift-test/version-script/socket"),
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
            reported: "3.2a", required: "3.3a", operation: "ordinary tmux operations")
        await #expect(throws: refusal) { try await server.run(TmuxCommand("new-session", ["-d"])) }
        await #expect(throws: refusal) {
            try await server.run(TmuxCommandList([TmuxCommand("kill-server")]))
        }
        await #expect(throws: refusal) { try await server.buffers() }
        await #expect(throws: refusal) { _ = try await server.isRunning() }
        #expect(await script.calls.allSatisfy { $0.contains("run-shell") })
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
                reported: "3.2a", required: "3.3a", operation: "ordinary tmux operations")
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

/// Runs `executable` and captures what it prints, without this library.
///
/// `posix_spawn` rather than `Process` or `popen`: this runs while the runner
/// plans tests on several threads, and a fork from a multithreaded process can
/// deadlock in the child before it execs, leaving its pipes open forever.
private func spawnCapturing(
    _ executable: String, _ arguments: [String]
) -> (output: String, error: String, status: Int32)? {
    var out: [Int32] = [0, 0]
    var err: [Int32] = [0, 0]
    guard pipe(&out) == 0 else { return nil }
    guard pipe(&err) == 0 else {
        close(out[0])
        close(out[1])
        return nil
    }
    #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
    #else
        var actions = posix_spawn_file_actions_t()
    #endif
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    for descriptor in out + err { posix_spawn_file_actions_addclose(&actions, descriptor) }
    var child: pid_t = 0
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    let environment =
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { environment.forEach { free($0) } }
    let status = posix_spawn(&child, executable, &actions, nil, argv, environment)
    close(out[1])
    close(err[1])
    guard status == 0 else {
        close(out[0])
        close(err[0])
        return nil
    }
    // A daemon this client started can keep these pipes open after the client
    // is gone, so read what is there until the client exits instead of
    // waiting for end of file.
    for descriptor in [out[0], err[0]] {
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    var captured = [Data(), Data()]
    var buffer = [UInt8](repeating: 0, count: 4096)
    func collect() {
        for (index, descriptor) in [out[0], err[0]].enumerated() {
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 { break }
                captured[index].append(contentsOf: buffer[..<count])
            }
        }
    }
    var wait: Int32 = 0
    while true {
        collect()
        let reaped = waitpid(child, &wait, WNOHANG)
        if reaped == child || reaped < 0 { break }
        usleep(2_000)
    }
    collect()
    close(out[0])
    close(err[0])
    return (
        String(decoding: captured[0], as: UTF8.self),
        String(decoding: captured[1], as: UTF8.self), (wait >> 8) & 0xff
    )
}

/// The release of the lane's tmux executable.
private func laneRelease() -> TmuxVersion? {
    let executable = tmuxExecutablePath()
    guard let result = spawnCapturing(executable, ["-V"]),
        let token = Support.Versions.executableToken(banner: result.output, executable: executable)
    else { return nil }
    return TmuxVersion(parsing: token)
}

private let laneIsBelowFloor = laneRelease().map { !$0.isCoreSupported } ?? false
private let laneIsSupported = laneRelease().map(\.isCoreSupported) ?? false

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

    @Test(
        "a daemon below the floor is refused by every entry point with no effect",
        .enabled(if: laneIsBelowFloor, "needs a tmux older than the floor")
    )
    func oldDaemonIsRefusedEverywhere() async throws {
        try await withNativeDaemon { daemon in
            let server = try daemon.server
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
            #expect(try await daemon.tmux(["show-buffer", "-b", "sentinel"]).isSuccess == false)
            #expect(try await daemon.tmux(["list-clients"]).text.isEmpty)
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
            #expect(try await server.version() == laneRelease())
        }
    }

    @Test(
        "a daemon replaced behind the endpoint does not inherit the previous version check",
        .enabled(if: laneIsBelowFloor, "needs a tmux older than the floor")
    )
    func replacementDaemonIsJudgedAfresh() async throws {
        try await withNativeDaemon { daemon in
            let server = try daemon.server
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
            let other = laneRelease() == TmuxVersion(parsing: "3.3a") ? "3.4" : "3.3a"
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
            _ = try await server.connected(attachingTo: "anchor") { connected, _ in
                try await connected.incarnation()
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
            "set LIBTMUX_TMUX_CLIENT_BIN to a second supported tmux")
    )
    func daemonReleaseNotClientRelease() async throws {
        try await withNativeDaemon { daemon in
            let client = try #require(
                ProcessInfo.processInfo.environment["LIBTMUX_TMUX_CLIENT_BIN"])
            let server = try Server(socketPath: daemon.socket, tmuxExecutable: client)
            let reported = try await server.daemonVersion()
            #expect(reported == laneRelease())
            _ = try await server.run(TmuxCommand("new-session", ["-d", "-s", "viaclient"]))
            #expect(try await daemon.sessionNames().contains("viaclient"))
        }
    }
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
