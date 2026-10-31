import Foundation
import Testing

@testable import LibTmux
@testable import TmuxFixture

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A run started some other way than `Scripts/swift-test` fails here, naming the
/// script, and is refused by the first fixture it reaches.
@Suite("test sandbox", .timeLimit(.minutes(5)))
struct SandboxTests {
    private static let selectors = [
        "TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH", "LIBTMUX_SOCKET_OTHER",
    ]

    private static var decoys: [String: String] {
        Dictionary(uniqueKeysWithValues: selectors.map { ($0, "decoy-\($0)") })
    }

    @Test("the run was started by Scripts/swift-test")
    func theRunIsSandboxed() {
        let findings = sandboxViolations()
        #expect(
            findings.isEmpty,
            "start the suite with Scripts/swift-test: \(findings.joined(separator: "; "))")
    }

    @Test("a client the library starts is handed no selector and the sandbox directory")
    func aLibraryClientSeesTheSandbox() async throws {
        try await withScratchDirectory { directory in
            let recorder = try RecordingTmux(in: directory)
            let server = try Server(
                socketPath: directory.appendingPathComponent("s").path,
                tmuxExecutable: recorder.executable.path)
            _ = try? await server.run(TmuxCommand("list-sessions"))

            let runs = try recorder.runs()
            let started = !runs.isEmpty
            try #require(started, "the library never started the client")
            for run in runs {
                let selectors = selectorNames(in: run.names)
                let sandboxed = run.tmpdirIsSandbox
                #expect(selectors == [])
                #expect(sandboxed, "TMUX_TMPDIR was not the directory the run names")
            }
        }
    }

    @Test("the recording client shows a selector it is handed, and none after cleaning")
    func theRecorderCanSeeWhatItIsHanded() async throws {
        try await withScratchDirectory { directory in
            let recorder = try RecordingTmux(in: directory)
            let handed = Self.decoys.merging(["PATH": "/usr/bin:/bin"]) { $1 }
            try recorder.run(environment: handed)
            try recorder.run(environment: sandboxedEnvironment(handed))

            let runs = try recorder.runs()
            let ran = runs.count == 2
            try #require(ran, "the recording client ran a different number of times")
            let handedSelectors = selectorNames(in: runs[0].names)
            let cleanedSelectors = selectorNames(in: runs[1].names)
            #expect(handedSelectors == Self.selectors.sorted())
            #expect(cleanedSelectors == [])
        }
    }

    @Test("cleaning keeps other variables and sets the directory only when asked")
    func cleaningTouchesOnlySelectors() {
        let caller = Self.decoys.merging(["PATH": "/usr/bin", "LIBTMUX_TMUX_BIN": "/opt/tmux"]) {
            first, _ in first
        }
        let cleaned = sandboxedEnvironment(caller)
        let named = sandboxedEnvironment(caller, tmuxTemporaryDirectory: "/tmp/private")
        let inherited = sandboxedEnvironment(caller.merging(["TMUX_TMPDIR": "/users/own"]) { $1 })

        let unchanged = cleaned["PATH"] == "/usr/bin" && cleaned["LIBTMUX_TMUX_BIN"] == "/opt/tmux"
        let directorySet = named["TMUX_TMPDIR"] == "/tmp/private"
        let directoryKept = inherited["TMUX_TMPDIR"] == "/users/own"

        #expect(cleaned.keys.sorted() == ["LIBTMUX_TMUX_BIN", "PATH"])
        #expect(unchanged, "a variable that is not a selector changed")
        #expect(directorySet, "the directory asked for was not set")
        #expect(directoryKept, "an inherited directory was replaced")
    }

    @Test("a selector is named, and its value is not", arguments: SandboxTests.selectors)
    func aSelectorIsNamed(_ name: String) async throws {
        try await withScratchDirectory { directory in
            var environment = [sandboxMarker: directory.path, "TMUX_TMPDIR": directory.path]
            #expect(sandboxViolations(in: environment).isEmpty)

            environment[name] = "must-not-appear"
            #expect(sandboxViolations(in: environment) == ["\(name) is set"])
        }
    }

    @Test("a run the script did not start is named")
    func aMissingMarkerIsNamed() {
        #expect(
            sandboxViolations(in: ["TMUX_TMPDIR": "/tmp/anywhere"])
                == ["\(sandboxMarker) is not set"])
        #expect(sandboxViolations(in: [sandboxMarker: ""]) == ["\(sandboxMarker) is not set"])
    }

    @Test("a TMUX_TMPDIR other than the sandbox is named")
    func aForeignTmuxTmpdirIsNamed() async throws {
        try await withScratchDirectory { directory in
            let findings = sandboxViolations(in: [
                sandboxMarker: directory.path, "TMUX_TMPDIR": "/tmp",
            ])
            #expect(findings == ["TMUX_TMPDIR is not the directory \(sandboxMarker) names"])
            #expect(
                sandboxViolations(in: [sandboxMarker: directory.path]) == findings)
        }
    }

    @Test("a sandbox that others can enter, a link and a missing path are named")
    func aDirectoryThatIsNotPrivateIsNamed() async throws {
        try await withScratchDirectory { directory in
            let expected = [
                "the directory \(sandboxMarker) names is not an owner-only directory"
            ]
            func findings(_ path: String) -> [String] {
                sandboxViolations(in: [sandboxMarker: path, "TMUX_TMPDIR": path])
            }

            let link = directory.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            #expect(findings(link.path) == expected)
            #expect(findings(directory.appendingPathComponent("absent").path) == expected)

            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
            #expect(findings(directory.path) == expected)
        }
    }

    @Test("only a run the script started is held to it")
    func onlyAnEnteredRunIsHeld() {
        let ambient = ["TMUX": "/decoy/socket,1,0"]

        #expect(throws: Never.self) { try requireEnteredSandbox(in: ambient) }
        #expect(throws: SandboxViolation.self) {
            try requireEnteredSandbox(in: ambient.merging([sandboxMarker: "/tmp"]) { $1 })
        }
        #expect(throws: SandboxViolation.self) { try requireSandbox(in: ambient) }
        #expect(SandboxViolation(findings: ["TMUX is set"]).description.contains("swift-test"))
    }

    @Test("this package's own fixture refuses an unwrapped run, and its first entry is live")
    func theFixtureRefusesHere() {
        let dependency = isDependencyCheckout(fixtureSourcePath)
        let runner = isTestRunner()
        let failure = fixtureSandboxFailure

        #expect(!dependency, "the checkout path holds /checkouts/, so no run would be refused")
        #expect(runner, "this process is not recognised as a test runner, so none would be refused")
        #expect(failure == nil, "the fixture would refuse this run")
    }

    @Test("a dependency checkout is told from this package's own tree")
    func checkoutsAreTold() {
        let own = "/work/libtmux-swift/Tests/TmuxFixture/TmuxSandbox.swift"
        let swiftPM = "/app/.build/checkouts/libtmux-swift/Tests/TmuxFixture/TmuxSandbox.swift"
        let xcode = "/x/DerivedData/app/SourcePackages/checkouts/libtmux-swift/Tests/T.swift"
        let path = "/work/libtmux-swift/Examples/../Tests/TmuxFixture/TmuxSandbox.swift"

        #expect(!isDependencyCheckout(own))
        #expect(!isDependencyCheckout(path))
        #expect(isDependencyCheckout(swiftPM))
        #expect(isDependencyCheckout(xcode))
    }

    @Test("a test runner is told from a program that embeds the fixture")
    func runnersAreTold() {
        #expect(isTestRunner(["/w/.build/debug/libtmuxPackageTests.xctest", "--traits", "X"]))
        #expect(isTestRunner(["/Applications/Xcode.app/usr/bin/xctest", "/w/t.xctest"]))
        #expect(isTestRunner(["/Applications/Xcode.app/usr/libexec/swiftpm-testing-helper"]))
        #expect(!isTestRunner(["/w/Examples/.build/debug/ApiCapture"]))
        #expect(!isTestRunner([]))
    }

    @Test("an unmarked test run of our own fixture is refused, and nothing else is")
    func unmarkedRunsAreRefusedHere() {
        let own = "/work/libtmux-swift/Tests/TmuxFixture/TmuxSandbox.swift"
        let dependency = "/app/.build/checkouts/libtmux-swift/Tests/TmuxFixture/TmuxSandbox.swift"
        let runner = ["/w/.build/debug/libtmuxPackageTests.xctest"]
        let example = ["/w/Examples/.build/debug/ApiCapture"]
        let quiet = ["TMUX_TMPDIR": "/tmp/anywhere"]
        let ambient = ["TMUX": "/decoy/socket,1,0"]
        let marked = ambient.merging([sandboxMarker: "/tmp"]) { $1 }

        #expect(throws: SandboxViolation.self) {
            try requireFixtureSandbox(compiledAt: own, running: runner, in: quiet)
        }
        #expect(throws: SandboxViolation.self) {
            try requireFixtureSandbox(compiledAt: own, running: runner, in: ambient)
        }
        #expect(throws: Never.self) {
            try requireFixtureSandbox(compiledAt: dependency, running: runner, in: ambient)
        }
        #expect(throws: Never.self) {
            try requireFixtureSandbox(compiledAt: own, running: example, in: ambient)
        }
        #expect(throws: SandboxViolation.self) {
            try requireFixtureSandbox(compiledAt: own, running: example, in: marked)
        }
        #expect(throws: SandboxViolation.self) {
            try requireFixtureSandbox(compiledAt: dependency, running: runner, in: marked)
        }
    }

    @Test("a client that names no socket lands on the default socket in the sandbox")
    func aBareClientLandsInTheSandbox() async throws {
        try await withBareClient(named: "landing", insideRunDirectory: true) { bare in
            // The environment a pane would leave: a TMUX naming a socket, with
            // the sandbox's TMUX_TMPDIR beside it.
            let cleaned = sandboxedEnvironment(
                bare.paneEnvironment, tmuxTemporaryDirectory: bare.tmuxTemporaryDirectory.path)
            let status = try bare.start(session: "canary", environment: cleaned)
            let landed = try await waitUntil(within: .seconds(5)) {
                FileManager.default.fileExists(atPath: bare.defaultSocket)
            }
            let strayed = FileManager.default.fileExists(atPath: bare.ambientSocket)

            #expect(status == 0, "the client did not start a server")
            #expect(landed, "no socket appeared at the default path under the sandbox")
            #expect(!strayed, "the client followed TMUX")
        }
    }

    @Test("control: the same client follows TMUX when nothing cleans the environment")
    func aBareClientFollowsTMUXWhenNothingCleansIt() async throws {
        try await withBareClient(named: "control", insideRunDirectory: false) { bare in
            let status = try bare.start(session: "canary", environment: bare.paneEnvironment)
            let followed = try await waitUntil(within: .seconds(5)) {
                FileManager.default.fileExists(atPath: bare.ambientSocket)
            }
            let landed = FileManager.default.fileExists(atPath: bare.defaultSocket)

            #expect(status == 0, "the client did not start a server")
            #expect(followed, "the client did not follow TMUX, so the case above proves nothing")
            #expect(!landed, "the client used the default socket although TMUX named another")
        }
    }
}

/// Spelled out rather than taken from the code under test, so a predicate that
/// stopped matching would not make these checks agree with it.
private func selectorNames(in names: Set<String>) -> [String] {
    names.filter { $0 == "TMUX" || $0 == "TMUX_PANE" || $0.hasPrefix("LIBTMUX_SOCKET") }
        .sorted()
}

private func withScratchDirectory<Result>(
    _ body: (URL) async throws -> Result
) async throws -> Result {
    let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
    try FileManager.default.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = root.appendingPathComponent("sandbox-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

private enum BareClientError: Error { case cannotStart }

/// Runs `body` with a bare client and always stops what it started, waiting for
/// each server to be gone: `Scripts/swift-test` calls a server still listening
/// when the run ends a leak, and one told to exit is still listening for a
/// moment.
private func withBareClient(
    named name: String,
    insideRunDirectory: Bool,
    _ body: (BareClient) async throws -> Void
) async throws {
    let bare = try BareClient(named: name, insideRunDirectory: insideRunDirectory)
    do {
        try await body(bare)
    } catch {
        await bare.stopEverything()
        throw error
    }
    await bare.stopEverything()
}

/// A real tmux client that names no -L or -S, the way a case that forgot to
/// would, and nothing else: it refuses to start unless the run is sandboxed,
/// puts every socket it can create inside the sandbox, and stops only those.
private struct BareClient {
    /// The `TMUX_TMPDIR` the client is given, and the default socket under it.
    let tmuxTemporaryDirectory: URL
    let defaultSocket: String
    let ambientSocket: String

    /// With `insideRunDirectory`, the client is given the run's own
    /// `TMUX_TMPDIR`, which is what a case that forgot would be given. Without
    /// it, a directory of its own inside the run's, so two clients never share
    /// a default socket.
    init(named name: String, insideRunDirectory: Bool) throws {
        try requireSandbox()
        guard let marked = ProcessInfo.processInfo.environment[sandboxMarker] else {
            throw SandboxViolation(findings: ["\(sandboxMarker) is not set"])
        }
        let sandbox = URL(fileURLWithPath: marked)
        let ambient = sandbox.appendingPathComponent("ambient-\(name)")
        try FileManager.default.createDirectory(
            at: ambient, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        tmuxTemporaryDirectory = insideRunDirectory ? sandbox : ambient
        defaultSocket =
            tmuxTemporaryDirectory.appendingPathComponent("tmux-\(getuid())/default").path
        ambientSocket = ambient.appendingPathComponent("s").path
    }

    /// The environment of a process started inside a tmux pane, as far as
    /// tmux is concerned: a `TMUX` naming a socket, and the sandbox's own
    /// `TMUX_TMPDIR`.
    var paneEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "TMUX": "\(ambientSocket),1,0", "TMUX_TMPDIR": tmuxTemporaryDirectory.path,
        ]) { $1 }
    }

    /// Starts a server with one session running `sleep`, not a shell: a login
    /// shell can take seconds to notice it has been hung up, and the server
    /// stays until it does.
    func start(session: String, environment: [String: String]) throws -> Int32 {
        try run(
            ["-f", "/dev/null", "new-session", "-d", "-s", session, "sleep", "3600"],
            environment: environment)
    }

    /// Stops a server on each socket this client could have created, by path,
    /// and waits for its listener to close.
    func stopEverything() async {
        for socket in [defaultSocket, ambientSocket]
        where FileManager.default.fileExists(atPath: socket) {
            _ = try? run(
                ["-f", "/dev/null", "-S", socket, "kill-server"],
                environment: sandboxedEnvironment(
                    tmuxTemporaryDirectory: tmuxTemporaryDirectory.path))
            _ = try? await waitForSocketClosure(socket)
        }
    }

    /// Through `posix_spawn` rather than `Process`: the client leaves a server
    /// behind it, and `Process` has not returned for a client like that.
    private func run(_ arguments: [String], environment: [String: String]) throws -> Int32 {
        guard
            let result = spawnCapturing(
                tmuxExecutablePath(), arguments, environment: environment)
        else { throw BareClientError.cannotStart }
        return result.status
    }
}

/// A stand-in for tmux that records its arguments, the names of the variables
/// it was handed and whether `TMUX_TMPDIR` is the run's sandbox, and nothing
/// else: no value is written, so no failure can print one.
private struct RecordingTmux {
    struct Run {
        var names: Set<String> = []
        var tmpdirIsSandbox = false
    }

    let executable: URL
    private let record: URL

    init(in directory: URL) throws {
        executable = directory.appendingPathComponent("tmux")
        record = directory.appendingPathComponent("record")
        try Data(
            """
            #!/bin/sh
            {
                printf 'ARGV'
                for argument in "$@"; do printf ' %s' "$argument"; done
                printf '\\n'
                env | sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/NAME \\1/p'
                if [ -n "${TMUX_TMPDIR:-}" ] && [ "${TMUX_TMPDIR:-}" = "${LIBTMUX_TEST_SANDBOX:-}" ]; then
                    printf 'BOOL tmpdir_is_sandbox\\n'
                fi
            } >> "$(dirname "$0")/record"

            """.utf8
        ).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func run(environment: [String: String]) throws {
        guard
            spawnCapturing(executable.path, ["list-sessions"], environment: environment) != nil
        else { throw BareClientError.cannotStart }
    }

    /// What each run was handed, in order.
    func runs() throws -> [Run] {
        guard FileManager.default.fileExists(atPath: record.path) else { return [] }
        var runs: [Run] = []
        for line in try String(contentsOf: record, encoding: .utf8).split(separator: "\n") {
            if line.hasPrefix("ARGV") {
                runs.append(Run())
            } else if line.hasPrefix("NAME "), !runs.isEmpty {
                runs[runs.count - 1].names.insert(String(line.dropFirst(5)))
            } else if line == "BOOL tmpdir_is_sandbox", !runs.isEmpty {
                runs[runs.count - 1].tmpdirIsSandbox = true
            }
        }
        return runs
    }
}
