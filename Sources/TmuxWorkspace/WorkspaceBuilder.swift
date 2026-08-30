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
    /// A failure after creation removes that exact session. If cleanup also
    /// fails, ``WorkspaceBuilderError/rollbackFailed(original:cleanup:)``
    /// reports both errors.
    public static func build(
        _ workspace: Workspace,
        on server: Server
    ) async throws(WorkspaceBuilderError) -> Session {
        guard !workspace.windows.isEmpty else {
            throw WorkspaceBuilderError.noWindows
        }
        let existing: [Session]
        do {
            existing = try await server.sessions()
        } catch {
            throw .tmux(error)
        }
        guard !existing.contains(where: { $0.name == workspace.sessionName }) else {
            throw WorkspaceBuilderError.sessionExists(workspace.sessionName)
        }

        var session: Session?
        do {
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
                    ).window
                }
                try await build(window, in: created, of: workspace, on: server)
            }

            guard let session else {
                throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
            }
            return session
        } catch {
            let original = Self.builderError(error)
            guard let session else { throw original }
            if let cleanup = await rollback(session, on: server) {
                throw .rollbackFailed(original: original, cleanup: cleanup)
            }
            throw original
        }
    }

    static func rollback(
        _ session: Session,
        on server: Server,
        timeout: Duration = .seconds(5)
    ) async -> TmuxError? {
        let cleanup = Task.detached { () -> TmuxError? in
            do {
                try await server.kill(session)
                return nil
            } catch let error as TmuxError {
                return error
            } catch {
                return .invocationFailed(reason: String(describing: error))
            }
        }
        let deadline = Task.detached {
            try? await Task.sleep(for: max(.zero, timeout))
        }
        let winner = await withTaskGroup(of: RollbackRace.self) { group in
            group.addTask { .cleanup(await cleanup.value) }
            group.addTask {
                await deadline.value
                return .deadline
            }
            let winner = await group.next() ?? .deadline
            switch winner {
            case .cleanup:
                deadline.cancel()
            case .deadline:
                cleanup.cancel()
            }
            group.cancelAll()
            return winner
        }
        switch winner {
        case let .cleanup(error):
            return error
        case .deadline:
            return .invocationFailed(reason: "workspace rollback timed out")
        }
    }

    private static func builderError(_ error: any Error) -> WorkspaceBuilderError {
        if let error = error as? WorkspaceBuilderError { return error }
        if let error = error as? TmuxError { return .tmux(error) }
        if error is CancellationError || Task.isCancelled { return .tmux(.cancelled) }
        return .tmux(.invocationFailed(reason: String(describing: error)))
    }

    private static func build(
        _ window: WindowPlan,
        in created: Window,
        of workspace: Workspace,
        on server: Server
    ) async throws(TmuxError) {
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

private enum RollbackRace: Sendable {
    case cleanup(TmuxError?)
    case deadline
}

public indirect enum WorkspaceBuilderError: Error, Sendable, Hashable {
    case noWindows
    case sessionExists(String)
    case sessionVanished(String)
    case tmux(TmuxError)
    case rollbackFailed(original: WorkspaceBuilderError, cleanup: TmuxError)
}
