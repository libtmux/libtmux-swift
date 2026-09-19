import Testing
import TmuxFixture

@testable import LibTmux

@Suite("options and hooks")
struct OptionsTests {
    @Test("option names cannot become mutation or listing flags")
    func leadingDashOptionNamesRemainPositional() async throws {
        try await withTmuxServer { server in
            try await server.setOption("@held", to: "yes", scope: .server)
            await #expect(throws: TmuxError.self) {
                try await server.setOption("-u", to: "@held", scope: .server)
            }
            #expect(try await server.option("@held", scope: .server) == "yes")
            await #expect(throws: TmuxError.self) {
                _ = try await server.resolvedOption("-v", scope: .server)
            }
            do {
                try await server.unsetOption("-q", scope: .server)
                Issue.record("a flag-shaped option name was accepted")
            } catch let TmuxError.commandFailed(_, _, reason) {
                #expect(reason.contains("option: -q"), Comment(rawValue: reason))
            }
        }
    }

    @Test("hook names cannot become mutation flags")
    func leadingDashHookNamesRemainPositional() async throws {
        try await withTmuxServer { server in
            _ = try await server.setHook("alert-bell", to: "display-message held")
            let set = try await server.setHook("-u", to: "alert-bell")
            #expect(!set.isSuccess)
            #expect(try await server.hooks().contains { $0.name == "alert-bell" })
            let unset = try await server.unsetHook("-q")
            #expect(unset.errorText.contains("option: -q"), Comment(rawValue: unset.errorText))
            let run = try await server.runHook("-u")
            #expect(run.isSuccess, Comment(rawValue: run.errorText))
        }
    }

    @Test("a user option round-trips through the server table")
    func userOptionRoundTrips() async throws {
        try await withTmuxServer { server in
            try await server.setOption("@project", to: "libtmux", scope: .server)

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
            try await server.setOption("@title", to: "two words", scope: .server)
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

    @Test("a deliberately empty window option is present")
    func emptyWindowOptionIsPresent() async throws {
        try await withTmuxServer { server in
            let window = try #require(try await server.windows().first)
            try await server.setOption("@empty", to: "", scope: .window(window))

            #expect(try await server.option("@empty", scope: .window(window)) == "")
            #expect(try await server.option("@absent", scope: .window(window)) == nil)
        }
    }

    @Test("session options are a different table from server options")
    func sessionOptionsAreADifferentTable() async throws {
        try await withTmuxServer { server in
            let target = try #require(try await server.sessions().first)
            try await server.setOption("@scoped", to: "session", scope: .session(target))
            let session = try await server.option("@scoped", scope: .session(target))
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
                in: .session(session.id.rawValue)
            )

            let global = try #require(
                try await server.hooks().first { $0.name == "alert-bell" }
            )
            let local = try #require(
                try await server.hooks(.session(session.id.rawValue))
                    .first { $0.name == "alert-bell" }
            )
            #expect(global.command.contains("global"))
            #expect(local.command.contains("local"))
            #expect(local.scope == .session(session.id.rawValue))
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
            try await server.setOption("@temporary", to: "yes", scope: .server)
            #expect(try await server.option("@temporary", scope: .server) == "yes")

            try await server.unsetOption("@temporary", scope: .server)
            #expect(try await server.option("@temporary", scope: .server) == nil)
        }
    }

    @Test("a flag, a number and a choice read back as their types")
    func typedOptionsRoundTrip() async throws {
        try await withTmuxServer { server in
            try await server.setOption(.mouse, to: true)
            try await server.setOption(.historyLimit, to: 4321)
            try await server.setOption(.statusPosition, to: .top)

            #expect(try await server.option(.mouse) == true)
            #expect(try await server.option(.historyLimit) == 4321)
            #expect(try await server.option(.statusPosition) == .top)
            // The typed calls wrote the global session table, not a session.
            #expect(try await server.option("mouse", scope: .globalSession) == "on")
        }
    }

    @Test("every catalogued key reads from the table it names")
    func catalogueTablesAreTmuxs() async throws {
        try await withTmuxServer { server in
            // A key naming the wrong table reads nil: the listing of that
            // table does not include the option.
            let flags = try await [
                server.option(.mouse), server.option(.synchronizePanes),
                server.option(.automaticRename), server.option(.exitEmpty),
            ]
            let numbers = try await [server.option(.historyLimit), server.option(.baseIndex)]
            let environment = try await server.option(.updateEnvironment)

            #expect(!flags.contains(nil), "\(flags)")
            #expect(!numbers.contains(nil), "\(numbers)")
            #expect(environment?.isEmpty == false)
        }
    }

    @Test("a value tmux refuses throws with tmux's reason")
    func refusedValueThrows() async throws {
        try await withTmuxServer { server in
            do {
                try await server.setOption(.historyLimit, to: -1)
                Issue.record("a negative history-limit was accepted")
            } catch let TmuxError.commandFailed(command, _, reason) {
                #expect(command == "set-option", Comment(rawValue: command))
                #expect(reason.contains("-1"), Comment(rawValue: reason))
            }
            #expect(try await server.option(.historyLimit) != -1)
        }
    }

    @Test("a scope the key's table cannot hold is refused before tmux sees it")
    func wrongTableIsRefusedLocally() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let window = try #require(try await server.windows().first)
            do {
                try await server.setOption(.mouse, to: true, scope: .window(window))
                Issue.record("a session option was sent to a window's table")
            } catch let TmuxError.rejectedLocally(reason) {
                #expect(reason.contains("mouse"), Comment(rawValue: reason))
            }
            #expect(try await server.option("mouse", scope: .session(session)) == nil)
        }
    }

    @Test("tmux itself does not refuse a set aimed at the wrong table")
    func tmuxRedirectsAWrongTableSet() async throws {
        try await withTmuxServer { server in
            // Why the keys carry a table: this exits 0 and lands on the
            // current session, leaving the global table as it was.
            try await server.setOption("mouse", to: "on", scope: .server)

            let session = try #require(try await server.sessions().first)
            #expect(try await server.option("mouse", scope: .globalSession) == "off")
            #expect(try await server.option("mouse", scope: .session(session)) == "on")
        }
    }

    @Test("text that is not the key's type is a decoding failure, not absence")
    func mistypedTextFailsToDecode() async throws {
        try await withTmuxServer { server in
            try await server.setOption("@count", to: "many", scope: .server)
            do {
                _ = try await server.option(TmuxOptionKey<Int>("@count", table: .server))
                Issue.record("\"many\" decoded as an Int")
            } catch TmuxError.decodingFailed(.invalidValue(_, "@count", "many")) {}
        }
    }

    @Test("an array keeps its indices, gaps and all")
    func sparseArrayKeepsIndices() async throws {
        try await withTmuxServer { server in
            // Emptying is a string set, so it names the table itself: the
            // default `.server` scope would empty the current session's copy.
            try await server.setOption("update-environment", to: "", scope: .globalSession)
            #expect(try await server.option(.updateEnvironment) == [:])

            let array = TmuxOptionKey.updateEnvironment
            try await server.setOption(array[0], to: "A")
            try await server.setOption(array[1], to: "B C")
            try await server.setOption(array[4], to: "D")
            #expect(try await server.option(.updateEnvironment) == [0: "A", 1: "B C", 4: "D"])
            #expect(try await server.option(array[1]) == "B C")

            try await server.unsetOption(TmuxOptionKey.updateEnvironment[1])
            #expect(try await server.option(.updateEnvironment) == [0: "A", 4: "D"])
        }
    }
}

/// A choice option, declared the way a caller outside the library would.
enum StatusPosition: String, TmuxOptionValue {
    case top, bottom
}

extension TmuxOptionKey<StatusPosition> {
    static var statusPosition: Self { Self("status-position", table: .session) }
}
