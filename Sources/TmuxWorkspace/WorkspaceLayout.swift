import LibTmux

package enum WorkspaceLayout {
    package static func validate(_ workspaces: [Workspace], on server: Server)
        async throws(TmuxError)
    {
        let layouts = workspaces.flatMap(\.windows).compactMap { window in
            guard let layout = window.layout, !layout.isEmpty else { return nil as (String, Int)? }
            return (layout, max(1, window.panes.count))
        }
        try await server.validateLayouts(layouts)
    }
}
