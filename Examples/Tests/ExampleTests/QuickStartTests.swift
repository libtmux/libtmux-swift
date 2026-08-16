import Foundation
import LibTmux
import Testing
import TmuxFixture

/// The quick start is top-level code, so no test can call it; it is spawned.
///
/// Found from this file rather than from `Bundle.main`, whose `bundleURL` is
/// the package's build directory on Linux but the xctest harness inside Xcode
/// on Darwin.
/// Named on its own, because `check_examples.py` reads it to decide that the
/// example this builds is one the suite runs.
private let quickStartExecutable = "QuickStart"

private func quickStartBinary(configuration: String = "debug") -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ExampleTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Examples
        .appendingPathComponent(".build")
        .appendingPathComponent(configuration)
        .appendingPathComponent(quickStartExecutable)
}

@Suite(
    "quick start",
    .timeLimit(.minutes(1)),
    .enabled(if: namedSocketsAvailable, "needs TMUX_TMPDIR under the suite root")
)
struct QuickStartTests {
    @Test("the example a reader runs first lists the sessions on its socket")
    func theQuickStartLists() async throws {
        let binary = quickStartBinary()
        try #require(
            FileManager.default.isExecutableFile(atPath: binary.path),
            "no QuickStart executable beside the test bundle at \(binary.path)"
        )

        let root = try #require(namedSocketRoot)
        let server = try Server(socketName: "libtmux-swift", tmuxExecutable: tmuxExecutablePath())
        _ = try await server.run([
            TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
            TmuxCommand("new-session", ["-d", "-s", "quickstart"]),
            reaperCommand(root: root.appendingPathComponent("tmux-\(getuid())/libtmux-swift")),
        ])
        defer { Task { _ = try? await server.run(TmuxCommand("kill-server")) } }

        let process = Process()
        process.executableURL = binary
        // The example names no tmux, so the child resolves one from PATH. The
        // lane's binary has to come first: a client of a different release
        // reaches the socket, fails to talk to the server behind it, and the
        // listing comes back empty rather than erroring.
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let tmuxDirectory = URL(fileURLWithPath: tmuxExecutablePath())
            .deletingLastPathComponent().path
        process.environment = [
            "TMUX_TMPDIR": root.path,
            "PATH": "\(tmuxDirectory):\(inheritedPath)",
        ]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(printed.contains("quickstart"))
    }
}
