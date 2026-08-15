import Testing
import TmuxFixture

@testable import LibTmux

@Suite("options and hooks")
struct OptionsTests {
    @Test("a user option round-trips through the server table")
    func userOptionRoundTrips() async throws {
        try await withTmuxServer { server in
            let set = try await server.setOption("@project", to: "libtmux", scope: .server)
            #expect(set.isSuccess, Comment(rawValue: set.errorText))

            let value = try await server.option("@project", scope: .server)
            #expect(value == "libtmux")

            let options = try await server.options(.server)
            let stored = try #require(options.first { $0.name == "@project" })
            #expect(stored.value == "libtmux")
            #expect(stored.scope == .server)
            #expect(stored.isUserOption)
        }
    }

    @Test("a value containing spaces keeps them")
    func valueWithSpacesKeepsThem() async throws {
        try await withTmuxServer { server in
            _ = try await server.setOption("@title", to: "two words", scope: .server)
            // Only the first space separates a name from its value.
            let value = try await server.option("@title", scope: .server)
            #expect(value == "two words")

            let options = try await server.options(.server)
            let stored = try #require(options.first { $0.name == "@title" })
            #expect(stored.value.contains("two words"))
        }
    }

    @Test("an option that was never set reports nothing")
    func unsetOptionReportsNothing() async throws {
        try await withTmuxServer { server in
            let value = try await server.option("@absent", scope: .server)
            #expect(value == nil)
        }
    }

    @Test("session options are a different table from server options")
    func sessionOptionsAreADifferentTable() async throws {
        try await withTmuxServer { server in
            _ = try await server.setOption("@scoped", to: "session", scope: .session)
            let session = try await server.option("@scoped", scope: .session)
            let server_ = try await server.option("@scoped", scope: .server)
            #expect(session == "session")
            #expect(server_ == nil)
        }
    }

    @Test("only bound hooks are reported, with their name, index, and command")
    func hookReportsItsParts() async throws {
        try await withTmuxServer { server in
            let set = try await server.setHook("alert-bell", to: "display-message ding")
            #expect(set.isSuccess, Comment(rawValue: set.errorText))

            let hooks = try await server.hooks()
            let bell = try #require(hooks.first { $0.name == "alert-bell" })
            #expect(bell.index == 0)
            #expect(bell.command.contains("display-message"))
            #expect(bell.scope == .global)
            // tmux lists every hook name it knows; the unbound ones are not
            // hooks, so they are not reported.
            #expect(hooks.allSatisfy { !$0.command.isEmpty })
            #expect(hooks.count < 20)
        }
    }

    @Test("a session's hooks are a different table from the global ones")
    func sessionHooksAreADifferentTable() async throws {
        try await withTmuxServer { server in
            let session = try await server.newSession(named: "hooked")
            _ = try await server.setHook("alert-bell", to: "display-message global")
            _ = try await server.setHook(
                "alert-bell",
                to: "display-message local",
                in: .session(session.id)
            )

            let global = try #require(
                try await server.hooks().first { $0.name == "alert-bell" }
            )
            let local = try #require(
                try await server.hooks(.session(session.id))
                    .first { $0.name == "alert-bell" }
            )
            #expect(global.command.contains("global"))
            #expect(local.command.contains("local"))
            #expect(local.scope == .session(session.id))
        }
    }

    @Test("a hook set without an index replaces every command bound to the name")
    func settingWithoutAnIndexReplacesTheArray() async throws {
        try await withTmuxServer { server in
            _ = try await server.setHook("alert-bell", to: "display-message zero", at: 0)
            _ = try await server.setHook("alert-bell", to: "display-message one", at: 1)
            #expect(try await server.hooks().filter { $0.name == "alert-bell" }.count == 2)

            _ = try await server.setHook("alert-bell", to: "display-message replaced")

            let bound = try await server.hooks().filter { $0.name == "alert-bell" }
            #expect(bound.count == 1)
            #expect(bound.first?.index == 0)
            #expect(bound.first?.command.contains("replaced") == true)
        }
    }

    @Test("unsetting a hook unbinds it while tmux keeps knowing the name")
    func unsettingAHookLeavesTheNameBehind() async throws {
        try await withTmuxServer { server in
            _ = try await server.setHook("alert-bell", to: "display-message ding")
            let unset = try await server.unsetHook("alert-bell")
            #expect(unset.isSuccess, Comment(rawValue: unset.errorText))

            #expect(!(try await server.hooks()).contains { $0.name == "alert-bell" })

            // tmux empties the array but leaves the name listed, with no index
            // and no command. That bare line is what the reported listing drops
            // — asserted here so the reason stays visible if tmux changes it.
            let raw = try await server.run(TmuxCommand("show-hooks", ["-g"]))
            #expect(raw.text.split(separator: "\n").contains("alert-bell"))
        }
    }

    @Test("unsetting a hook nothing was bound to is not a failure")
    func unsettingAnUnboundHookSucceeds() async throws {
        try await withTmuxServer { server in
            let unset = try await server.unsetHook("after-copy-mode")
            #expect(unset.isSuccess, Comment(rawValue: unset.errorText))
        }
    }

    @Test("a name tmux does not know comes back as a reply, not an error")
    func settingAnUnknownHookReportsWhy() async throws {
        try await withTmuxServer { server in
            let set = try await server.setHook("not-a-hook", to: "display-message x")
            #expect(!set.isSuccess)
            #expect(set.errorText.contains("not-a-hook"))
        }
    }

    @Test("a hook can be run on demand")
    func hookRunsOnDemand() async throws {
        try await withTmuxServer { server in
            _ = try await server.setHook("alert-bell", to: "set-option -s @rang yes")
            let run = try await server.runHook("alert-bell")
            #expect(run.isSuccess, Comment(rawValue: run.errorText))
            // The hook's own command chose the server table, so that is where
            // the evidence it ran has to be read from.
            #expect(try await server.option("@rang", scope: .server) == "yes")
        }
    }

    @Test("a user option can be unset")
    func userOptionCanBeUnset() async throws {
        try await withTmuxServer { server in
            _ = try await server.setOption("@temporary", to: "yes", scope: .server)
            #expect(try await server.option("@temporary", scope: .server) == "yes")

            let unset = try await server.unsetOption("@temporary", scope: .server)
            #expect(unset.isSuccess, Comment(rawValue: unset.errorText))
            #expect(try await server.option("@temporary", scope: .server) == nil)
        }
    }
}
