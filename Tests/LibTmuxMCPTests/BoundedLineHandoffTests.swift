import Foundation
import Testing
import TmuxFixture

@testable import LibTmuxMCP

@Suite("bounded line handoff", .timeLimit(.minutes(5)))
struct BoundedLineHandoffTests {
    @Test("an eighth unacknowledged line holds the next submission")
    func acknowledgementReleasesNextSubmission() async throws {
        let handoff = BoundedLineHandoff(capacity: 8)
        defer { handoff.close() }
        for line in 0..<8 {
            #expect(handoff.submit("\(line)"))
        }

        // `submit` parks its thread in `NSCondition.wait()`, so it needs a
        // thread that is allowed to park. The executable gives it one for that
        // reason, and so does this case: parking a cooperative thread instead
        // spends one of the pool's few threads, and the pool is shared with
        // every other test in the run.
        let completion = Submission()
        let producer = Thread { completion.record(handoff.submit("8")) }
        producer.start()

        // A negative check is the one place a fixed delay is honest — it can
        // report a held submission early, never late.
        try await Task.sleep(for: .milliseconds(20))
        #expect(completion.value == nil)

        var lines = handoff.makeAsyncIterator()
        #expect(await lines.next() == "0")

        // Waking a parked thread takes as long as a loaded machine takes, so
        // wait for the answer rather than guess at how long it needs. Guessing
        // 20ms is what made this case fail on a macOS runner.
        #expect(try await waitUntil { completion.value != nil })
        #expect(completion.value == true)
    }
}

/// The producer thread's answer, readable from the test's own task.
///
/// A lock rather than an actor: the point of the case is when the parked thread
/// returns, and an actor hop would add a second thing to wait on.
private final class Submission: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Bool?

    var value: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ value: Bool) {
        lock.lock()
        recorded = value
        lock.unlock()
    }
}
