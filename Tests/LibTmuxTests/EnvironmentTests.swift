import Testing
import TmuxFixture

@testable import LibTmux

@Suite("environment", .timeLimit(.minutes(1)))
struct EnvironmentTests {
    @Test("a variable set in a session is read back from it")
    func sessionVariableRoundTrips() async throws {
        try await withTmuxServer { server in
            let scope = EnvironmentScope.session("bootstrap")
            try await server.setEnvironment("EDITOR", to: "nvim", in: scope)

            let editor = try await server.environmentValue("EDITOR", in: scope)
            #expect(editor == "nvim")
            let listed = try await server.environment(scope)
            #expect(listed.contains(TmuxEnvironmentVariable(name: "EDITOR", value: "nvim")))
        }
    }

    @Test("the global environment is a different one from a session's")
    func globalAndSessionAreSeparate() async throws {
        try await withTmuxServer { server in
            try await server.setEnvironment("WHERE", to: "global", in: .global)
            try await server.setEnvironment(
                "WHERE", to: "session", in: .session("bootstrap"))

            let global = try await server.environmentValue("WHERE", in: .global)
            let session = try await server.environmentValue(
                "WHERE", in: .session("bootstrap"))
            #expect(global == "global")
            #expect(session == "session")
        }
    }

    @Test("a value keeps everything after the first equals sign")
    func valuesMayContainEquals() async throws {
        try await withTmuxServer { server in
            let awkward = "a=b=c"
            try await server.setEnvironment("PAIRS", to: awkward, in: .global)
            let pairs = try await server.environmentValue("PAIRS", in: .global)
            #expect(pairs == awkward)
        }
    }

    @Test("an empty value is a value, not an absence")
    func emptyValuesSurvive() async throws {
        try await withTmuxServer { server in
            try await server.setEnvironment("BLANK", to: "", in: .global)
            let blank = try await server.environmentValue("BLANK", in: .global)
            #expect(blank == "")
            let listed = try await server.environment(.global)
            #expect(listed.contains { $0.name == "BLANK" && $0.value == "" })
        }
    }

    @Test("removing is not unsetting")
    func removalIsDistinctFromUnset() async throws {
        try await withTmuxServer { server in
            try await server.setEnvironment("KEEP", to: "yes", in: .global)
            try await server.setEnvironment("DROP", to: "yes", in: .global)

            try await server.unsetEnvironment("KEEP", in: .global)
            try await server.removeEnvironment("DROP", in: .global)

            let listed = try await server.environment(.global)
            // Unset leaves nothing behind.
            #expect(!listed.contains { $0.name == "KEEP" })
            // Removed is still listed, so that a new process starts without it.
            let dropped = try #require(listed.first { $0.name == "DROP" })
            #expect(dropped.isRemoved)
            #expect(dropped.value == nil)
        }
    }

    @Test("an unknown variable is absent, not an error")
    func unknownVariableIsAbsent() async throws {
        try await withTmuxServer { server in
            let missing = try await server.environmentValue("NEVER_SET", in: .global)
            #expect(missing == nil)
        }
    }

    @Test(
        "each line tmux prints reads back as what it means",
        arguments: [
            ("FOO=bar", "FOO", String?.some("bar")),
            ("EMPTY=", "EMPTY", String?.some("")),
            ("PAIRS=a=b", "PAIRS", String?.some("a=b")),
            ("-GONE", "GONE", String?.none),
        ]
    )
    func linesParse(_ line: String, _ name: String, _ value: String?) throws {
        let parsed = try #require(TmuxEnvironmentVariable(line: line))
        #expect(parsed.name == name)
        #expect(parsed.value == value)
    }

    @Test("a line that is neither shape is not invented into a variable")
    func malformedLinesAreDropped() {
        for line in ["", "-", "novalue"] {
            #expect(TmuxEnvironmentVariable(line: line) == nil)
        }
    }
}
