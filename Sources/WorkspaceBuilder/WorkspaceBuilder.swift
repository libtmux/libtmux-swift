import Foundation
import LibTmux

/// Builds a workspace on a tmux server.
///
/// This is a consumer of `LibTmux`, not part of it: everything here goes
/// through the same public surface any other caller has, which is the point —
/// if building a real layout needs something the library does not expose, that
/// is the library's problem to fix.
public enum WorkspaceBuilder {
    /// Creates the workspace's session and returns it.
    ///
    /// Fails rather than adopting an existing session of the same name: two
    /// callers building the same workspace should not silently share one.
    public static func build(
        _ workspace: Workspace,
        on server: Server
    ) async throws -> Session {
        guard !workspace.windows.isEmpty else {
            throw WorkspaceBuilderError.noWindows
        }
        let existing = try await server.sessions()
        guard !existing.contains(where: { $0.name == workspace.sessionName }) else {
            throw WorkspaceBuilderError.sessionExists(workspace.sessionName)
        }

        var session: Session?
        for (index, window) in workspace.windows.enumerated() {
            let directory = window.startDirectory ?? workspace.startDirectory
            let created: Window
            if index == 0 {
                let made = try await server.newSession(
                    named: workspace.sessionName,
                    startDirectory: directory,
                    windowName: window.windowName
                )
                session = made
                guard let first = try await server.snapshot().windows(of: made).first
                else {
                    throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
                }
                created = first
            } else {
                guard let session else {
                    throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
                }
                created = try await server.newWindow(
                    in: session,
                    named: window.windowName,
                    startDirectory: directory
                )
            }
            try await build(window, in: created, of: workspace, on: server)
        }

        guard let session else {
            throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
        }
        return session
    }

    private static func build(
        _ window: WindowPlan,
        in created: Window,
        of workspace: Workspace,
        on server: Server
    ) async throws {
        // The window arrives with one pane; only the rest are split in.
        var panes = try await server.snapshot().panes(of: created)
        for pane in window.panes.dropFirst() {
            panes.append(
                try await server.splitWindow(
                    created,
                    startDirectory: pane.startDirectory ?? window.startDirectory
                        ?? workspace.startDirectory
                )
            )
        }

        if let layout = window.layout {
            try await server.selectLayout(created, layout)
        }

        for (plan, pane) in zip(window.panes, panes) {
            for command in plan.shellCommands {
                if command.enter {
                    try await server.run(command.command, in: pane)
                } else {
                    // Typed and left sitting there. Literal, so the text lands
                    // as text rather than being read as key names.
                    try await server.sendKeys(
                        [command.command],
                        to: pane,
                        literally: true
                    )
                }
            }
        }
    }

}

public enum WorkspaceBuilderError: Error, Sendable, Hashable {
    case noWindows
    case sessionExists(String)
    case sessionVanished(String)
    /// tmux refused a command, carrying the reason it gave.
    case tmuxRejected(String)
}
