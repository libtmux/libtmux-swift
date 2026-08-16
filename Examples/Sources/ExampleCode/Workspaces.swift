// The examples in the README's `WorkspaceBuilder` section.

import Foundation
import LibTmux
import TmuxWorkspace

public func describeAWorkspaceInSwift() -> Workspace {
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

public func buildItOnAServer(_ server: Server, _ workspace: Workspace) async throws -> Session {
    let session = try await WorkspaceBuilder.build(workspace, on: server)
    print(session.name, session.windowCount)
    return session
}

public func readAWorkspaceWrittenAsJSON(_ json: Data) throws -> Workspace {
    try Workspace.decode(json: json)
}

// Deliberately NOT wrapped in `#if YAMLWorkspaces`. A trait defines its
// compilation condition only inside the package that declares it, so that guard
// in a consumer package is always false and deletes the example — loudly if a
// test calls it, silently if nothing does. The symbol is nonetheless here,
// because the dependency was resolved with the trait on.
public func readATmuxpFile(_ text: String) throws -> Workspace {
    try Workspace.decode(yaml: text)
}
