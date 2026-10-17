import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

// MARK: - Rules that need no process

@Suite("tmux version check rules")
struct VersionCheckRuleTests {
    @Test(
        "the floor is a whole release, patch letter included",
        arguments: [
            ("3.1c", false), ("3.2a", false), ("3.3", false), ("3.3a", true),
            ("3.4", true), ("3.7b", true), ("3.10", true), ("4.0", true),
            // A snapshot or candidate ranks below the release it names.
            ("next-3.3a", false), ("3.3a-rc", false), ("next-3.4", true),
            ("3.8-rc2", true), ("next-3.9", true),
            ("3.4-master", true), ("3.3-master", false),
            // A build this library cannot rank is refused, not read as a
            // release: `openbsd` numbers by its own release, not tmux's.
            ("3.4-openbsd", false), ("3.4-custom", false),
        ]
    )
    func floorIsAWholeRelease(_ token: String, _ checked: Bool) throws {
        let version = try #require(TmuxVersion(parsing: token))
        #expect(version.isCoreSupported == checked)
        if checked {
            _ = try Support.Versions.requireCore(token)
        } else {
            #expect(throws: TmuxError.self) { try Support.Versions.requireCore(token) }
        }
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

/// The release of the lane's tmux executable, read without this library.
///
/// `popen` rather than `Process`: this runs while the runner is planning
/// tests on several threads, and a fork from a multithreaded process can
/// deadlock in the child before it execs.
private func laneRelease() -> TmuxVersion? {
    let executable = tmuxExecutablePath()
    guard
        let pipe = popen(
            "'\(executable.replacingOccurrences(of: "'", with: "'\\''"))' -V 2>/dev/null", "r")
    else { return nil }
    var banner = ""
    var buffer = [CChar](repeating: 0, count: 256)
    while fgets(&buffer, Int32(buffer.count), pipe) != nil {
        banner += String(cString: buffer)
    }
    pclose(pipe)
    guard let token = Support.Versions.executableToken(banner: banner, executable: executable)
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

@Suite("tmux version check against the lane's tmux", .timeLimit(.minutes(5)))
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
