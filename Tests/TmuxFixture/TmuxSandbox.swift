import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The variable `Scripts/swift-test` sets to the directory it gave the run.
///
/// Its presence is how a run says it was started by that script. This
/// package's own runs must carry it; a package that takes `TmuxFixture` as a
/// dependency is held to what the script promised only when it carries it. Its
/// tests run from a tmux pane and the fixture's servers all name their socket,
/// so `TMUX` costs them nothing, and a program that embeds the fixture, as the
/// examples do, has no script to start it.
let sandboxMarker = "LIBTMUX_TEST_SANDBOX"

/// Whether `name` makes tmux, or a libtmux executable, choose a server itself.
///
/// tmux follows `TMUX` to the server its caller is inside, ahead of
/// `TMUX_TMPDIR`. `TMUX_PANE` retargets a command that names no pane, and
/// `libtmux-mcp` picks a socket from `LIBTMUX_SOCKET` and `LIBTMUX_SOCKET_PATH`.
func isAmbientSelector(_ name: String) -> Bool {
    name == "TMUX" || name == "TMUX_PANE" || name.hasPrefix("LIBTMUX_SOCKET")
}

/// `environment` without the variables that select a server.
///
/// A child a test starts takes this rather than the process environment, so it
/// cannot follow the server the suite was started from. Pass
/// `tmuxTemporaryDirectory` when the child may use tmux's default socket, so
/// that socket lands in a directory the test owns.
func sandboxedEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment,
    tmuxTemporaryDirectory: String? = nil
) -> [String: String] {
    var cleaned = environment.filter { !isAmbientSelector($0.key) }
    if let tmuxTemporaryDirectory { cleaned["TMUX_TMPDIR"] = tmuxTemporaryDirectory }
    return cleaned
}

/// Every way `environment` could still reach a server the suite did not start.
///
/// Names variables and never their values: a `TMUX` is a path under someone's
/// home, and a finding ends up in a log.
func sandboxViolations(
    in environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String] {
    var findings = environment.keys.filter(isAmbientSelector).sorted().map { "\($0) is set" }
    guard let sandbox = environment[sandboxMarker], !sandbox.isEmpty else {
        findings.append("\(sandboxMarker) is not set")
        return findings
    }
    if environment["TMUX_TMPDIR"] != sandbox {
        findings.append("TMUX_TMPDIR is not the directory \(sandboxMarker) names")
    }
    if !isOwnerOnlyDirectory(sandbox) {
        findings.append("the directory \(sandboxMarker) names is not an owner-only directory")
    }
    return findings
}

private func isOwnerOnlyDirectory(_ path: String) -> Bool {
    var information = stat()
    guard lstat(path, &information) == 0 else { return false }
    return information.st_mode & S_IFMT == S_IFDIR
        && information.st_uid == getuid()
        && information.st_mode & 0o077 == 0
}

/// The environment still reaches a server the suite did not start.
struct SandboxViolation: Error, Sendable, CustomStringConvertible {
    let findings: [String]

    var description: String {
        "the run is not sandboxed: " + findings.joined(separator: "; ")
            + ". Start it with Scripts/swift-test."
    }
}

/// Throws unless the environment holds no selector and names a private
/// directory as `TMUX_TMPDIR`.
///
/// The fixture calls this on entry for this package's own runs, through
/// ``requireFixtureSandbox(compiledAt:in:)``. Code that starts a tmux client
/// without the fixture, such as a case that builds a server naming no socket,
/// calls it before it starts anything.
func requireSandbox(
    in environment: [String: String] = ProcessInfo.processInfo.environment
) throws(SandboxViolation) {
    let findings = sandboxViolations(in: environment)
    if !findings.isEmpty { throw SandboxViolation(findings: findings) }
}

/// ``requireSandbox(in:)`` for a run that says it was started by
/// `Scripts/swift-test`, and nothing for any other.
func requireEnteredSandbox(
    in environment: [String: String] = ProcessInfo.processInfo.environment
) throws(SandboxViolation) {
    guard environment[sandboxMarker] != nil else { return }
    try requireSandbox(in: environment)
}

/// The path these sources were compiled from.
let fixtureSourcePath = #filePath

/// Whether `path` lies in a checkout SwiftPM or Xcode made for a dependency.
///
/// Both put one at `.../checkouts/<package>/`. A copy of this package that is
/// the root of the build, or a path dependency such as the one `Examples/`
/// takes, is not one.
func isDependencyCheckout(_ path: String) -> Bool {
    path.contains("/checkouts/")
}

/// Whether `arguments` start a test runner rather than a program that embeds
/// the fixture, as the examples do.
///
/// SwiftPM runs a package's tests in `<package>PackageTests.xctest` on Linux, and
/// in `xctest` or `swiftpm-testing-helper` on Darwin.
func isTestRunner(_ arguments: [String] = CommandLine.arguments) -> Bool {
    guard let first = arguments.first else { return false }
    let name = (first as NSString).lastPathComponent
    return name.contains("xctest") || name.contains("testing-helper")
}

/// What the fixture requires of a run.
///
/// Every test run of this package's own sources must have been started by
/// `Scripts/swift-test`, so a bare `swift test` fails at the first fixture it
/// reaches instead of running with whatever the shell holds. Anything else is
/// held to it only if it carries the marker: a package that depends on this
/// one, and a program that embeds the fixture, such as the examples a reader
/// runs with `swift run`.
func requireFixtureSandbox(
    compiledAt path: String = fixtureSourcePath,
    running arguments: [String] = CommandLine.arguments,
    in environment: [String: String] = ProcessInfo.processInfo.environment
) throws(SandboxViolation) {
    if isDependencyCheckout(path) || !isTestRunner(arguments) {
        try requireEnteredSandbox(in: environment)
    } else {
        try requireSandbox(in: environment)
    }
}

/// What every fixture entry reports, worked out once: the environment does not
/// change under a run.
let fixtureSandboxFailure: SandboxViolation? = {
    do throws(SandboxViolation) {
        try requireFixtureSandbox()
        return nil
    } catch {
        return error
    }
}()
