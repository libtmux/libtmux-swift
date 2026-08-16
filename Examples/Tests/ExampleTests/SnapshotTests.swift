import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("snapshots", .timeLimit(.minutes(1)))
struct SnapshotTests {
    @Test("a snapshot resolves the relationships between what it holds")
    func aSnapshotResolvesItsRelations() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let snapshot = try await walkOneConsistentPicture(server, session)

            #expect(!snapshot.windows(of: session).isEmpty)
            for window in snapshot.windows(of: session) {
                #expect(snapshot.session(of: window)?.id == session.id)
                #expect(!snapshot.panes(of: window).isEmpty)
            }
        }
    }
}
