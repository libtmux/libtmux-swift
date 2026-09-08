import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// A tool that reports success has to have done something.
///
/// `ToolSurfaceTests` proves every advertised tool ANSWERS the schema it
/// publishes. That is not the same as working. tmux accepts
/// `set-option -s mouse on` without complaint and changes nothing, so an option
/// written at the wrong scope reports success and silently no-ops — quieter,
/// and worse, than the loud refusal the same defect produced in libtmux-go.
///
/// Only tools whose whole effect is a value that can be read straight back
/// belong here. Anything needing a fixture to observe it is a behaviour test.
@Suite("tool effects", .timeLimit(.minutes(2)))
struct ToolEffectTests {
    @Test("option-setting tools change the option they name")
    func optionSettingToolsChangeTheOptionTheyName() async throws {
        try await withTmuxServer { server in
            let tools = TmuxTools(
                server: server,
                authority: ToolAuthority(toolsets: [.manage]),
                caller: nil
            )

            _ = try await tools.call(
                ToolCall(
                    name: "set_mouse_enabled",
                    arguments: .object(["enabled": .bool(true)])
                )
            )
            let mouse = try await server.option("mouse", scope: .globalSession)
            #expect(
                mouse == "on",
                "set_mouse_enabled reported success but mouse reads \(mouse ?? "nothing")"
            )

            _ = try await tools.call(
                ToolCall(
                    name: "set_history_limit",
                    arguments: .object(["lines": .number(4242)])
                )
            )
            let limit = try await server.option("history-limit", scope: .globalSession)
            #expect(
                limit == "4242",
                "set_history_limit reported success but history-limit reads \(limit ?? "nothing")"
            )
        }
    }
}
