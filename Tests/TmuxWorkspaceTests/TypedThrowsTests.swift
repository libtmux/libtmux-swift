import LibTmux
import TmuxWorkspace

private func requireWorkspaceError<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws(WorkspaceBuilderError) -> Result
) {}

private func compileTypedWorkspaceFailures(workspace: Workspace, server: Server) {
    requireWorkspaceError { () async throws(WorkspaceBuilderError) -> Session in
        try await WorkspaceBuilder.build(workspace, on: server)
    }
}
