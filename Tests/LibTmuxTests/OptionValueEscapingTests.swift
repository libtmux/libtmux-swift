import Testing
import TmuxFixture

@testable import LibTmux

/// A value ending in `;` is escaped when it travels as argv and quoted when a
/// guarded request carries it, and doing both stores the backslash.
@Suite("an option value that ends in a semicolon", .timeLimit(.minutes(5)))
struct OptionValueEscapingTests {
    private static let values = ["hello;", "back\\;", ";"]

    @Test("is stored as written at server scope")
    func serverScope() async throws {
        try await withTmuxServer { server in
            for value in Self.values {
                let set = try await server.setOption("@v", to: value, scope: .server)
                #expect(set.isSuccess, Comment(rawValue: set.errorText))
                let stored = try await server.option("@v", scope: .server)
                #expect(stored == value)
            }
        }
    }

    @Test("is stored as written at global session and global window scope")
    func globalScopes() async throws {
        try await withTmuxServer { server in
            for scope in [OptionScope.globalSession, .globalWindow] {
                for value in Self.values {
                    let set = try await server.setOption("@v", to: value, scope: scope)
                    #expect(set.isSuccess, Comment(rawValue: set.errorText))
                    let stored = try await server.option("@v", scope: scope)
                    #expect(stored == value, "\(scope)")
                }
            }
        }
    }

    @Test("is stored as written at session scope")
    func sessionScope() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            for value in Self.values {
                let set = try await server.setOption("@v", to: value, scope: .session(session))
                #expect(set.isSuccess, Comment(rawValue: set.errorText))
                let stored = try await server.option("@v", scope: .session(session))
                #expect(stored == value)
            }
        }
    }

    @Test("is stored as written at window scope")
    func windowScope() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            for value in Self.values {
                let set = try await server.setOption("@v", to: value, scope: .window(window))
                #expect(set.isSuccess, Comment(rawValue: set.errorText))
                let stored = try await server.option("@v", scope: .window(window))
                #expect(stored == value)
            }
        }
    }

    @Test("is stored as written at pane scope")
    func paneScope() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            for value in Self.values {
                let set = try await server.setOption("@v", to: value, scope: .pane(pane))
                #expect(set.isSuccess, Comment(rawValue: set.errorText))
                let stored = try await server.option("@v", scope: .pane(pane))
                #expect(stored == value)
            }
        }
    }
}
