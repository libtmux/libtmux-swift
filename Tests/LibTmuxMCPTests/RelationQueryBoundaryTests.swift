import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("relation queries across the boundary", .timeLimit(.minutes(1)))
struct RelationQueryBoundaryTests {
    @Test("a relation query travels as one value and selects by it")
    func relationQueryTravelsAsOneValue() async throws {
        try await withTmuxServer { server in
            let editors = try await server.newSession(named: "editors")
            let window = try #require(try await server.snapshot().windows(of: editors).first)
            let pane = try #require(try await server.snapshot().panes(of: window).first)
            try await server.run("exec sleep 61", in: pane)

            let running = try await waitUntil {
                try await server.panes()
                    .first { $0.id == pane.id }?.currentCommand == "sleep"
            }
            #expect(running)

            let query = RelationQuery(
                .some,
                try FilterExpr<Pane>.where(\.currentCommand, .equals("sleep"))
            )
            let encoded = String(decoding: try JSONEncoder().encode(query), as: UTF8.self)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "list_sessions",
                    arguments: .object(["pane_relation": .string(encoded)])
                )
            )
            // "sessions where some pane runs sleep" — quantifier and expression
            // crossed together, which two loose arguments could not guarantee.
            #expect(
                try outcome.rows("sessions", SessionResult.self).map(\.name) == ["editors"]
            )
        }
    }

    @Test("a relation query round-trips without losing its quantifier")
    func relationQueryRoundTrips() throws {
        let query = RelationQuery(
            .every,
            try FilterExpr<Pane>.where(\.isActive, .equals(true))
        )
        let data = try JSONEncoder().encode(query)
        let decoded = try JSONDecoder().decode(RelationQuery<Pane>.self, from: data)
        #expect(decoded == query)
        #expect(decoded.quantifier == .every)
    }
}
