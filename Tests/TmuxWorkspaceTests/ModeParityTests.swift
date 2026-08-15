import Foundation
import LibTmux
import Testing
import TmuxFixture

@testable import TmuxWorkspace

/// The mode switch has to read the same from a consumer as it does from the
/// library, and produce the same workspace either way.
///
/// The workspace has to match: the windows, the panes, and how wide they are.
///
/// Heights are tmux's own business — attaching a client is how it decides how
/// tall a session is, and a connection *is* a client. On 3.2a that shows: panes
/// built over a connection come back a row taller. From 3.3a they do not. Both
/// are asserted rather than one being excused, so a release that changes its
/// mind here is caught instead of quietly widening the exception.
@Suite("building under either mode", .timeLimit(.minutes(1)))
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

        // Widths always agree: the split happened the same way either mode.
        let widths: ([String]) -> [Substring] = { $0.map { $0.split(separator: "x")[0] } }
        #expect(widths(direct.1) == widths(connected.1))

        let version = try await withTmuxServer { try await $0.version() }
        if version < TmuxVersion(major: 3, minor: 3) {
            // 3.2a sizes a session to the client that attached, and a
            // connection is one. 3.3a onward do not.
            #expect(direct.1 != connected.1)
        } else {
            #expect(direct.1 == connected.1)
        }
    }
}
