import Foundation
import Testing

@Suite("ordinary session program", .timeLimit(.minutes(5)))
struct OrdinarySessionTests {
    @Test("the unchanged example runs on private defaults and cleans up on failure")
    func ordinaryProgram() throws {
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = examples.appendingPathComponent(".build/debug/OrdinarySession")
        let probe = examples.appendingPathComponent(".build/debug/EndpointSnapshotProbe")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", examples.appendingPathComponent("Tests/ordinary_session_harness.py").path,
            binary.path, "--snapshot-probe", probe.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
