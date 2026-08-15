// The examples in the README's `WorkspaceBuilder` section.
//
// `Workspace.decode(yaml:)` is behind the `YAMLWorkspaces` trait, so the
// example that reads a tmuxp file is compiled only when the trait is on. The
// rest builds either way, which is the point the section makes.

import Foundation
import LibTmux
import WorkspaceBuilder

func describeAWorkspaceInSwift() -> Workspace {
    Workspace(
        sessionName: "work",
        windows: [
            WindowPlan(
                windowName: "editor",
                layout: "even-horizontal",
                panes: [PanePlan(), PanePlan()]
            ),
            WindowPlan(
                windowName: "logs",
                panes: [PanePlan(shellCommands: ["tail -f /tmp/build.log"])]
            ),
        ]
    )
}

func buildItOnAServer(_ server: Server, _ workspace: Workspace) async throws {
    let session = try await WorkspaceBuilder.build(workspace, on: server)
    print(session.name, session.windowCount)
}

func readAWorkspaceWrittenAsJSON(_ json: Data) throws -> Workspace {
    try Workspace.decode(json: json)
}

#if YAMLWorkspaces
    func readATmuxpFile(_ text: String) throws -> Workspace {
        try Workspace.decode(yaml: text)
    }
#endif
