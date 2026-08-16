import Testing
import TmuxFixture

@testable import LibTmux

/// A socket *name* is the half of ``Endpoint`` a path-addressed fixture never
/// reaches, and tmux resolves a name inside `TMUX_TMPDIR` rather than beside
/// the path it was given. Until these ran, a bug in that half would have shown
/// up only as the suite addressing the machine-wide default directory.
@Suite(
    "addressing a server by name",
    .timeLimit(.minutes(1)),
    .enabled(if: namedSocketsAvailable, "needs TMUX_TMPDIR under the suite root")
)
struct NamedEndpointTests {
    @Test("a server addressed by name answers the same listings")
    func listingsByName() async throws {
        try await withNamedTmuxServer { server in
            let sessions = try await server.sessions()
            #expect(sessions.count == 1)
            #expect(sessions.first?.name == "bootstrap")
            #expect(server.mode == .direct)
        }
    }

    @Test("a name and a path reach servers that behave the same way")
    func nameAndPathAgree() async throws {
        let byName = try await withNamedTmuxServer { server -> [String] in
            _ = try await server.newSession(named: "work")
            return try await server.sessions().map(\.name).sorted()
        }
        let byPath = try await withTmuxServer { server -> [String] in
            _ = try await server.newSession(named: "work")
            return try await server.sessions().map(\.name).sorted()
        }
        #expect(byName == byPath)
    }
}
