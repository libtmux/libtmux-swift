import Foundation
import Testing

@Suite("lifecycle programs", .timeLimit(.minutes(5)))
struct LifecycleTests {
    @Test("six imported programs execute unchanged on harness defaults")
    func programs() throws {
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // These names also bind the displayed source to live consumer execution.
        let programs = [
            "OwnedHierarchy", "AdoptExisting", "FindResources", "DiscoverRunning",
            "OwnDisposableServer", "FixtureLifecycle",
        ]
        #expect(programs.count == 6)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3", examples.appendingPathComponent("Tests/lifecycle_harness.py").path,
            examples.appendingPathComponent(".build/debug").path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
