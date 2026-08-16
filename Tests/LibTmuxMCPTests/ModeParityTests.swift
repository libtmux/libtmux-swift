import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// The tools are built from a server, so they inherit whichever mode that
/// server carries. Nothing in this consumer knows a mode exists, which is the
/// property worth holding on to.
@Suite("tools under either mode", .timeLimit(.minutes(1)))
struct ModeParityTests {
    @Test("a tool answers the same over a connection as over a process")
    func toolsAnswerTheSameEitherWay() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "alpha")

            // The same tool, reached through the same switch a caller would use.
            let call = ToolCall(name: "list_sessions")
            func answer(under mode: TmuxMode) async throws -> Data {
                try await server.using(mode) { server in
                    Data(try await TmuxTools(server: server).call(call).text.utf8)
                }
            }

            let direct = try await answer(under: .direct)
            let connected = try await answer(under: .connected(to: "bootstrap"))

            // Same tool, same request, same JSON — except for the one thing a
            // connection changes about the server it is asking: it is itself a
            // client, so the session it attached to reads as attached.
            let strip: (Data) throws -> [[String: Any]] = { data in
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rows = body?["sessions"] as? [Any] ?? []
                return rows.compactMap { $0 as? [String: Any] }
                    .map { row in row.filter { $0.key != "isAttached" } }
                    .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            }

            let directRows = try strip(direct)
            let connectedRows = try strip(connected)
            #expect(directRows.count == connectedRows.count)
            #expect(directRows.count >= 2)
            #expect(
                directRows.map { $0["name"] as? String }
                    == connectedRows.map { $0["name"] as? String }
            )
        }
    }
}
