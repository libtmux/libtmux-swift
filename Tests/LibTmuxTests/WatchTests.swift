import Foundation
import Testing
import TmuxFixture

@testable import LibTmux

@Suite("watching a pane without polling", .timeLimit(.minutes(1)))
struct WatchTests {
    /// The bootstrap session's only pane.
    private func bootstrapPane(_ server: Server) async throws -> Pane {
        let panes = try await server.panes()
        return try #require(panes.first)
    }

    /// Runs `wait` while `text` is printed into `pane` over and over.
    ///
    /// A wait only ends on output that arrives after it starts, and opening its
    /// connection takes as long as a loaded machine takes. Printing repeatedly
    /// removes that race, where a longer sleep only makes it rarer — the same
    /// reason `run_shell` exists for callers who cannot tolerate it at all.
    private func printing(
        _ text: String,
        into pane: Pane,
        on server: Server,
        while wait: @Sendable @escaping () async throws -> OutputWait
    ) async throws -> OutputWait {
        try await withThrowingTaskGroup(of: OutputWait?.self) { group in
            group.addTask { try await wait() }
            group.addTask {
                var round = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    round += 1
                    // Numbered so a failed wait's tail says how long the
                    // printer was active.
                    try? await server.run("printf '\\n\(text) \(round)\\n'", in: pane)
                }
                return nil
            }
            var answer: OutputWait?
            while let outcome = try await group.next() {
                if let outcome {
                    answer = outcome
                    break
                }
            }
            group.cancelAll()
            return try #require(answer)
        }
    }

    @Test("a wait ends on the line the command prints")
    func waitEndsOnAPrintedLine() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing(
                "libtmux-ready",
                into: pane,
                on: server
            ) {
                // Fresh output specifically: this is the event-driven path,
                // and without it the wait can legitimately answer from what
                // the printer already put on screen and never exercise it.
                try await server.waitForOutput(
                    in: pane,
                    matching: ["libtmux-ready"],
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }
            #expect(result.outcome == .matched)
            #expect(result.matched == "libtmux-ready")
            #expect(result.sawNewOutput)
        }
    }

    @Test("a stop marker ends the wait before the deadline")
    func stopMarkerEndsTheWaitEarly() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing("FAILED", into: pane, on: server) {
                try await server.waitForOutput(
                    in: pane,
                    matching: ["never-appears-anywhere"],
                    stoppingAt: ["FAILED"],
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }
            #expect(result.outcome == .stopped)
            #expect(result.matchedIndex == 0)
            // The point of a stop marker is the clock: without it this wait
            // would have held the caller for the whole twenty seconds to
            // report the same failure.
            #expect(result.seconds < 15)
        }
    }

    @Test("no patterns means any new output at all")
    func noPatternsMeansAnyOutput() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await printing("anything-at-all", into: pane, on: server) {
                try await server.waitForOutput(
                    in: pane,
                    requiringFreshOutput: true,
                    timeout: .seconds(20)
                )
            }
            #expect(result.outcome == .matched)
            #expect(result.matched == nil)
        }
    }

    @Test("a quiet pane times out saying it stayed quiet")
    func quietPaneReportsNoOutput() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let result = try await server.waitForOutput(
                in: pane,
                matching: ["nothing-will-print-this"],
                timeout: .milliseconds(1200)
            )
            #expect(result.outcome == .timedOut)
            // The field that tells a wrong pattern from a command that never
            // ran. Guessing another pattern is wasted work in the second case.
            #expect(!result.sawNewOutput)
        }
    }

    @Test("text already on screen answers at once, or is waited past on request")
    func staleTextDoesNotMatch() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            try await server.run("printf 'stale-marker\\n'", in: pane)
            try await Task.sleep(for: .milliseconds(400))

            // Checked before it is blocked on: the text is there, so the
            // question is already answered and holding the caller for the
            // timeout would only make the same answer expensive.
            let answered = try await server.waitForOutput(
                in: pane,
                matching: ["stale-marker"],
                timeout: .seconds(30)
            )
            #expect(answered.outcome == .matched)
            #expect(answered.matchedAtEntry)
            #expect(!answered.sawNewOutput)
            // Well inside the thirty-second timeout: `matchedAtEntry` already
            // proves which path answered, and this proves that path did not
            // wait. Loose enough to stay true on a machine running the rest of
            // this suite beside it.
            #expect(answered.seconds < 10)

            let result = try await server.waitForOutput(
                in: pane,
                matching: ["stale-marker"],
                requiringFreshOutput: true,
                timeout: .milliseconds(1200)
            )
            // Re-running a command whose output looks identical has to work, so
            // asking for a fresh line waits past the one on screen.
            #expect(result.outcome == .timedOut)
            #expect(result.matchedAtEntry)
            #expect(!result.sawNewOutput)
        }
    }

    @Test("a repeated line on a multiply linked pane is fresh output")
    func repeatedIdenticalLineIsFresh() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let source = try #require(
                try await server.windowLinks().first { $0.windowID == pane.windowID }
            )
            let destination = try await server.newSession(named: "wait-destination")
            _ = try await server.link(source, into: destination)
            _ = try await server.link(source, into: destination)
            let channel = "libtmux-test-echo-off-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; \(server.shellInvocation) wait-for -S \(channel)",
                in: pane
            )
            try await server.wait(for: channel)
            let seeded = "libtmux-test-seeded-\(UUID().uuidString)"
            try await server.run(
                "printf 'same-marker\\n'; \(server.shellInvocation) wait-for -S \(seeded)",
                in: pane
            )
            try await server.wait(for: seeded)

            let result = try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    try await server.waitForOutput(
                        in: pane,
                        matching: ["^same-marker$"],
                        requiringFreshOutput: true,
                        timeout: .seconds(3)
                    )
                }
                group.addTask {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(250))
                        try? await server.run("printf '\\nsame-marker\\n'", in: pane)
                    }
                    return nil
                }
                var answer: OutputWait?
                while let next = try await group.next() {
                    if let next {
                        answer = next
                        break
                    }
                }
                group.cancelAll()
                return try #require(answer)
            }

            #expect(result.outcome == .matched)
            #expect(result.matched == "^same-marker$")
            #expect(result.sawNewOutput)
        }
    }

    @Test("removing a pane ends its wait")
    func removedPaneEndsItsWait() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            _ = try await server.split(pane)

            let result = try await withThrowingTaskGroup(of: OutputWait?.self) { group in
                group.addTask {
                    try await server.waitForOutput(
                        in: pane,
                        matching: ["never-appears"],
                        timeout: .seconds(5)
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(500))
                    try await server.kill(pane)
                    return nil
                }
                var answer: OutputWait?
                while let next = try await group.next() {
                    if let next {
                        answer = next
                        break
                    }
                }
                group.cancelAll()
                return try #require(answer)
            }

            #expect(result.outcome == .paneClosed)
            #expect(result.seconds < 4)
        }
    }

    @Test("output from a pane respawn ends an established wait")
    func respawnedPaneOutputIsNotLost() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let command = TmuxCommand(
                "respawn-pane",
                [
                    "-k", "-t", pane.id.rawValue,
                    "printf 'after-respawn\\n'; exec sleep 30",
                ]
            ).parsedString
            let hook = try await server.setHook("client-attached", to: command)
            #expect(hook.isSuccess)

            let result = try await server.waitForOutput(
                in: pane,
                matching: ["^after-respawn$"],
                requiringFreshOutput: true,
                timeout: .seconds(3)
            )

            #expect(result.outcome == .matched)
            #expect(result.matched == "^after-respawn$")
            #expect(result.sawNewOutput)
        }
    }

    @Test("a subscription reports the foreground command changing")
    func subscriptionReportsCommandChange() async throws {
        try await withTmuxServer { server in
            let pane = try await bootstrapPane(server)
            let values = try await server.connected(attachingTo: "bootstrap") {
                server, control in
                try await control.watch(
                    FormatSubscription(
                        name: "cmd",
                        scope: .pane(pane.id),
                        format: "#{pane_current_command}"
                    )
                )
                let changes = control.changes(named: "cmd")
                try await server.run("sleep 3", in: pane)
                var seen: [String] = []
                for await change in changes {
                    seen.append(change.value)
                    if seen.contains("sleep") { break }
                }
                return seen
            }
            // No capture, no scrollback, no prompt regex: tmux says what the
            // pane is running whenever that changes.
            #expect(values.contains("sleep"))
        }
    }

    @Test("a subscription change is read field by field")
    func subscriptionChangeParses() throws {
        let change = try #require(
            SubscriptionChange(
                ControlNotification(
                    name: "subscription-changed",
                    arguments: "cmd $0 @1 2 %3 : sleep 5"
                )
            )
        )
        #expect(change.name == "cmd")
        #expect(change.sessionID == "$0")
        #expect(change.windowID == "@1")
        #expect(change.windowIndex == 2)
        #expect(change.paneID == "%3")
        // Everything after the lone `:` is the value, spaces included.
        #expect(change.value == "sleep 5")
    }

    @Test("a session-scoped change carries no window or pane")
    func sessionScopedChangeHasNoPane() throws {
        let change = try #require(
            SubscriptionChange(
                ControlNotification(
                    name: "subscription-changed",
                    arguments: "act $0 - - - : main/1"
                )
            )
        )
        #expect(change.windowID == nil)
        #expect(change.windowIndex == nil)
        #expect(change.paneID == nil)
        #expect(change.value == "main/1")
    }

    @Test(
        "malformed subscription fields are refused",
        arguments: [
            "cmd $01 @1 2 %3 : value",
            "cmd $0 @01 2 %3 : value",
            "cmd $0 @1 two %3 : value",
            "cmd $0 @1 2 %03 : value",
        ]
    )
    func malformedSubscriptionFieldsAreRefused(_ arguments: String) {
        #expect(
            SubscriptionChange(
                ControlNotification(name: "subscription-changed", arguments: arguments)
            ) == nil
        )
    }

    @Test("any other notification is not a subscription change")
    func otherNotificationsAreNotChanges() {
        #expect(
            SubscriptionChange(
                ControlNotification(name: "output", arguments: "%0 hello")
            ) == nil
        )
    }
}
