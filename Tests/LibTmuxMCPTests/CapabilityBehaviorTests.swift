import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("capability behavior", .timeLimit(.minutes(1)))
struct CapabilityBehaviorTests {
    private func tools(_ server: Server) -> TmuxTools {
        TmuxTools(
            server: server,
            authority: ToolAuthority(toolsets: [.inspect, .manage, .execute, .teardown]),
            caller: nil
        )
    }

    @Test("search work budget enforces every aggregate ceiling")
    func searchWorkBudgetEnforcesEveryAggregateCeiling() {
        let clock = ContinuousClock()
        let start = clock.now

        var panes = SearchWorkBudget(
            maximumPanes: 1,
            maximumLines: 10,
            maximumBytes: 100,
            startedAt: start,
            maximumDuration: .seconds(5)
        )
        #expect(panes.beginPane(at: start) == nil)
        #expect(panes.beginPane(at: start) == .panes)

        var lines = SearchWorkBudget(
            maximumPanes: 10,
            maximumLines: 1,
            maximumBytes: 100,
            startedAt: start,
            maximumDuration: .seconds(5)
        )
        #expect(lines.consume("first", at: start) == nil)
        #expect(lines.consume("second", at: start) == .lines)

        var bytes = SearchWorkBudget(
            maximumPanes: 10,
            maximumLines: 10,
            maximumBytes: 4,
            startedAt: start,
            maximumDuration: .seconds(5)
        )
        #expect(bytes.consume("1234", at: start) == nil)
        #expect(bytes.consume("5", at: start) == .bytes)

        var time = SearchWorkBudget(
            maximumPanes: 10,
            maximumLines: 10,
            maximumBytes: 100,
            startedAt: start,
            maximumDuration: .zero
        )
        #expect(time.beginPane(at: start) == .time)
    }

    @Test("create_session applies its advertised dimensions")
    func createSessionAppliesDimensions() async throws {
        try await withTmuxServer { server in
            let result = try await tools(server).call(
                ToolCall(
                    name: "create_session",
                    arguments: .object([
                        "height": .integer(41),
                        "name": .string("capability-size"),
                        "width": .integer(111),
                    ])
                )
            )
            let sessionID = try #require(result.structured["id"]?.stringValue)
            let snapshot = try await server.snapshot()
            let link = try #require(
                snapshot.windowLinks.first { $0.sessionID.rawValue == sessionID }
            )
            let window = try #require(snapshot.windows.first { $0.id == link.windowID })

            #expect(window.width == 111)
            #expect(window.height == 41)
        }
    }

    @Test("move_window applies its advertised destination index")
    func moveWindowAppliesIndex() async throws {
        try await withTmuxServer { server in
            let sourceSession = try #require(try await server.sessions().first)
            let source = try await server.newWindow(in: sourceSession)
            let destination = try await server.newSession(named: "capability-move")

            _ = try await tools(server).call(
                ToolCall(
                    name: "move_window",
                    arguments: .object([
                        "index": .integer(7),
                        "session": .string(destination.id.rawValue),
                        "windowId": .string(source.window.id.rawValue),
                    ])
                )
            )

            let moved = try #require(
                try await server.windowLinks().first {
                    $0.windowID == source.window.id && $0.sessionID == destination.id
                }
            )
            #expect(moved.index == 7)
        }
    }

    @Test("resize_pane applies its advertised zoom operation")
    func resizePaneAppliesZoom() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            _ = try await server.split(pane, direction: .right)

            _ = try await tools(server).call(
                ToolCall(
                    name: "resize_pane",
                    arguments: .object([
                        "paneId": .string(pane.id.rawValue), "zoom": .bool(true),
                    ])
                )
            )

            #expect(
                try await server.format(
                    "#{window_zoomed_flag}", addressing: pane.id.rawValue) == "1"
            )
        }
    }

    @Test("capture_pane applies its advertised range")
    func capturePaneAppliesRange() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            try await server.run("printf 'range-one\\nrange-two\\nrange-three\\n'", in: pane)
            #expect(
                try await waitUntil {
                    try await server.capture(pane).contains { $0.contains("range-three") }
                }
            )

            let reply = try await server.run(
                TmuxCommand(
                    "capture-pane",
                    ["-p", "-t", pane.id.rawValue, "-S", "0", "-E", "1"]
                )
            )
            var expected = reply.text
            if expected.hasSuffix("\n") { expected.removeLast() }
            let expectedLines = expected.isEmpty ? [] : expected.components(separatedBy: "\n")

            let result = try await tools(server).call(
                ToolCall(
                    name: "capture_pane",
                    arguments: .object([
                        "end": .integer(1), "maxLines": .integer(10),
                        "paneId": .string(pane.id.rawValue), "start": .integer(0),
                    ])
                )
            )
            let actual = result.structured["lines"]?.arrayValue?.compactMap(\.stringValue)
            #expect(actual == expectedLines)
        }
    }

    @Test("retained run and wait tools preserve their bounded result contracts")
    func retainedRunAndWaitContracts() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let marker = "retained-run-and-wait"
            let run = try await tools(server).call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("printf '\(marker)\\n'"),
                        "maxLines": .integer(20),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(5_000),
                    ])
                )
            )
            #expect(run.structured["exitStatus"]?.intValue == 0)
            #expect(
                run.structured["output"]?.arrayValue?.compactMap(\.stringValue)
                    .contains(marker) == true
            )

            let waited = try await tools(server).call(
                ToolCall(
                    name: "wait_for_text",
                    arguments: .object([
                        "maxLines": .integer(20),
                        "paneId": .string(pane.id.rawValue),
                        "patterns": .array([.string(marker)]),
                        "timeoutMs": .integer(1_000),
                    ])
                )
            )
            #expect(waited.structured["matched"]?.stringValue == marker)
            #expect(waited.structured["matchedAtEntry"]?.boolValue == true)
            #expect(waited.structured["effectiveTimeout"]?.doubleValue == 1)
        }
    }

    @Test("run_shell_command refuses a synchronized multi-pane cohort before input")
    func runRequiresSingularConfiguredPane() async throws {
        try await withTmuxServer { server in
            let first = try #require(try await server.panes().first)
            let second = try await server.split(first, direction: .right)
            _ = try await server.run(
                TmuxCommand(
                    "set-option", ["-p", "-t", first.id.rawValue, "synchronize-panes", "on"])
            )
            _ = try await server.run(
                TmuxCommand(
                    "set-option", ["-p", "-t", second.id.rawValue, "synchronize-panes", "on"])
            )
            let marker = "must-not-reach-a-pane"

            await #expect(throws: ToolError.self) {
                _ = try await tools(server).call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string("printf '\(marker)\\n'"),
                            "paneId": .string(first.id.rawValue),
                            "timeoutMs": .integer(1_000),
                        ])
                    )
                )
            }
            #expect(try await server.capture(first).contains { $0.contains(marker) } == false)
            #expect(try await server.capture(second).contains { $0.contains(marker) } == false)
        }
    }

    @Test("run_shell_command contains exit, syntax, and shell state")
    func runContainsShellState() async throws {
        try await withTmuxServer { server in
            let pane = try #require(try await server.panes().first)
            let surface = tools(server)
            let exited = try await surface.call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("exit 23"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(2_000),
                    ])
                )
            )
            #expect(exited.structured["exitStatus"]?.intValue == 23)

            let invalid = try await surface.call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("if then"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(2_000),
                    ])
                )
            )
            #expect(invalid.structured["exitStatus"]?.intValue != 0)

            let alive = try await surface.call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("pwd; cd /; export LIBTMUX_FRAME_LEAK=1; trap : 0"),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(2_000),
                    ])
                )
            )
            #expect(alive.structured["exitStatus"]?.intValue == 0)
            let after = try await surface.call(
                ToolCall(
                    name: "run_shell_command",
                    arguments: .object([
                        "command": .string("test -z \"${LIBTMUX_FRAME_LEAK+x}\""),
                        "paneId": .string(pane.id.rawValue),
                        "timeoutMs": .integer(2_000),
                    ])
                )
            )
            #expect(after.structured["exitStatus"]?.intValue == 0)
        }
    }

    @Test("shell framing preserves inherited state across supported installed shells")
    func shellFramingAcrossInstalledShells() async throws {
        try await withTmuxServer { server in
            let original = try #require(try await server.panes().first)
            let candidates: [(String, [String])] = [
                ("/bin/sh", []),
                ("/bin/dash", []),
                ("/bin/bash", ["--noprofile", "--norc"]),
                ("/bin/zsh", ["-f"]),
            ]
            for (path, flags) in candidates
            where FileManager.default.isExecutableFile(atPath: path) {
                try await server.respawn(original, running: [path] + flags)
                let shell = URL(fileURLWithPath: path).lastPathComponent
                #expect(
                    try await waitUntil {
                        try await server.panes().first(where: { $0.id == original.id })?
                            .currentCommand == shell
                    },
                    Comment(rawValue: shell)
                )
                let ready = "libtmux-swift-frame-ready-\(UUID().uuidString)"
                let setup =
                    "cd /tmp; export LIBTMUX_FRAME_PARENT=kept; "
                    + "readonly __libtmux_mcp_status=parent __libtmux_mcp_flags=parent; "
                    + "printf(){ :; }; alias printf=:; trap ':' 0; "
                    + (shell == "bash" ? "trap ':' DEBUG; trap ':' ERR; " : "")
                    + "set -e; set -x; \(server.shellInvocation) wait-for -S \(ready)"
                try await server.sendKeys([setup, "Enter"], to: original)
                try await server.wait(for: ready)

                let surface = tools(server)
                let run = try await surface.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string(
                                "cd /; export LIBTMUX_FRAME_PARENT=changed; "
                                    + "trap ':' 0; "
                                    + "/usr/bin/printf 'frame-\(shell)\\n'; false; "
                                    + "/usr/bin/printf 'unreachable\\n'"
                            ),
                            "maxLines": .integer(2_000),
                            "paneId": .string(original.id.rawValue),
                            "timeoutMs": .integer(5_000),
                        ])
                    )
                )
                #expect(run.structured["exitStatus"]?.intValue != 0, Comment(rawValue: shell))
                #expect(
                    run.structured["output"]?.arrayValue?.compactMap(\.stringValue)
                        .contains("frame-\(shell)") == true,
                    Comment(rawValue: shell)
                )
                #expect(
                    run.structured["output"]?.arrayValue?.compactMap(\.stringValue)
                        .contains("unreachable") == false,
                    Comment(rawValue: shell)
                )

                let parent = try await surface.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string(
                                "test \"$PWD\" = /tmp && test \"$LIBTMUX_FRAME_PARENT\" = kept"
                            ),
                            "paneId": .string(original.id.rawValue),
                            "timeoutMs": .integer(5_000),
                        ])
                    )
                )
                #expect(parent.structured["exitStatus"]?.intValue == 0, Comment(rawValue: shell))

                let unaliased = "libtmux-swift-frame-unalias-\(UUID().uuidString)"
                try await server.sendKeys(
                    [
                        "unalias printf; \(server.shellInvocation) wait-for -S \(unaliased)",
                        "Enter",
                    ],
                    to: original
                )
                try await server.wait(for: unaliased)
                let function = try await surface.call(
                    ToolCall(
                        name: "run_shell_command",
                        arguments: .object([
                            "command": .string(
                                "printf(){ :; }; /usr/bin/printf 'function-\(shell)\\n'"
                            ),
                            "maxLines": .integer(2_000),
                            "paneId": .string(original.id.rawValue),
                            "timeoutMs": .integer(5_000),
                        ])
                    )
                )
                #expect(function.structured["exitStatus"]?.intValue == 0)
                #expect(
                    function.structured["output"]?.arrayValue?.compactMap(\.stringValue)
                        .contains("function-\(shell)") == true,
                    Comment(rawValue: shell)
                )
            }
        }
    }

    @Test("validated dispatch precedes mutation and synchronized sends disclose all targets")
    func validatedDispatchAndSynchronizedTargets() async throws {
        try await withTmuxServer { server in
            let first = try #require(try await server.panes().first)
            let second = try await server.split(first, direction: .right)
            let invalidMarker = "must-not-be-pasted"
            await #expect(throws: ToolError.self) {
                _ = try await tools(server).call(
                    ToolCall(
                        name: "paste_text",
                        arguments: .object([
                            "enter": .string("yes"),
                            "paneId": .string(first.id.rawValue),
                            "text": .string(invalidMarker),
                        ])
                    )
                )
            }
            #expect(try await server.capture(first).contains(invalidMarker) == false)

            _ = try await tools(server).call(
                ToolCall(
                    name: "set_synchronize_panes",
                    arguments: .object([
                        "enabled": .bool(true),
                        "windowId": .string(first.windowID.rawValue),
                    ])
                )
            )
            let sent = try await tools(server).call(
                ToolCall(
                    name: "send_keys",
                    arguments: .object([
                        "keys": .array([.string("s")]),
                        "literal": .bool(true),
                        "paneId": .string(first.id.rawValue),
                    ])
                )
            )
            let resolved = Set(
                sent.structured["resolvedPaneIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            #expect(resolved == [first.id.rawValue, second.id.rawValue])
        }
    }

    @Test("synchronized input refuses modal members and every batch row rechecks")
    func synchronizedInputRefusesModalMembers() async throws {
        try await withTmuxServer { server in
            let source = try #require(try await server.panes().first)
            let peer = try await server.split(source, direction: .right)
            _ = try await server.run(
                TmuxCommand(
                    "set-option", ["-p", "-t", peer.id.rawValue, "synchronize-panes", "on"])
            )
            try await server.enterCopyMode(peer)
            let surface = tools(server)
            let marker = "modal-member-must-not-receive-input"

            _ = try await server.run(
                TmuxCommand(
                    "set-option", ["-p", "-t", source.id.rawValue, "synchronize-panes", "on"])
            )
            await #expect(throws: ToolError.self) {
                _ = try await surface.call(
                    ToolCall(
                        name: "send_keys",
                        arguments: .object([
                            "keys": .array([.string(marker)]),
                            "literal": .bool(true),
                            "paneId": .string(source.id.rawValue),
                        ])
                    )
                )
            }
            #expect(try await server.capture(source).contains { $0.contains(marker) } == false)
            #expect(try await server.capture(peer).contains { $0.contains(marker) } == false)
            _ = try await server.run(
                TmuxCommand(
                    "set-option", ["-p", "-t", source.id.rawValue, "synchronize-panes", "off"])
            )

            _ = try await surface.call(
                ToolCall(
                    name: "send_keys",
                    arguments: .object([
                        "keys": .array([.string("safe-source-row")]),
                        "literal": .bool(true),
                        "paneId": .string(source.id.rawValue),
                    ])
                )
            )
            let batch = try await surface.call(
                ToolCall(
                    name: "send_keys_batch",
                    arguments: .object([
                        "onError": .string("continue"),
                        "operations": .array([
                            .object([
                                "keys": .array([.string("one")]),
                                "literal": .bool(true),
                                "paneId": .string(source.id.rawValue),
                            ]),
                            .object([
                                "keys": .array([.string(marker)]),
                                "literal": .bool(true),
                                "paneId": .string(peer.id.rawValue),
                            ]),
                        ]),
                    ])
                )
            )
            #expect(batch.structured["completed"]?.intValue == 1)
            #expect(batch.structured["failures"]?.arrayValue?.count == 1)
            #expect(try await server.capture(peer).contains { $0.contains(marker) } == false)
            #expect(try await server.capture(source).contains { $0.contains("safe-source-rowone") })
        }
    }

    @Test("paste_text keeps text and Enter target-only in one private buffer")
    func pasteTextKeepsEnterTargetOnly() async throws {
        try await withTmuxServer { server in
            let source = try #require(try await server.panes().first)
            let peer = try await server.split(source, direction: .right)
            let peerMarker = "peer-enter-must-not-run"
            try await server.sendKeys(
                ["/usr/bin/printf '\(peerMarker)\\n'"],
                to: peer,
                literally: true
            )
            for pane in [source, peer] {
                _ = try await server.run(
                    TmuxCommand(
                        "set-option",
                        ["-p", "-t", pane.id.rawValue, "synchronize-panes", "on"]
                    )
                )
            }
            let targetMarker = "target-paste-ran"
            _ = try await tools(server).call(
                ToolCall(
                    name: "paste_text",
                    arguments: .object([
                        "enter": .bool(true),
                        "paneId": .string(source.id.rawValue),
                        "text": .string("/usr/bin/printf '\(targetMarker)\\n'"),
                    ])
                )
            )

            #expect(
                try await waitUntil {
                    try await server.capture(source).contains { $0.contains(targetMarker) }
                }
            )
            #expect(try await server.capture(peer).contains { $0.contains(peerMarker) } == false)
            #expect(
                try await server.buffers().contains { $0.name.hasPrefix("libtmux-mcp-") } == false)
        }
    }
}
