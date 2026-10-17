import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import TmuxWorkspace

/// The mode switch has to read the same from a consumer as it does from the
/// library, and produce the same workspace either way.
///
/// The workspace has to match: the windows, the panes, and their sizes.
///
/// A connection is a client, and attaching a client is how tmux decides how
/// tall a session is. From 3.3a that no longer changes pane heights, so every
/// supported release is held to the same answer rather than excused a row.
@Suite("building under either mode", .timeLimit(.minutes(5)))
struct ModeParityTests {
    static let workspace = Workspace(
        sessionName: "parity",
        windows: [
            WindowPlan(
                windowName: "editor",
                layout: "even-horizontal",
                panes: [PanePlan(), PanePlan()]
            ),
            WindowPlan(windowName: "shell", panes: [PanePlan()]),
        ]
    )

    @Test("a workspace built over a connection matches one built directly")
    func buildsMatchAcrossModes() async throws {
        // The mode is a parameter, so this branches on data rather than on two
        // shapes of call — which is the property the switch is for, and the one
        // a consumer picking a mode at runtime depends on.
        func build(under mode: TmuxMode) async throws -> ([String], [String]) {
            try await withTmuxServer { server in
                let session = try await server.using(mode) { server in
                    try await WorkspaceBuilder.build(Self.workspace, on: server)
                }
                let snapshot = try await server.snapshot()
                let windows = snapshot.windows(of: session)
                return (
                    windows.map(\.name),
                    snapshot.panes(of: session).map { "\($0.width)x\($0.height)" }
                )
            }
        }

        let direct = try await build(under: .direct)
        // A connection needs a session to attach to, and the build creates the
        // one it is building. Attach to the fixture's.
        let connected = try await build(under: .connected(to: "bootstrap"))

        #expect(direct.0 == connected.0)
        #expect(direct.0 == ["editor", "shell"])
        #expect(direct.1.count == 3)

        #expect(direct.1 == connected.1)
    }
}
