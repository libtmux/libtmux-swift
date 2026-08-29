import Testing

@testable import LibTmuxMCP

@Suite("bounded line handoff", .timeLimit(.minutes(1)))
struct BoundedLineHandoffTests {
    @Test("an eighth unacknowledged line holds the next submission")
    func acknowledgementReleasesNextSubmission() async throws {
        let handoff = BoundedLineHandoff(capacity: 8)
        defer { handoff.close() }
        for line in 0..<8 {
            #expect(handoff.submit("\(line)"))
        }

        let completion = Submission()
        let submission = Task.detached {
            let accepted = handoff.submit("8")
            await completion.record(accepted)
            return accepted
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.value == nil)

        var lines = handoff.makeAsyncIterator()
        #expect(await lines.next() == "0")
        try await Task.sleep(for: .milliseconds(20))
        let accepted = await completion.value
        #expect(accepted == true)
        guard accepted == true else { return }
        #expect(await submission.value)
    }
}

private actor Submission {
    private(set) var value: Bool?

    func record(_ value: Bool) {
        self.value = value
    }
}
