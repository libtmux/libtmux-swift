import Foundation
import Testing

@testable import LibTmux
@testable import TmuxFixture

@Suite("named socket namespace")
struct NamedSocketNamespaceTests {
    @Test("the allowed root requires a path-component boundary")
    func rootRequiresAComponentBoundary() {
        let root = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
        #expect(isAllowedNamedSocketRoot(root))
        #expect(isAllowedNamedSocketRoot(root.appendingPathComponent("named")))
        #expect(!isAllowedNamedSocketRoot(URL(fileURLWithPath: "\(root.path)-other")))
    }

    @Test("the reaper accepts only owned descendants and shell-quotes them")
    func reaperRootsAreScopedAndQuoted() throws {
        let owned = URL(
            fileURLWithPath: "/tmp/libtmux-swift-test/case's socket"
        )
        let command = try reaperCommand(root: owned)
        let script = try #require(command.arguments.last)

        #expect(script.contains("rm -rf \(shellQuoted(owned.path));"))
        #expect(throws: UnsafeReaperRoot.self) {
            try reaperCommand(root: URL(fileURLWithPath: "/"))
        }
        #expect(throws: UnsafeReaperRoot.self) {
            try reaperCommand(root: URL(fileURLWithPath: "/tmp/libtmux-swift-test"))
        }
        #expect(throws: UnsafeReaperRoot.self) {
            try reaperCommand(root: URL(fileURLWithPath: "/tmp/libtmux-python-test/case"))
        }
    }
}

/// A socket *name* is the half of ``Endpoint`` a path-addressed fixture never
/// reaches, and tmux resolves a name inside `TMUX_TMPDIR` rather than beside
/// the path it was given. Until these ran, a bug in that half would have shown
/// up only as the suite addressing the machine-wide default directory.
@Suite(
    "addressing a server by name",
    .timeLimit(.minutes(5)),
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
