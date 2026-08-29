import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import LibTmuxMCP

/// The tools are built from a server, so they inherit whichever mode that
/// server carries. Nothing in this consumer knows a mode exists, which is the
/// property worth holding on to.
@Suite("tools under either mode", .timeLimit(.minutes(1)))
struct ModeParityTests {
    @Test("run_shell outlives the connection used to start it")
    func runShellFinishesAfterItsConnectionCloses() async throws {
        try await withTmuxServer { server in
            let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let started = "libtmux-test-connected-run-started-\(nonce)"
            let release = "libtmux-test-connected-run-release-\(nonce)"
            let tmux = server.shellInvocation
            let running = try await server.connected(attachingTo: "bootstrap") {
                connected,
                _ in
                let pane = try #require(try await connected.panes().first)
                let tools = TmuxTools(server: connected, tier: .mutating)
                let paneRef = WireReferenceCodec.processLocal.reference(to: pane)
                let task = Task {
                    try await tools.call(
                        ToolCall(
                            name: "run_shell",
                            arguments: .object([
                                "pane": .string(paneRef),
                                "command": .string(
                                    "\(tmux) wait-for -S \(started); "
                                        + "\(tmux) wait-for \(release); "
                                        + "printf 'after-connection\\n'"
                                ),
                                "timeout": .number(20),
                            ])
                        )
                    )
                }
                try await server.wait(for: started)
                return task
            }

            try await server.signal(release)
            let outcome = try await running.value
            let data = Data(outcome.text.utf8)
            let result = try JSONDecoder().decode(RunShellResult.self, from: data)
            #expect(result.exitStatus == 0)
            #expect(result.output.contains { $0.hasSuffix("after-connection") })
        }
    }

    @Test("a tool answers the same over a connection as over a process")
    func toolsAnswerTheSameEitherWay() async throws {
        try await withTmuxServer { server in
            _ = try await server.newSession(named: "alpha")

            // The same tool, reached through the same switch a caller would use.
            let call = ToolCall(name: "list_sessions")
            func answer(under mode: TmuxMode) async throws -> Data {
                try await server.using(mode) { server in
                    Data(try await TmuxTools(server: server).call(call).text.utf8)
                }
            }

            let direct = try await answer(under: .direct)
            let connected = try await answer(under: .connected(to: "bootstrap"))

            // Same tool, same request, same JSON — except for the one thing a
            // connection changes about the server it is asking: it is itself a
            // client, so the session it attached to reads as attached.
            let strip: (Data) throws -> [[String: Any]] = { data in
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let rows = body?["sessions"] as? [Any] ?? []
                return rows.compactMap { $0 as? [String: Any] }
                    .map { row in row.filter { $0.key != "isAttached" } }
                    .sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
            }

            let directRows = try strip(direct)
            let connectedRows = try strip(connected)
            #expect(directRows.count == connectedRows.count)
            #expect(directRows.count >= 2)
            #expect(
                directRows.map { $0["name"] as? String }
                    == connectedRows.map { $0["name"] as? String }
            )
        }
    }
}
