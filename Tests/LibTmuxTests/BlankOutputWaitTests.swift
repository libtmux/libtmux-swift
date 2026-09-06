import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("waiting for blank pane output", .timeLimit(.minutes(5)))
struct BlankOutputWaitTests {
    private func bootstrapPane(_ server: Server) async throws -> Pane {
        try #require(try await server.panes().first)
    }

    private func waitForOutput(
        producing shellOutput: String,
        on server: Server,
        in pane: Pane,
        matching patterns: [RegexPattern] = [],
        stoppingAt stops: [RegexPattern] = []
    ) async throws -> OutputWait {
        let ready = "blank-output-ready-\(UUID().uuidString)"
        let print = "blank-output-print-\(UUID().uuidString)"
        let command =
            "\(server.shellInvocation) wait-for -S \(ready); "
            + "\(server.shellInvocation) wait-for \(print); "
            + "\(shellOutput); exec sleep 30"
        try await server.respawn(pane, running: [command])
        try await server.wait(for: ready)
        let hook = try await server.setHook(
            "client-attached",
            to: TmuxCommand("wait-for", ["-S", print]).parsedString
        )
        #expect(hook.isSuccess)

        return try await server.waitForOutput(
            in: pane,
            matching: patterns,
            stoppingAt: stops,
            requiringFreshOutput: true,
            timeout: .seconds(3)
        )
    }

    @Test("an empty pattern matches a new blank-only output event")
    func emptyPatternMatchesBlankOutput() async throws {
        try await withTmuxServer { server in
            let result = try await waitForOutput(
                producing: "printf '\\n'",
                on: server,
                in: try await bootstrapPane(server)
            )

            #expect(result.outcome == .matched)
            #expect(result.matched == nil)
            #expect(result.sawNewOutput)
        }
    }

    @Test("a blank-line pattern matches a new blank-only output event")
    func blankPatternMatchesBlankOutput() async throws {
        try await withTmuxServer { server in
            let result = try await waitForOutput(
                producing: "printf '\\n'",
                on: server,
                in: try await bootstrapPane(server),
                matching: [try RegexPattern("^$")]
            )

            #expect(result.outcome == .matched)
            #expect(result.matched == "^$")
            #expect(result.matchedIndex == 0)
            #expect(result.sawNewOutput)
        }
    }

    @Test("a nonblank line does not add a blank match after its newline")
    func nonblankLineDoesNotMatchBlankPattern() async throws {
        try await withTmuxServer { server in
            let result = try await waitForOutput(
                producing: "printf 'VISIBLE\\n'",
                on: server,
                in: try await bootstrapPane(server),
                matching: [try RegexPattern("^$")]
            )

            #expect(result.outcome == .timedOut)
            #expect(result.matched == nil)
            #expect(result.sawNewOutput)
            #expect(result.tail == ["VISIBLE"])
        }
    }

    @Test("a captured stop precedes the empty-pattern output fallback")
    func stopPrecedesEmptyPatternFallback() async throws {
        try await withTmuxServer { server in
            let result = try await waitForOutput(
                producing: "printf 'FAILED\\n'",
                on: server,
                in: try await bootstrapPane(server),
                stoppingAt: [try RegexPattern("^FAILED$")]
            )

            #expect(result.outcome == .stopped)
            #expect(result.matched == "^FAILED$")
            #expect(result.matchedIndex == 0)
            #expect(result.sawNewOutput)
        }
    }

    @Test("a topology wake does not count as pane output")
    func topologyWakeDoesNotMatch() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.respawn(pane, running: ["sleep", "30"])
            let windowName = "quiet-topology-\(UUID().uuidString)"
            let hook = try await server.setHook(
                "client-attached",
                to: TmuxCommand(
                    "new-window",
                    ["-d", "-t", "bootstrap", "-n", windowName, "sleep 30"]
                ).parsedString
            )
            #expect(hook.isSuccess)

            let result = try await server.waitForOutput(
                in: pane,
                requiringFreshOutput: true,
                timeout: .milliseconds(1200)
            )

            #expect(result.outcome == .timedOut)
            #expect(!result.sawNewOutput)
            #expect(try await server.windows().contains { $0.name == windowName })
        }
    }
}
