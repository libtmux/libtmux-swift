import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

extension TmuxToolsTests {
    @Test("a rejected tmux command is reported, not thrown")
    func rejectedCommandIsReported() async throws {
        try await withTmuxServer { server in
            let reference = try await serverRef(server)
            let outcome = try await TmuxTools(server: server, tier: .destructive).call(
                ToolCall(
                    name: "run_command",
                    arguments: .object([
                        "server_ref": .string(reference),
                        "command": .string("has-session"),
                        "arguments": .array([.string("-t"), .string("absent")]),
                        "confirm_unsafe": .bool(true),
                    ])
                )
            )
            let result = try outcome.decode(CommandResult.self)
            // A client asking whether a session exists wants the answer.
            #expect(result.exitCode != 0)
            #expect(!result.standardError.isEmpty)
        }
    }

    @Test("a batch says which step failed and stops there")
    func batchAttributesItsFailure() async throws {
        try await withTmuxServer { server in
            let reference = try await serverRef(server)
            let outcome = try await TmuxTools(server: server, tier: .destructive).call(
                ToolCall(
                    name: "run_commands",
                    arguments: .object([
                        "server_ref": .string(reference),
                        "commands": .array([
                            .object(["command": .string("list-sessions")]),
                            .object([
                                "command": .string("has-session"),
                                "arguments": .array([.string("-t"), .string("absent")]),
                            ]),
                            .object(["command": .string("list-windows")]),
                        ]),
                        "confirm_unsafe": .bool(true),
                    ])
                )
            )
            let batch = try outcome.decode(BatchResult.self)
            #expect(batch.requested == 3)
            // A `;` list merges every command's output into one stream; this
            // says which one stopped it.
            #expect(batch.steps.count == 2)
            #expect(batch.steps.last?.step == 1)
            #expect(batch.steps.last?.command == "has-session")
            #expect(batch.stoppedEarly)
        }
    }

    @Test("run_shell reports the exit status and only its own output")
    func runShellReportsStatusAndOutput() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            _ = try await server.run(
                TmuxCommand("resize-window", ["-t", pane.windowID.rawValue, "-x", "12"])
            )
            #expect(try await server.formatGlobal("#{pane_width}", for: pane) == "12")
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("printf shell-marker"),
                        "max_lines": .number(1),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(!result.timedOut)
            #expect(result.output == ["shell-marker"])
            #expect(!result.linesMissed)
        }
    }

    @Test("run_shell bounds output before collecting it")
    func runShellBoundsOutputAtTheSource() async throws {
        try await withTmuxServer { server in
            _ = try await server.setOption("history-limit", to: "6000")
            let existing = Set(try await server.panes().map(\.id))
            _ = try await server.newSession(named: "bounded-run-shell")
            let pane = try #require(
                try await server.panes().first { !existing.contains($0.id) }
            )
            let ready = "libtmux-test-run-shell-ready-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; printf '\\033c'; "
                    + "\(server.shellInvocation) wait-for -S \(ready)",
                in: pane
            )
            try await server.wait(for: ready)
            try await server.clearHistory(pane)

            let transport = CaptureLimitRecordingTransport()
            let boundedServer = Server(
                endpoint: server.endpoint,
                tmuxExecutable: server.tmuxExecutable,
                transport: transport
            )
            let current = try #require(
                try await boundedServer.panes().first { $0.id == pane.id }
            )
            let filler = String(repeating: "x", count: 57)
            let outcome = try await TmuxTools(server: boundedServer).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(current)),
                        "command": .string(
                            "i=0; while [ \"$i\" -lt 4200 ]; do "
                                + "printf 'RUN%04d\(filler)\\n' \"$i\"; "
                                + "i=$((i + 1)); done"
                        ),
                        "max_lines": .number(2),
                        "timeout": .number(20),
                    ])
                )
            ).decode(RunShellResult.self)

            #expect(outcome.exitStatus == 0)
            #expect(outcome.output.count == 2)
            #expect(outcome.output.map { String($0.prefix(7)) } == ["RUN4198", "RUN4199"])
            #expect(outcome.linesMissed)
            #expect(outcome.droppedLines == 2)
            let capture = try #require(await transport.lastCapture)
            #expect(capture.outputLimit == 262_144)
            #expect(capture.arguments.joined(separator: " ").contains(" -S "))
        }
    }

    @Test("run_shell preserves output when scrollback is full")
    func runShellPreservesOutputAtFullHistory() async throws {
        try await withTmuxServer { server in
            _ = try await server.setOption("history-limit", to: "20")
            let existing = Set(try await server.panes().map(\.id))
            _ = try await server.newSession(named: "full-history-run-shell")
            let pane = try #require(
                try await server.panes().first { !existing.contains($0.id) }
            )
            let reset = "libtmux-test-run-shell-reset-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; printf '\\033c'; "
                    + "\(server.shellInvocation) wait-for -S \(reset)",
                in: pane
            )
            try await server.wait(for: reset)
            try await server.clearHistory(pane)

            let ready = "libtmux-test-run-shell-full-\(UUID().uuidString)"
            let release = "libtmux-test-run-shell-release-\(UUID().uuidString)"
            let settled = "libtmux-test-run-shell-settled-\(UUID().uuidString)"
            let tmux = server.shellInvocation
            try await server.run(
                "i=0; while [ \"$(\(tmux) display-message -p -t \(pane.id.rawValue) "
                    + "'#{history_size}')\" != '20' ]; do "
                    + "printf 'SEED%04d\\n' \"$i\"; i=$((i + 1)); done; "
                    + "\(tmux) wait-for -S \(ready); \(tmux) wait-for \(release); "
                    + "\(tmux) wait-for -S \(settled)",
                in: pane
            )
            try await server.wait(for: ready)
            #expect(
                try await server.formatGlobal("#{history_size}", for: pane) == "20"
            )
            try await server.signal(release)
            try await server.wait(for: settled)

            let result = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("printf 'ONE\\nTWO\\n'"),
                        "timeout": .number(20),
                    ])
                )
            ).decode(RunShellResult.self)

            #expect(result.exitStatus == 0)
            #expect(result.output == ["ONE", "TWO"])
            #expect(!result.linesMissed)
            #expect(result.droppedLines == 0)
        }
    }

    @Test("run_shell does not depend on a tmux being on the pane's PATH")
    func runShellDoesNotNeedTmuxOnPath() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            // A bare `tmux` here would be whichever one the pane can find, and
            // a client of a different protocol version is refused with `server
            // exited unexpectedly` — reaching the caller as a command that
            // simply never finished. Emptying PATH is the same fault, made
            // deterministic.
            try await server.run("PATH=/nonexistent; export PATH", in: pane)
            try await Task.sleep(for: .milliseconds(200))

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("/bin/echo path-independent"),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(!result.timedOut)
            #expect(result.exitStatus == 0)
        }
    }

    @Test("run_shell carries a failing command's status back")
    func runShellCarriesFailure() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("(exit 3)"),
                        "timeout": .number(20),
                    ])
                )
            )
            #expect(try outcome.decode(RunShellResult.self).exitStatus == 3)
        }
    }

    @Test("run_shell isolates its bookkeeping from a trailing comment")
    func runShellSurvivesATrailingComment() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let outcome = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("(exit 7) # trailing comment"),
                        "timeout": .number(1),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(!result.timedOut)
            #expect(result.exitStatus == 7)
            #expect(!(await tools.paneRuns.isHeld(pane)))
        }
    }

    @Test("run_shell is pane-global when its window has several links")
    func runShellDoesNotRequireAWindowLink() async throws {
        try await withTmuxServer { server in
            let sourceLink = try #require(try await server.windowLinks().first)
            let source = try #require(
                try await server.windows().first { $0.id == sourceLink.windowID }
            )
            let pane = try #require(
                try await server.panes().first { $0.windowID == source.id }
            )
            let destination = try await server.newSession(named: "run-shell-destination")
            _ = try await server.link(source, into: destination)
            _ = try await server.link(source, into: destination)

            let outcome = try await TmuxTools(server: server, caller: nil).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("printf 'pane-global\\n'"),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(!result.timedOut)
        }
    }

    @Test("run_shell reports an identical output occurrence")
    func runShellReportsRepeatedOutput() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let command = "printf 'repeated-shell-output\\n'"
            let echoOff = "libtmux-test-echo-off-\(UUID().uuidString)"
            try await server.run(
                "stty -echo; \(server.shellInvocation) wait-for -S \(echoOff)",
                in: pane
            )
            try await server.wait(for: echoOff)
            let seeded = "libtmux-test-seeded-\(UUID().uuidString)"
            try await server.run(
                "\(command); \(server.shellInvocation) wait-for -S \(seeded)",
                in: pane
            )
            try await server.wait(for: seeded)

            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string(command),
                        "timeout": .number(20),
                    ])
                )
            )
            let result = try outcome.decode(RunShellResult.self)
            #expect(result.output.contains { $0.hasSuffix("repeated-shell-output") })
        }
    }

    @Test("concurrent run_shell calls keep their own status")
    func concurrentRunShellCallsKeepTheirStatus() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let results = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
                for expected in 1...8 {
                    group.addTask {
                        let outcome = try await tools.call(
                            ToolCall(
                                name: "run_shell",
                                arguments: .object([
                                    "pane": .string(wireRef(pane)),
                                    "command": .string("(exit \(expected))"),
                                    "timeout": .number(20),
                                ])
                            )
                        )
                        return (expected, try outcome.decode(RunShellResult.self).exitStatus)
                    }
                }
                return try await group.reduce(into: []) { $0.append($1) }
            }

            for (expected, actual) in results {
                #expect(actual == expected)
            }
        }
    }

    @Test("a timed-out run keeps later output separate")
    func timedOutRunKeepsThePaneLease() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("sleep 1; printf 'first-run-finished\\n'"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            let second = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("printf 'second-run-only\\n'"),
                        "timeout": .number(5),
                    ])
                )
            )
            let result = try second.decode(RunShellResult.self)
            #expect(result.exitStatus == 0)
            #expect(result.output.contains { $0.hasSuffix("second-run-only") })
            #expect(!result.output.contains { $0.hasSuffix("first-run-finished") })
        }
    }

    @Test("separate tool values share one pane lease")
    func paneLeaseIsSharedAcrossToolValues() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let firstTools = TmuxTools(server: server)
            let first = try await firstTools.call(
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

            let secondTools = TmuxTools(server: server)
            await #expect(throws: ToolError.self) {
                try await secondTools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(wireRef(pane)),
                            "command": .string("printf 'must-not-run\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            }
        }
    }

    @Test("respawning a pane releases its timed-out run")
    func paneRespawnReleasesTimedOutRun() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("sleep 30"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)

            try await server.respawn(pane)
            let second = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("printf 'after-respawn\n'"),
                        "timeout": .number(3),
                    ])
                )
            )
            let result = try second.decode(RunShellResult.self)
            #expect(!result.timedOut)
            #expect(result.output.contains { $0.hasSuffix("after-respawn") })
        }
    }

    @Test("a retained dead pane releases its timed-out run")
    func retainedDeadPaneReleasesTimedOutRun() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let window = try #require(
                try await server.windows().first { $0.id == pane.windowID }
            )
            try await server.setOption("remain-on-exit", to: "on", of: window)
            let tools = TmuxTools(server: server)
            let first = try await tools.call(
                ToolCall(
                    name: "run_shell",
                    arguments: .object([
                        "pane": .string(wireRef(pane)),
                        "command": .string("exit"),
                        "timeout": .number(0.1),
                    ])
                )
            )
            #expect(try first.decode(RunShellResult.self).timedOut)
            #expect(
                try await waitUntil {
                    try await server.format("#{pane_dead}", addressing: pane.id.rawValue) == "1"
                }
            )

            do {
                _ = try await tools.call(
                    ToolCall(
                        name: "run_shell",
                        arguments: .object([
                            "pane": .string(wireRef(pane)),
                            "command": .string("printf 'dead-pane\n'"),
                            "timeout": .number(0.2),
                        ])
                    )
                )
            } catch let error as ToolError {
                if case let .refusedForSafety(reason) = error {
                    #expect(!reason.contains("earlier run_shell"))
                }
            }
        }
    }

    @Test("a workspace plan builds a whole session in one call")
    func workspacePlanBuildsASession() async throws {
        try await withTmuxServer { server in
            let plan = """
                {"session_name":"planned","windows":[
                  {"window_name":"one","panes":[{"shell_command":[]}]},
                  {"window_name":"two","panes":[{"shell_command":[]},{"shell_command":[]}]}
                ]}
                """
            let outcome = try await TmuxTools(server: server).call(
                ToolCall(
                    name: "apply_workspace",
                    arguments: .object(["plan": .string(plan)])
                )
            )
            let built = try outcome.decode(WorkspaceResult.self)
            #expect(built.session.name == "planned")
            #expect(built.windows.count == 2)
            #expect(built.panes.count == 3)
        }
    }

}
