import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

extension TmuxToolsTests {
    @Test("wait ceilings keep fractional and sub-floor precision")
    func waitCeilingsKeepTheirPrecision() throws {
        let server = try Server(socketPath: "/tmp/libtmux-swift-test/unstarted-duration")
        let fractional = TmuxTools(server: server, waitCeiling: .milliseconds(1_250))
            .bounded(10)
        let short = TmuxTools(server: server, waitCeiling: .milliseconds(50))
            .bounded(10)
        let negative = TmuxTools(server: server, waitCeiling: .seconds(-1))

        #expect(fractional.duration == .milliseconds(1_250))
        #expect(fractional.enforced == 1.25)
        #expect(short.duration == .milliseconds(50))
        #expect(short.enforced == 0.05)
        #expect(negative.waitCeiling == .zero)
        #expect(negative.bounded(10).duration == .zero)
    }

    @Test("waiting for a busy pane is bounded")
    func busyPaneWaitUsesTheRequestedTimeout() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, tier: .mutating)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("sleep 2"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            let started = ContinuousClock.now
            await #expect(throws: ToolError.self) {
                try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(wireRef(pane)),
                            "command": .string("printf 'must-not-run\\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            }
            #expect(ContinuousClock.now - started < .seconds(1))
        }
    }

    @Test("a wait is clamped to the ceiling and says what was enforced")
    func waitsAreClampedToTheCeiling() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server, waitCeiling: .seconds(1))
            let outcome = try await tools.call(
                ToolCall(
                    name: "wait_for_output",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "patterns": .array([.string("never-arrives")]),
                        // Far past the ceiling: clamped rather than refused, so
                        // an over-large ask still does something useful.
                        "timeout": .number(9999),
                    ])
                )
            )
            let waited = try outcome.decode(OutputWaitResult.self)
            #expect(waited.effectiveTimeout == 1)
            #expect(waited.outcome == "timedOut")
            #expect(!waited.sawNewOutput)
        }
    }

    @Test("format watches require an exact link when a window appears more than once")
    func linkedPaneWatchesRequireAnExactLink() async throws {
        try await withTmuxServer { server in
            let sourceLink = try #require(try await server.windowLinks().first)
            let source = try #require(
                try await server.windows().first { $0.id == sourceLink.windowID }
            )
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.id }
            )
            let destination = try await server.newSession(named: "wait-destination")
            let destinationLink = try await server.link(source, into: destination)
            let duplicate = try await server.link(source, into: destination)
            let tools = TmuxTools(server: server, caller: nil)

            await #expect(throws: ToolError.self) {
                try await tools.windowLink(for: pane, matching: nil)
            }
            #expect(
                try await tools.windowLink(for: pane, matching: wireRef(destinationLink))
                    == destinationLink
            )
            #expect(
                try await tools.windowLink(for: pane, matching: wireRef(duplicate))
                    == duplicate
            )
            await #expect(throws: ToolError.self) {
                try await tools.windowLink(for: pane, matching: destination.id.rawValue)
            }
        }
    }

    @Test("watch_format ignores another link's initial value")
    func watchFormatFiltersDuplicateWindowLinks() async throws {
        try await withTmuxServer { server in
            let sourceLink = try #require(try await server.windowLinks().first)
            let source = try #require(
                try await server.windows().first { $0.id == sourceLink.windowID }
            )
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.id }
            )
            let destination = try await server.newSession(named: "watch-destination")
            let exact = try await server.link(source, into: destination)
            _ = try await server.link(source, into: destination)

            let outcome = try await TmuxTools(server: server, caller: nil).call(
                ToolCall(
                    name: "watch_format",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "window_link": .string(wireRef(exact)),
                        "format": .string("#{window_index}:#{window_active}"),
                        "timeout": .number(0.5),
                    ])
                )
            )
            #expect(try outcome.decode(FormatWatchResult.self).outcome == "timedOut")
        }
    }

    @Test("a wait whose condition already holds answers instead of blocking")
    func waitAnswersWhenTheConditionAlreadyHolds() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'already-listening\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            let tools = TmuxTools(server: server, waitCeiling: .seconds(30))
            let outcome = try await tools.call(
                ToolCall(
                    name: "wait_for_output",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "patterns": .array([.string("ALREADY-LISTENING")]),
                        "case_insensitive": .bool(true),
                        "timeout": .number(30),
                    ])
                )
            )
            let waited = try outcome.decode(OutputWaitResult.self)
            // The failure this replaces: an agent asked to wait for something
            // that had already happened sat for the whole timeout and then
            // reported a fact it knew on arrival.
            #expect(waited.outcome == "matched")
            #expect(waited.matchedAtEntry)
            #expect(waited.seconds < 5)
        }
    }

    @Test("require_fresh waits past a match that is already on screen")
    func requireFreshWaitsPastAStaleMatch() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'already-listening\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "wait_for_output",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "patterns": .array([.string("already-listening")]),
                        "require_fresh": .bool(true),
                        "timeout": .number(1),
                    ])
                )
            )
            let waited = try outcome.decode(OutputWaitResult.self)
            #expect(waited.outcome == "timedOut")
            #expect(waited.matchedAtEntry)
        }
    }

    @Test("watch_format returns on the value it was told to wait for")
    func watchFormatReturnsOnItsValue() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            // Started first and long enough to outlast the subscription being
            // made: tmux reports a subscribed format's value once on creation
            // and then on change, so a command that has already ended is a
            // change the watch was never there to see.
            try await server.run("exec sleep 60", in: pane)
            let running = try await waitUntil {
                try await server.panes()
                    .first { $0.id == pane.id }?.currentCommand == "sleep"
            }
            #expect(running)

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "watch_format",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "format": .string("#{pane_current_command}"),
                        "matching": .string("^SLEEP$"),
                        "case_insensitive": .bool(true),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(FormatWatchResult.self)
            #expect(result.outcome == "changed")
            #expect(result.value == "sleep")
        }
    }

    @Test("a channel wait returns when the channel is signalled")
    func channelWaitReturnsOnSignal() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .mutating)
            async let waited = tools.call(
                ToolCall(
                    name: "wait_for_channel",
                    arguments: .object([
                        "channel": .string("gate"), "timeout": .number(20),
                    ])
                )
            )
            try await Task.sleep(for: .milliseconds(200))
            _ = try await tools.call(
                ToolCall(
                    name: "signal_channel",
                    arguments: .object(["channel": .string("gate")])
                )
            )
            #expect(try await waited.decode(ChannelWaitResult.self).released)
        }
    }

    @Test("a channel wait that times out says so rather than hanging")
    func channelWaitTimesOut() async throws {
        try await withTmuxServer { server in
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "wait_for_channel",
                    arguments: .object([
                        "channel": .string("never-signalled"), "timeout": .number(1),
                    ])
                )
            )
            #expect(try outcome.decode(ChannelWaitResult.self).released == false)
        }
    }

    @Test("a channel wait failure is not reported as a timeout")
    func channelWaitFailureIsPropagated() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/channel-wait-failure",
            tmuxExecutable: "/tmp/libtmux-swift-test/missing-tmux-\(UUID())"
        )
        await #expect(throws: TmuxError.self) {
            try await TmuxTools(server: server).call(
                ToolCall(
                    name: "wait_for_channel",
                    arguments: .object([
                        "channel": .string("unreachable"), "timeout": .number(1),
                    ])
                )
            )
        }
    }
}
