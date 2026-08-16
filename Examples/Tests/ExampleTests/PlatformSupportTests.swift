import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("platform support", .timeLimit(.minutes(1)))
struct PlatformSupportTests {
    @Test("the version gate reads the release the server actually runs")
    func theVersionGateReadsTheServer() async throws {
        try await withTmuxServer { server in
            let reported = try await branchOnTheReleaseTheServerRuns(server)
            // Every release the package claims to support is 3.x, and the CI
            // matrix builds each of them, so this asserts against whichever one
            // the lane selected rather than against a pinned number.
            #expect(reported.major == 3)
            #expect(reported == (try await server.version()))
        }
    }
}
