import Testing
import TmuxFixture

@testable import LibTmux

@Suite("environment", .timeLimit(.minutes(5)))
struct EnvironmentTests {
    @Test("tmux clients inherit the caller's environment unchanged")
    func processEnvironmentIsInherited() {
        let caller = [
            "LC_ALL": "fr_FR.UTF-8",
            "LIBTMUX_SENTINEL": "kept",
            "PATH": "/usr/bin:/bin",
            "TMUX_TMPDIR": "/tmp/libtmux-swift-test/named",
        ]

        #expect(TmuxProcessEnvironment.variables(readingFrom: caller) == caller)

        var nested = caller
        nested["TMUX"] = "/tmp/libtmux-swift-test/outer,1,0"
        nested["TMUX_PANE"] = "%7"
        #expect(TmuxProcessEnvironment.controlAttachmentVariables(readingFrom: nested) == caller)
    }

    @Test("opening control mode does not rewrite the session environment")
    func controlAttachmentPreservesSessionEnvironment() async throws {
        try await withTmuxServer { server in
            let scope = EnvironmentScope.session("bootstrap")
            try await server.setEnvironment("DISPLAY", to: "preserved", in: scope)

            try await server.withControlMode(attachingTo: "bootstrap") { _ in }

            #expect(try await server.environmentValue("DISPLAY", in: scope) == "preserved")
        }
    }

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

    @Test("an individual environment value preserves embedded and trailing newlines")
    func multilineValue() async throws {
        try await withTmuxServer { server in
            let value = "first\nNOT_A_VARIABLE=second\nlast=λ\n"
            try await server.setEnvironment("MULTILINE", to: value, in: .session("bootstrap"))
            #expect(
                try await server.environmentValue("MULTILINE", in: .session("bootstrap")) == value)
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

    @Test("a missing environment session is an error, while an unknown variable is absent")
    func missingSessionIsFailure() async throws {
        try await withTmuxServer { server in
            let unknown = try await server.environmentValue("NEVER_SET", in: .session("bootstrap"))
            #expect(unknown == nil)
            await #expect(throws: TmuxError.self) {
                try await server.environmentValue("NEVER_SET", in: .session("missing-session"))
            }
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

    @Test("a name beginning with a dash is a name in every scope")
    func dashPrefixedNamesReachEveryScope() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "dashes")
            try await server.setEnvironment("-GLOBAL", to: "kept")
            #expect(try await server.environmentValue("-GLOBAL") == "kept")
            _ = try await server.setEnvironment("-BORROWED", to: "kept", in: session)
            #expect(
                try await server.environmentValue(
                    "-BORROWED", in: .session(session.id.rawValue)) == "kept")
        }
    }

    @Test("a value ending in a separator survives being set")
    func trailingSeparatorValuesSurvive() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "separators")
            for value in ["a;", "two;;", #"slash\;"#] {
                try await server.setEnvironment("GLOBAL_VALUE", to: value)
                #expect(try await server.environmentValue("GLOBAL_VALUE") == value)
                try await server.setEnvironment(
                    "SESSION_VALUE", to: value, in: .session(session.id.rawValue))
                #expect(
                    try await server.environmentValue(
                        "SESSION_VALUE", in: .session(session.id.rawValue)) == value)
                _ = try await server.setEnvironment("BORROWED_VALUE", to: value, in: session)
                #expect(
                    try await server.environmentValue(
                        "BORROWED_VALUE", in: .session(session.id.rawValue)) == value)
                try await server.setOption("@separator", to: value)
                #expect(try await server.option("@separator") == value)
                try await server.using(.connected(to: "bootstrap")) {
                    try await $0.setEnvironment("CONNECTED_VALUE", to: value)
                }
                #expect(try await server.environmentValue("CONNECTED_VALUE") == value)
            }
        }
    }
}
