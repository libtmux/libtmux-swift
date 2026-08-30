import LibTmux
import Testing

@testable import LibTmuxMCP

private func requireToolError(
    from tools: TmuxTools,
    calling request: ToolCall
) async throws(ToolError) -> ToolOutcome {
    try await tools.call(request)
}

@Suite("tmux tool errors")
struct TmuxToolsTypedThrowsTests {
    @Test("call exposes ToolError as its only thrown type")
    func callHasATypedErrorBoundary() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-typed-tool-error"
        )

        await #expect(throws: ToolError.unknownTool("teleport")) {
            try await requireToolError(
                from: TmuxTools(server: server),
                calling: ToolCall(name: "teleport")
            )
        }
    }

    @Test("core failures retain their typed tmux error")
    func coreFailuresRetainTheirTmuxError() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-typed-core-error",
            tmuxExecutable: "/tmp/libtmux-swift-test/missing-typed-core-tmux"
        )

        do {
            _ = try await TmuxTools(server: server).call(ToolCall(name: "list_sessions"))
            Issue.record("the missing tmux executable did not fail")
        } catch .tmux(.processLaunchFailed) {
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("workspace failures retain their builder error")
    func workspaceFailuresRetainTheirBuilderError() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-typed-workspace-error"
        )
        let plan: JSONValue = .object([
            "session_name": .string("empty"),
            "windows": .array([]),
        ])

        await #expect(throws: ToolError.workspace(.noWindows)) {
            try await TmuxTools(server: server, tier: .mutating).call(
                ToolCall(
                    name: "apply_workspace",
                    arguments: .object(["plan": plan])
                )
            )
        }
    }

    @Test("malformed embedded JSON is an argument error")
    func malformedEmbeddedJSONIsAnArgumentError() async throws {
        let server = try Server(
            socketPath: "/tmp/libtmux-swift-test/unstarted-typed-decoding-error"
        )
        let plan: JSONValue = .object([
            "session_name": .integer(1),
            "windows": .array([]),
        ])

        await #expect(
            throws: ToolError.wrongArgumentType(
                "arguments",
                expected: "values matching apply_workspace's schema"
            )
        ) {
            try await TmuxTools(server: server, tier: .mutating).call(
                ToolCall(
                    name: "apply_workspace",
                    arguments: .object(["plan": plan])
                )
            )
        }
    }
}
