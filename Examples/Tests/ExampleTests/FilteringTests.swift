import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("filtering", .timeLimit(.minutes(1)))
struct FilteringTests {
    @Test("a filter expression selects the same panes the predicate would")
    func theExpressionAgreesWithThePredicate() async throws {
        try await withTmuxServer { server in
            // Nothing here runs an editor, so the honest answer from both
            // examples is none — and a filter that matched anyway would be the
            // bug worth catching. Depending on an editor being installed would
            // trade that for a test that skips on most machines.
            let byPredicate = try await locally(server)
            let byExpression = try await travelling(server)
            #expect(byPredicate.isEmpty)
            #expect(byExpression.isEmpty)
            #expect(byPredicate.map(\.id) == byExpression.map(\.id))

            // The positive control: agreement between two empty answers proves
            // nothing on its own, so this shows the same machinery selecting
            // what is actually there.
            let shells = try FilterExpr<Pane>.where(\.currentCommand, .isIn(["sh"]))
            #expect(try await server.panes().filter(shells).count == 1)
        }
    }
}
