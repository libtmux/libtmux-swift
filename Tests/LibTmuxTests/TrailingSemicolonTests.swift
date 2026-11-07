import Testing
import TmuxFixture

@testable import LibTmux

/// A typed call carries the caller's text as data. tmux ends a command at an
/// argument that ends in `;`, so each of these would otherwise store less than
/// it was given or run the next argument as a command of its own.
@Suite("a trailing semicolon in caller text", .timeLimit(.minutes(5)))
struct TrailingSemicolonTests {
    @Test("setBuffer stores contents that end in a semicolon")
    func bufferContentsKeepTheirSemicolon() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("hello;", named: "a")
            let value = try await server.buffer(named: "a")
            #expect(value == "hello;")
        }
    }

    @Test(
        "setBuffer stores contents that end in a semicolon over a connection",
        .enabled(if: laneSupportsControl, "control mode needs tmux 3.7"))
    func bufferContentsKeepTheirSemicolonOverAConnection() async throws {
        try await withTmuxServer { server in
            try await server.using(.connected(to: "bootstrap")) { server in
                try await server.setBuffer("hello;", named: "a")
            }
            let value = try await server.buffer(named: "a")
            #expect(value == "hello;")
        }
    }

    @Test("a buffer name that ends in a semicolon names one buffer")
    func bufferNameKeepsItsSemicolon() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("body", named: "name;")
            let value = try await server.buffer(named: "name;")
            #expect(value == "body")
            let listed = try await server.buffers().map(\.name).contains("name;")
            #expect(listed)
        }
    }

    @Test(
        "deleteBuffer removes the one buffer whose name ends in a semicolon",
        .enabled(if: laneSupportsNamedBufferEditing, "named-buffer deletion needs tmux 3.4"))
    func deleteBufferNameKeepsItsSemicolon() async throws {
        try await withTmuxServer { server in
            try await server.setBuffer("body", named: "name;")
            try await server.setBuffer("other", named: "name")
            try await server.deleteBuffer(named: "name;")
            let afterDelete = try await server.buffer(named: "name;")
            #expect(afterDelete == nil)
            let other = try await server.buffer(named: "name")
            #expect(other == "other")
        }
    }

    @Test("an option name that ends in a semicolon is refused, not chained")
    func optionNameDoesNotChain() async throws {
        try await withTmuxServer { server in
            // A user option may carry a semicolon in its name; tmux must see
            // the value `set-option` as a value, not as the next command.
            let named = try await server.setOption("@n;", to: "set-option")
            #expect(named.isSuccess, Comment(rawValue: named.errorText))

            let killer = try await server.setOption("mouse;", to: "kill-server")
            #expect(
                killer.errorText.contains("invalid option"), Comment(rawValue: killer.errorText))
            let running = try await server.isRunning()
            #expect(running, "kill-server ran as a chained command")
        }
    }

    @Test("a guarded option name that ends in a semicolon is refused, not chained")
    func guardedOptionNameDoesNotChain() async throws {
        try await withTmuxServer { server in
            let session = try #require(try await server.sessions().first)
            let reply = try await server.setOption(
                "mouse;", to: "kill-server", scope: .session(session))
            #expect(!reply.isSuccess)
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("an option name that ends in a semicolon can be set, read and unset")
    func optionNameRoundTrips() async throws {
        try await withTmuxServer { server in
            let set = try await server.setOption("@keep;", to: "value", scope: .server)
            #expect(set.isSuccess, Comment(rawValue: set.errorText))
            let stored = try await server.option("@keep;", scope: .server)
            #expect(stored == "value")

            let unset = try await server.unsetOption("@keep;", scope: .server)
            #expect(unset.isSuccess, Comment(rawValue: unset.errorText))
            let gone = try await server.option("@keep;", scope: .server)
            #expect(gone == nil)
        }
    }

    @Test("an environment name that ends in a semicolon is not chained")
    func environmentNameDoesNotChain() async throws {
        try await withTmuxServer { server in
            _ = try await server.setEnvironment("SWIFTPROBE_A;", to: "kill-server")
            let running = try await server.isRunning()
            #expect(running, "kill-server ran as a chained command")
            let value = try await server.environmentValue("SWIFTPROBE_A;")
            #expect(value == "kill-server")
        }
    }

    @Test("a hook name that ends in a semicolon reaches tmux whole")
    func hookNameKeepsItsSemicolon() async throws {
        try await withTmuxServer { server in
            let reply = try await server.setHook("alert-bell;", to: "kill-server")
            // tmux names the hook it was given; split at the semicolon, it
            // complains of a missing value instead.
            #expect(reply.errorText.contains("alert-bell;"), Comment(rawValue: reply.errorText))
            let running = try await server.isRunning()
            #expect(running)
        }
    }

    @Test("a format that ends in a semicolon is evaluated whole")
    func formatKeepsItsSemicolon() async throws {
        try await withTmuxServer { server in
            let value = try await server.format("kept;")
            #expect(value == "kept;")
        }
    }
}
