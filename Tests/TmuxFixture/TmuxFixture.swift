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
    _ body: (Server) async throws -> Result
) async throws -> Result {
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
    defer { try? FileManager.default.removeItem(at: root) }

    let server = try Server(
        socketPath: root.appendingPathComponent("s").path,
        tmuxExecutable: tmuxExecutablePath()
    )
    _ = try await server.run([
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
        TmuxCommand("new-session", ["-d", "-s", "bootstrap"]),
        reaperCommand(root: root),
    ])
    do {
        let result = try await body(server)
        _ = try await server.run(TmuxCommand("kill-server"))
        return result
    } catch {
        _ = try? await server.run(TmuxCommand("kill-server"))
        throw error
    }
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
/// `AGENTS.md` and CI name the directory; ``namedSocketsAvailable`` is what the
/// suite checks so a run without one skips those cases rather than scattering
/// sockets.
public let namedSocketRoot: URL? = ProcessInfo.processInfo.environment["TMUX_TMPDIR"]
    .map { URL(fileURLWithPath: $0) }

/// Whether this run can address servers by socket name inside the suite's root.
public var namedSocketsAvailable: Bool {
    guard let root = namedSocketRoot else { return false }
    return root.path.hasPrefix(socketRoot.path)
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
    // it before the job can remove anything. tmux does not reliably unlink a
    // socket on its way out, so the ordinary path is cleaned here — the same
    // division of labour the path-addressed fixture uses for its directory.
    defer { try? FileManager.default.removeItem(at: socket) }

    let server = try Server(
        socketName: name,
        tmuxExecutable: tmuxExecutablePath()
    )
    _ = try await server.run([
        TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
        TmuxCommand("new-session", ["-d", "-s", "bootstrap"]),
        reaperCommand(root: socket),
    ])
    do {
        let result = try await body(server)
        _ = try await server.run(TmuxCommand("kill-server"))
        return result
    } catch {
        _ = try? await server.run(TmuxCommand("kill-server"))
        throw error
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
/// So the reaper lives inside the tmux server instead, as a background job. It
/// watches the owning process and, once that is gone, removes the directory and
/// kills the server. Three details carry the design:
///
/// - The directory goes first. `kill` ends the server, and tmux kills its jobs
///   when it exits, so anything sequenced after it would not run.
/// - The server is addressed by pid, not by socket, because the socket is
///   inside the directory just removed.
/// - `#{pid}` is left for tmux to expand rather than asked for first, which is
///   what lets arming ride in the same invocation that creates the session.
///   Sent separately, a run killed in the gap between the two leaves a server
///   no reaper ever covered — measurably, under load, about one server in six.
/// - The interval is whole seconds. Fractions are a GNU and BSD extension that
///   POSIX does not require, and a `sleep` that rejects its argument turns this
///   into a busy loop per server rather than a slower one. Reaping a second
///   later costs nothing here.
public func reaperCommand(root: URL) -> TmuxCommand {
    let owner = ProcessInfo.processInfo.processIdentifier
    let script = """
        while kill -0 \(owner) 2>/dev/null; do sleep 1; done; \
        rm -rf '\(root.path)'; \
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
