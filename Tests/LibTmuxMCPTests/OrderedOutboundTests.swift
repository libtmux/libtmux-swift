import Testing

@testable import LibTmuxMCP

@Suite("ordered outbound")
struct OrderedOutboundTests {
    @Test("optional output drops at saturation without delaying mandatory output")
    func optionalOutputDoesNotWaitForCapacity() async throws {
        let outbound = OrderedOutbound(capacity: 1)

        #expect(await outbound.offer("active"))
        #expect(await outbound.next() == "active")
        #expect(await outbound.offer("buffered"))

        let result = OfferResult()
        let optional = Task {
            let accepted = await outbound.offer("optional")
            await result.record(accepted)
            return accepted
        }
        for _ in 0..<100 where await result.value == nil {
            try await Task.sleep(for: .milliseconds(1))
        }
        guard let accepted = await result.value else {
            await outbound.cancel()
            _ = await optional.value
            Issue.record("the optional offer waited for capacity")
            return
        }
        #expect(!accepted)
        #expect(!(await optional.value))

        let mandatory = Task { await outbound.enqueue("mandatory") }
        await outbound.didWrite()
        #expect(await outbound.next() == "buffered")
        #expect(await mandatory.value)
        await outbound.didWrite()
        #expect(await outbound.next() == "mandatory")
        await outbound.didWrite()
        await outbound.finish()
        #expect(await outbound.next() == nil)
    }
}

private actor OfferResult {
    private(set) var value: Bool?

    func record(_ value: Bool) {
        self.value = value
    }
}
