import ExampleCode
import LibTmux
import Testing
import TmuxFixture

@Suite("lookup examples", .timeLimit(.minutes(2)))
struct LookupExampleTests {
    @Test("finding one object without listing the rest")
    func findsOneObject() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "work")
            let pane = try #require(try await server.panes().first)
            let (work, fresh) = try await findOneObjectWithoutListingTheRest(server, pane)
            #expect(work?.name == "work")
            #expect(fresh?.id == pane.id)
        }
    }

    @Test("a filter that travels to tmux")
    func filterTravels() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let expression = try FilterExpr<Pane>.where(\.id, .equals(pane.id))
            let matching = try await letTmuxDoTheNarrowing(server, expression)
            #expect(matching.map(\.id) == [pane.id])
            // The editor example runs against a server with no editor in it,
            // which is the answer that proves it filtered rather than listed.
            #expect(try await askTmuxForTheEditors(server).isEmpty)
        }
    }

    @Test("a typed error survives a connected scope")
    func typedErrorSurvives() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "main")
            let names = try await typedErrorsAcrossAScope(server)
            #expect(names.contains("main"))
        }
    }
}
