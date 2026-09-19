import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("typed connection scope", .hangLimit)
struct TypedConnectionTests {
    @Test("a session value attaches to that session")
    func sessionValueAttaches() async throws {
        try await withTmuxServer { server in
            let work = try await server.newSession(named: "work")

            let attached = try await server.connected(attachingTo: work) { server, _ in
                try await server.sessions().map(\.name)
            }

            #expect(attached.contains("work"))
        }
    }

    @Test("a session from a replaced daemon is refused, not attached to its namesake")
    func replacedDaemonsSessionIsRefused() async throws {
        try await withTmuxServer { server in
            let stale = try await server.newSession(named: "work")
            _ = try await server.run(TmuxCommand("kill-server"))
            // Same socket, same session name, different daemon: attaching by
            // name would succeed and describe something else entirely.
            let replaced = try await waitUntil {
                if try await server.hasSession("work") { return true }
                return try await server.run(
                    TmuxCommand("new-session", ["-d", "-s", "work"])
                ).isSuccess
            }
            #expect(replaced)

            await #expect(throws: TmuxError.serverRestarted) {
                _ = try await server.connected(attachingTo: stale) { _, _ in 0 }
            }
            // The name form still attaches, which is exactly the difference.
            let byName = try await server.connected(attachingTo: "work") { _, _ in 1 }
            #expect(byName == 1)
        }
    }
}
