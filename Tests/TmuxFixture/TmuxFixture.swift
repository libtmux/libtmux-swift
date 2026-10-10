import Foundation
import LibTmux

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Keeps a broken pipe from killing the test process.
///
/// Writing to a control connection whose tmux has already gone raises SIGPIPE,
/// whose default action is to terminate — so the run dies mid-suite with no
/// failing case to point at. A pipe has no portable per-descriptor way to
/// suppress it (`MSG_NOSIGNAL` is
/// for sockets, `F_SETNOSIGPIPE` is Darwin's alone), so the disposition is the
/// process's to choose and the library does not choose it for anybody. Here the
/// process is the test runner, which has no pipeline behaviour to preserve, so
/// it chooses. A program embedding this library makes its own call — see
/// <doc:PlatformSupport>.
private let sigpipeIgnoredOnce: Void = {
    signal(SIGPIPE, SIG_IGN)
}()

/// Where every socket this suite creates lives.
///
/// `/tmp` rather than `TMPDIR`: a socket path is bounded by `sun_path`, and
/// Darwin's per-user `TMPDIR` is a long `/var/folders/…` path that spends much
/// of that budget before the fixture names anything. `/tmp` exists on both
/// systems. ``Endpoint`` enforces the limit.
///
/// The language is in the name because `/tmp` is shared and several ports of
/// libtmux are worked on side by side. A Python suite and this one both reaching
/// for `libtmux-test-…` would see each other's servers, and anything sweeping up
/// by prefix — this fixture's own reaper included — would kill a server it never
/// started. Scoping the root means a stray socket always says whose it is.
private let socketRoot = URL(fileURLWithPath: "/tmp/libtmux-swift-test")

/// Runs `body` against a private tmux server and always kills it — including
/// when this process is killed outright.
///
/// Each case gets its own socket, so cases never see each other's sessions and
/// teardown never touches a server it did not start. The server is bootstrapped
/// with one session named `bootstrap`: a tmux server exits as soon as its last
/// session goes away, so without one there is nothing to hold it open. Scope
/// assertions to the objects the case created rather than to the server being
/// otherwise empty.
public func withTmuxServer<Result>(
    socketFileName: String = "s",
    _ body: (Server) async throws -> Result
) async throws -> Result {
    try await withTmuxFixtureCapacity {
        _ = sigpipeIgnoredOnce
        let root = socketRoot.appendingPathComponent("\(UUID().uuidString.prefix(8))")
        // The shared root may already be there from an earlier case; this case's own
        // directory may not, so a collision fails here rather than putting two
        // servers on one socket.
        try FileManager.default.createDirectory(
            at: socketRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let server = try Server(
            socketPath: root.appendingPathComponent(socketFileName).path,
            tmuxExecutable: tmuxExecutablePath()
        )
        let owner = try await server.newOwnedServer(
            bootstrapSession: "bootstrap",
            configurationCommands: [
                // Before the first session, so even the bootstrap pane gets it.
                //
                // A pane otherwise runs whoever's shell the machine is configured
                // with, which makes a test's speed and its behaviour someone's dotfiles
                // rather than the library's. An interactive shell with a line editor
                // also discards input typed before it has finished starting, so a case
                // that sends keys races that startup and loses on a busy machine. `sh`
                // starts promptly, reads what it is given, and is on both supported
                // systems.
                TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
                // `default-shell` alone is still run as a *login* shell — tmux
                // prefixes its `argv[0]` with `-`, and `$0` in the pane proves it —
                // so it reads `/etc/profile` and the runner's own profile: exactly
                // the dotfiles the line above exists to keep out, and enough startup
                // to delay the first prompt past the keys a case sends. Naming the
                // command drops the login pass. `ENV` is the remaining rc hook, and
                // is set in the server environment rather than in front of the
                // command, where it would become the window's name.
                TmuxCommand("set-environment", ["-g", "ENV", ""]),
                // Darwin's /bin/bash is 3.2 and prints a notice telling the reader
                // that zsh is the default shell now. It is compiled in rather than
                // read from a startup file, so --noprofile --norc does not stop it,
                // and it lands in the pane ahead of whatever a case is reading.
                TmuxCommand("set-environment", ["-g", "BASH_SILENCE_DEPRECATION_WARNING", "1"]),
                // `exec` so the pane holds one process: without it tmux keeps the
                // `-c` wrapper alive, and a case that `exec`s its own command still
                // reports the wrapper as the pane's command.
                TmuxCommand("set-option", ["-g", "default-command", "exec sh"]),
            ], startupCommands: [try reaperCommand(root: root)])
        return try await finishFixture(owner: owner, removing: root) {
            try await waitForShellPrompt(on: server)
            return try await body(server)
        }
    }
}

/// Waits until a pane's shell has drawn its first prompt.
///
/// Keys sent before that are echoed with no prompt in front of them, which
/// leaves the prompt to land on the row the command's own output wants. A case
/// looking for a row equal to what it printed is then waiting for something
/// that cannot arrive, and reports it as a timeout naming nothing. One capture
/// settles it for every case that follows.
///
/// What the prompt *says* is not portable — `sh` is dash on Linux and bash on
/// macOS, which prints `sh-3.2$` — so readiness is that the pane has drawn
/// anything at all. Until the shell starts it has drawn nothing.
///
/// This reads the pane directly rather than through the wait machinery: a
/// fixture that bootstrapped itself with the code under test would make every
/// unrelated case depend on it.
public func waitForShellPrompt(
    on server: Server,
    within timeout: Duration = .seconds(20)
) async throws {
    guard let pane = try await server.panes().first else {
        throw TmuxFixtureError.shellNeverPrompted
    }
    let ready = try await waitUntil(within: timeout) {
        try await server.capture(pane).contains { !$0.isEmpty }
    }
    guard ready else { throw TmuxFixtureError.shellNeverPrompted }
}

enum TmuxFixtureError: Error {
    case shellNeverPrompted
}

/// The directory a socket *name* resolves inside, when the run provides one.
///
/// tmux looks a name up in `TMUX_TMPDIR`, whose default is shared with every
/// other tmux on the machine — the other libtmux ports' included. A suite that
/// addressed servers by name without moving that directory would put its
/// sockets exactly where anything sweeping by prefix can reach them, which is
/// what this whole root exists to prevent.
///
/// So the directory is taken from the environment rather than set into it. The
/// obvious alternative — `setenv` from the fixture — writes to `environ` while
/// other cases are concurrently reading it to build a tmux environment, and
/// that is a data race whether or not it has bitten yet. Cases that address a
/// socket by path do not care either way, `-S` being absolute.
///
/// `CONTRIBUTING.md` and CI name the directory; ``namedSocketsAvailable`` is
/// what the suite checks so a run without one skips those cases rather than
/// scattering sockets.
public let namedSocketRoot: URL? = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
    .map { URL(fileURLWithPath: $0) }

func isAllowedNamedSocketRoot(_ root: URL) -> Bool {
    let allowed = socketRoot.standardizedFileURL.resolvingSymlinksInPath().path
    let candidate = root.standardizedFileURL.resolvingSymlinksInPath().path
    return candidate == allowed || candidate.hasPrefix("\(allowed)/")
}

/// Whether this run can address servers by socket name inside the suite's root.
public var namedSocketsAvailable: Bool {
    guard let root = namedSocketRoot else { return false }
    return isAllowedNamedSocketRoot(root)
}

/// Thrown when a name-addressed case runs without a directory to put it in.
public struct NamedSocketRootMissing: Error, CustomStringConvertible {
    public var description: String {
        "set TMUX_TMPDIR to a directory under /tmp/libtmux-swift-test"
    }
}

/// Runs `body` against a private tmux server addressed by socket *name*, and
/// always kills it.
///
/// The same guarantees as ``withTmuxServer(_:)`` — its own server, killed on
/// the way out and reaped if this process is killed outright — for the half of
/// ``Endpoint`` that a path-addressed fixture never exercises.
public func withNamedTmuxServer<Result>(
    _ body: (Server) async throws -> Result
) async throws -> Result {
    try await withTmuxFixtureCapacity {
        _ = sigpipeIgnoredOnce
        guard let root = namedSocketRoot, namedSocketsAvailable else {
            // Reached only if a case forgot its `.enabled(if:)`; better to say so
            // than to put a socket in the machine-wide directory.
            throw NamedSocketRootMissing()
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let name = "libtmux-swift-\(UUID().uuidString.prefix(8))"
        // tmux does not put the socket in `TMUX_TMPDIR` itself: it creates a
        // `tmux-<uid>` directory inside it and puts the socket there, so that one
        // directory can be shared between users without their sockets colliding.
        // The reaper has to be told the path tmux will actually use, or it removes
        // nothing and every case leaves its socket behind.
        let socket =
            root
            .appendingPathComponent("tmux-\(getuid())")
            .appendingPathComponent(name)

        // The reaper covers a run that is killed outright; it cannot cover the
        // ordinary exit, because `kill-server` takes tmux's background jobs with
        // it before the job can verify daemon exit. tmux can leave a socket
        // behind, so finishFixture waits for the captured process before removing
        // the path, as it does for a path-addressed fixture's directory.

        let server = try Server(
            socketName: name,
            tmuxExecutable: tmuxExecutablePath()
        )
        let owner = try await server.newOwnedServer(
            bootstrapSession: "bootstrap",
            configurationCommands: [
                TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
                // `default-shell` alone is still run as a *login* shell — tmux
                // prefixes its `argv[0]` with `-`, and `$0` in the pane proves it —
                // so it reads `/etc/profile` and the runner's own profile: exactly
                // the dotfiles the line above exists to keep out, and enough startup
                // to delay the first prompt past the keys a case sends. Naming the
                // command drops the login pass. `ENV` is the remaining rc hook, and
                // is set in the server environment rather than in front of the
                // command, where it would become the window's name.
                TmuxCommand("set-environment", ["-g", "ENV", ""]),
                // Darwin's /bin/bash is 3.2 and prints a notice telling the reader
                // that zsh is the default shell now. It is compiled in rather than
                // read from a startup file, so --noprofile --norc does not stop it,
                // and it lands in the pane ahead of whatever a case is reading.
                TmuxCommand("set-environment", ["-g", "BASH_SILENCE_DEPRECATION_WARNING", "1"]),
                // `exec` so the pane holds one process: without it tmux keeps the
                // `-c` wrapper alive, and a case that `exec`s its own command still
                // reports the wrapper as the pane's command.
                TmuxCommand("set-option", ["-g", "default-command", "exec sh"]),
            ], startupCommands: [try reaperCommand(root: socket)])
        return try await finishFixture(owner: owner, removing: socket) {
            try await waitForShellPrompt(on: server)
            return try await body(server)
        }
    }
}

/// The reaper was asked to remove a path outside this port's owned roots.
public struct UnsafeReaperRoot: Error, Sendable, Hashable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "a reaper root must be below /tmp/libtmux-swift-test or /tmp/libtmux-swift-dev"
    }
}

/// A reaper that outlives this process, so a killed run leaves no server
/// behind.
///
/// Arm it in the same invocation that creates the server's first session, and
/// give it the directory holding the socket. Public because the benchmark
/// provisions its own servers — with a counting shim standing in for tmux —
/// and a second copy of this reasoning is a second copy to get wrong.
///
/// `defer` and `kill-server` both run *in the process that started the server*,
/// which makes them useless in the one case that actually leaks: the run is
/// killed outright by a harness timeout or an impatient operator, and every
/// tmux server it started survives with no owner and no way to reach it.
/// Cleanup that depends on the cleaner surviving is not deterministic.
///
/// The reaper runs inside tmux as a background job and watches the owning
/// process. When that process exits, the reaper signals the captured daemon
/// PID. It retains the directory: tmux terminates its jobs during shutdown, so
/// that job cannot verify daemon exit before deleting files. An outer harness
/// may remove the recorded root after observing process exit.
///
/// Arm the reaper in the invocation that creates the first session. `#{pid}`
/// expands in that daemon, and a whole-second sleep avoids depending on a
/// platform-specific fractional `sleep` implementation. The path argument
/// still identifies the fixture root and must remain inside the port's roots.
public func reaperCommand(root: URL) throws(UnsafeReaperRoot) -> TmuxCommand {
    let candidate = root.standardizedFileURL.resolvingSymlinksInPath().path
    let allowedRoots = ["/tmp/libtmux-swift-test", "/tmp/libtmux-swift-dev"]
    guard allowedRoots.contains(where: { candidate.hasPrefix("\($0)/") }) else {
        throw UnsafeReaperRoot()
    }
    let owner = ProcessInfo.processInfo.processIdentifier
    let script = """
        while kill -0 \(owner) 2>/dev/null; do sleep 1; done; \
        kill #{pid} 2>/dev/null
        """
    return TmuxCommand("run-shell", ["-b", script])
}

/// Polls `condition` until it holds, and reports whether it did.
///
/// Bounded in wall-clock rather than in attempts. What makes one of these polls
/// slow is the tmux call inside it, so a count of attempts says nothing about
/// how long the loop can run: on a contended machine a generous-looking budget
/// outlives the case's time limit, and the failure reads as a timeout instead of
/// naming the thing that never became true.
public func waitUntil(
    within timeout: Duration = .seconds(20),
    _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    // One last look, so a condition that came true during the final sleep is
    // not reported as a failure.
    return try await condition()
}

/// Waits for a stopped daemon's Unix listener to close before reusing its path.
public func waitForSocketClosure(_ path: String) async throws -> Bool {
    try await waitUntil(within: .seconds(2)) {
        #if canImport(Darwin)
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
            let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_un()
        #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return false }
        if errno == ECONNREFUSED || errno == ENOENT { return true }
        if errno == EINPROGRESS || errno == EAGAIN { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// The lane binary when a matrix runner selected one, otherwise whatever `tmux`
/// resolves to. Resolved to a path because the transport never searches `PATH`.
public func tmuxExecutablePath() -> String {
    if let selected = ProcessInfo.processInfo.environment["LIBTMUX_TMUX_BIN"],
        !selected.isEmpty
    {
        return selected
    }
    for candidate in ["/usr/bin/tmux", "/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"]
    where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return "/usr/bin/tmux"
}

/// Fixture teardown failed; the path stays available for inspection.
public struct FixtureCleanupFailure: Error, Sendable {
    public let root: String
    public let bodyError: (any Error)?
    public let cleanupError: any Error
}

private func finishFixture<Result>(
    owner: OwnedTmux<Server>, removing root: URL, body: () async throws -> Result
) async throws -> Result {
    let outcome: Swift.Result<Result, any Error>
    do { outcome = .success(try await body()) } catch { outcome = .failure(error) }
    // OwnedTmux.close shields its task from the body's cancellation. Files are
    // removed only after the captured daemon has exited. A replacement daemon
    // is left intact with its root, and the caller sees the retained path.
    let cleanup = await Task.detached { () async -> (any Error)? in
        do {
            try await owner.close()
            if try await owner.value.isRunning() {
                throw TmuxError.serverRestarted
            }
            try FileManager.default.removeItem(at: root)
            return nil
        } catch { return error }
    }.value
    if let cleanup {
        let bodyError: (any Error)?
        switch outcome {
        case .success: bodyError = nil
        case let .failure(error): bodyError = error
        }
        throw FixtureCleanupFailure(root: root.path, bodyError: bodyError, cleanupError: cleanup)
    }
    return try outcome.get()
}
