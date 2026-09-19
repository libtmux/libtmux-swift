import Foundation
import Testing

@testable import LibTmux

/// Never observes cancellation, which a transport a consumer wrote may not.
private struct UncooperativeTransport: ProcessTransport {
    let work: Duration

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        let deadline = ContinuousClock.now.advanced(by: work)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return TmuxReply(standardOutput: [], standardError: [], exitCode: 0)
    }
}

@Suite("command deadline", .hangLimit)
struct CommandDeadlineTests {
    private func bounded(_ transport: any ProcessTransport, _ bound: Duration) throws -> Server {
        try Server(
            socketPath: "/tmp/libtmux-swift-test/deadline-contract/socket",
            transport: transport
        ).withTimeout(bound)
    }

    @Test("a bound holds even when the transport ignores cancellation")
    func boundHoldsAgainstAnUncooperativeTransport() async throws {
        let bound = Duration.milliseconds(250)
        let server = try bounded(UncooperativeTransport(work: .seconds(3)), bound)
        let started = ContinuousClock.now

        var reported: Duration?
        do {
            _ = try await server.run(TmuxCommand("display-message"))
        } catch {
            if case let .timedOut(after) = error { reported = after }
        }

        // The bound is the claim. A transport that never checks cancellation
        // is exactly what it has to hold against: the cooperative case needs
        // no bound to return.
        let elapsed = started.duration(to: .now)
        #expect(reported != nil, "expected a timeout, took \(elapsed)")
        #expect(elapsed < .seconds(1), "bounded call took \(elapsed)")
    }

    @Test("a timeout never names a duration the call did not wait")
    func timeoutNamesWhatItActuallyWaited() async throws {
        let bound = Duration.milliseconds(250)
        let server = try bounded(UncooperativeTransport(work: .seconds(3)), bound)
        let started = ContinuousClock.now

        var reported: Duration?
        do {
            _ = try await server.run(TmuxCommand("display-message"))
        } catch {
            if case let .timedOut(after) = error { reported = after }
        }
        let elapsed = started.duration(to: .now)

        let named = try #require(reported)
        // Reporting 250ms after blocking for three seconds is a false
        // statement about what happened, whatever the bound was.
        #expect(elapsed < named + .milliseconds(500), "named \(named), took \(elapsed)")
    }
}
