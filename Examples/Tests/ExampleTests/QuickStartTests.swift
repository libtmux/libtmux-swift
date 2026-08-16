import Foundation
import LibTmux
import Testing
import TmuxFixture

/// The quick start is top-level code, so no test can call it; it is spawned.
private func quickStartBinary() -> URL {
    Bundle.main.bundleURL.appendingPathComponent("QuickStart")
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
        let server = try Server(socketName: "work", tmuxExecutable: tmuxExecutablePath())
        _ = try await server.run([
            TmuxCommand("set-option", ["-g", "default-shell", "/bin/sh"]),
            TmuxCommand("new-session", ["-d", "-s", "quickstart"]),
            reaperCommand(root: root.appendingPathComponent("tmux-\(getuid())/work")),
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
