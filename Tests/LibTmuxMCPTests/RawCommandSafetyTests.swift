import Foundation
import Testing
import TmuxFixture

@testable import LibTmux
@testable import LibTmuxMCP

@Suite("raw command safety", .timeLimit(.minutes(1)))
struct RawCommandSafetyTests {
    @Test("raw commands are destructive tools with explicit confirmation")
    func rawCommandsRequireDestructiveConfirmation() throws {
        for name in ["run_command", "run_commands"] {
            let definition = try #require(TmuxTools.byName[name])
            #expect(definition.tier == .destructive)
            #expect(
                definition.arguments.first { $0.name == "confirm_unsafe" }?.isRequired == true
            )
            #expect(definition.arguments.contains { $0.name == "server_ref" })
            #expect(definition.arguments.contains { $0.name == "timeout" })
        }
    }

    @Test("false unsafe confirmation cannot execute a command")
    func falseConfirmationCannotExecute() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(server: server, tier: .destructive)
            let reference = try await rawServerRef(server)
            await #expect(
                throws: ToolError.refusedForSafety(
                    "raw tmux commands bypass typed target and safety checks; "
                        + "pass confirm_unsafe=true to acknowledge that"
                )
            ) {
                try await tools.call(
                    ToolCall(
                        name: "run_command",
                        arguments: .object([
                            "server_ref": .string(reference),
                            "command": .string("set-option"),
                            "arguments": .array([
                                .string("-g"), .string("@unsafe-ran"), .string("yes"),
                            ]),
                            "confirm_unsafe": .bool(false),
                        ])
                    )
                )
            }
            #expect(try await server.option("@unsafe-ran", scope: .globalSession) == nil)
        }
    }

    @Test("a nested blocking command is cancelled at the deadline")
    func nestedBlockingCommandTimesOut() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(
                server: server,
                tier: .destructive,
                waitCeiling: .seconds(1)
            )
            let reference = try await rawServerRef(server)
            let channel = "libtmux-test-raw-never-\(UUID().uuidString)"

            await #expect(throws: ToolError.timedOut("run_command", seconds: 0.1)) {
                try await tools.call(
                    ToolCall(
                        name: "run_command",
                        arguments: .object([
                            "server_ref": .string(reference),
                            "command": .string("if-shell"),
                            "arguments": .array([
                                .string("-F"), .string("1"),
                                .string("wait-for \(channel)"), .string(""),
                            ]),
                            "confirm_unsafe": .bool(true),
                            "timeout": .number(0.1),
                        ])
                    )
                )
            }
            #expect(try await !server.sessions().isEmpty)
        }
    }

    @Test("raw command output is bounded")
    func rawCommandOutputIsBounded() async throws {
        try await withTmuxServer { server in
            let directory = URL(fileURLWithPath: "/tmp/libtmux-swift-test")
                .appendingPathComponent("raw-output-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let payload = directory.appendingPathComponent("payload")
            try Data(repeating: 120, count: 300_000).write(to: payload)
            let loaded = try await server.run(
                TmuxCommand(
                    "load-buffer",
                    ["-b", "raw-output-limit", payload.path]
                )
            )
            #expect(loaded.isSuccess)
            let tools = TmuxTools(server: server, tier: .destructive)
            await #expect(
                throws: ToolError.tmux(
                    .invocationFailed(
                        reason: "tmux output exceeded 262144 bytes per stream"
                    )
                )
            ) {
                try await tools.call(
                    ToolCall(
                        name: "run_command",
                        arguments: .object([
                            "server_ref": .string(try await rawServerRef(server)),
                            "command": .string("show-buffer"),
                            "arguments": .array([
                                .string("-b"), .string("raw-output-limit"),
                            ]),
                            "confirm_unsafe": .bool(true),
                            "timeout": .number(20),
                        ])
                    )
                )
            }
            #expect(try await server.isRunning())
        }
    }
}

private func rawServerRef(_ server: Server) async throws -> String {
    WireReferenceCodec.processLocal.reference(
        to: try #require(try await server.incarnation())
    )
}
