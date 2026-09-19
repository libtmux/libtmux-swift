import Foundation
import LibTmux

package enum WorkspaceBuildEvent: Sendable {
    case sessionCreated(session: Session)
    case windowStarted(index: Int, window: Window, session: Session)
    case paneStarted(windowIndex: Int, index: Int, pane: Pane, window: Window, session: Session)
    case paneCompleted(windowIndex: Int, index: Int, pane: Pane, window: Window, session: Session)
    /// The pane's shell drew nothing the readiness probe could see before the
    /// timeout, so its first command was sent anyway.
    case paneNotReady(windowIndex: Int, index: Int, pane: Pane, window: Window, session: Session)
    case windowCompleted(index: Int, window: Window, session: Session)
}

/// Whether a pane's first command waits for that pane's shell to draw a
/// prompt before it is sent.
///
/// Waiting is what keeps a command from being echoed by the terminal and then
/// redrawn by the shell, showing twice. It does not depend on which shell the
/// pane runs, so `automatic` and `always` mean the same thing here; `never` is
/// for a caller that has its own reason to send immediately.
package enum PaneReadiness: Sendable {
    case automatic
    case always
    case never
}

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
    /// An ordinary failure after creation removes that exact session. If
    /// cleanup also fails, ``WorkspaceBuilderError/rollbackFailed(original:cleanup:)``
    /// reports both errors. An interruption is the exception: it removes
    /// nothing, because the same signal that stopped the build could just as
    /// well stop the cleanup that would follow it.
    public static func build(
        _ workspace: Workspace,
        on server: Server
    ) async throws(WorkspaceBuilderError) -> Session {
        try await build(
            workspace, on: server, environment: [:], configureSession: { _ in },
            configureWindow: { _, _ in })
    }

    package static func build(
        _ workspace: Workspace,
        on server: Server,
        environment: [String: String],
        width: Int? = nil,
        height: Int? = nil,
        configureSession: @Sendable (Session) async throws -> Void,
        configureWindow: @Sendable (Window, Int) async throws -> Void,
        configureWindowAfter: @Sendable (Window, Int) async throws -> Void = { _, _ in },
        readiness: PaneReadiness = .automatic,
        readinessTimeout: Duration = .seconds(2),
        borrowing borrowed: Session? = nil,
        onEvent: @Sendable (WorkspaceBuildEvent) async throws -> Void = { _ in }
    ) async throws(WorkspaceBuilderError) -> Session {
        guard !workspace.windows.isEmpty else {
            throw WorkspaceBuilderError.noWindows
        }
        let existing: [Session]
        do {
            try await WorkspaceLayout.validate([workspace], on: server)
            if borrowed == nil, try await server.isRunning() {
                existing = try await server.sessions()
            } else {
                existing = []
            }
        } catch {
            throw .tmux(error)
        }
        guard !existing.contains(where: { $0.name == workspace.sessionName }) else {
            throw WorkspaceBuilderError.sessionExists(workspace.sessionName)
        }

        var session: Session? = borrowed
        var focusedWindow: Window?
        do {
            if let borrowed { try await configureSession(borrowed) }
            for (index, window) in workspace.windows.enumerated() {
                let directory =
                    window.panes.first?.startDirectory
                    ?? window.startDirectory ?? workspace.startDirectory
                // The window's first pane takes its own environment/shell
                // over the window's, matching tmuxp: a pane that names one
                // overrides what its window would otherwise supply.
                let firstPane = window.panes.first
                let windowEnvironment = firstPane?.environment ?? window.environment ?? [:]
                let windowShell = nonEmpty(firstPane?.shell) ?? window.windowShell
                let created: Window
                if index == 0 && borrowed == nil {
                    let made = try await server.newSession(
                        named: workspace.sessionName,
                        startDirectory: directory,
                        windowName: window.windowName,
                        width: width,
                        height: height,
                        environment: environment.merging(windowEnvironment) { _, new in new },
                        shell: windowShell
                    )
                    session = made
                    try await onEvent(.sessionCreated(session: made))
                    try await configureSession(made)
                    let snapshot = try await server.snapshot()
                    guard let first = snapshot.windows(of: made).first
                    else {
                        throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
                    }
                    created = first
                    if let desired = window.windowIndex,
                        let link = snapshot.windowLinks(of: made).first, link.index != desired
                    {
                        _ = try await server.move(link, to: made, at: desired)
                    }
                } else {
                    guard let session else {
                        throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
                    }
                    created = try await server.newWindow(
                        in: session,
                        named: window.windowName,
                        startDirectory: directory,
                        at: window.windowIndex,
                        environment: windowEnvironment,
                        shell: windowShell
                    ).window
                }
                guard let activeSession = session else {
                    throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
                }
                try await configureWindow(created, index)
                try await onEvent(
                    .windowStarted(index: index, window: created, session: activeSession))
                try await build(
                    window, at: index, in: created, of: workspace, on: server,
                    session: activeSession, readiness: readiness,
                    readinessTimeout: readinessTimeout, onEvent: onEvent)
                // `automatic-rename off` only holds once applied after the
                // panes that could have renamed the window already exist.
                try await configureWindowAfter(created, index)
                try await onEvent(
                    .windowCompleted(index: index, window: created, session: activeSession))
                if window.focus == true { focusedWindow = created }
            }

            guard let session else {
                throw WorkspaceBuilderError.sessionVanished(workspace.sessionName)
            }
            if let focusedWindow {
                guard
                    let link = try await server.windowLinks().first(where: {
                        $0.incarnation == session.incarnation && $0.sessionID == session.id
                            && $0.windowID == focusedWindow.id
                    })
                else { throw WorkspaceBuilderError.sessionVanished(workspace.sessionName) }
                try await server.select(link)
            }
            return session
        } catch {
            let original = Self.builderError(error)
            guard borrowed == nil, let session else { throw original }
            // A signal that interrupted the build can just as well interrupt
            // the cleanup that would follow it, so an interruption reports
            // what it retained rather than attempting a rollback that might
            // itself never finish. Rollback fires on an ordinary failure
            // only.
            guard case .tmux(.cancelled) = original else {
                if let cleanup = await rollback(session, on: server) {
                    throw .rollbackFailed(original: original, cleanup: cleanup)
                }
                throw original
            }
            throw original
        }
    }

    static func rollback(
        _ session: Session,
        on server: Server,
        timeout: Duration = .seconds(5)
    ) async -> TmuxError? {
        let race = RollbackRaceGate()
        let cleanup = Task.detached {
            let result: TmuxError?
            do {
                try await server.kill(session)
                result = nil
            } catch let error as TmuxError {
                result = error
            } catch {
                result = .invocationFailed(reason: String(describing: error))
            }
            await race.finish(.cleanup(result))
        }
        let deadline = Task.detached {
            do {
                try await Task.sleep(for: max(.zero, timeout))
            } catch {
                return
            }
            await race.finish(.deadline)
        }
        let winner = await race.value()
        switch winner {
        case let .cleanup(error):
            deadline.cancel()
            return error
        case .deadline:
            cleanup.cancel()
            return .invocationFailed(reason: "workspace rollback timed out")
        }
    }

    private static func builderError(_ error: any Error) -> WorkspaceBuilderError {
        if let error = error as? WorkspaceBuilderError { return error }
        if let error = error as? TmuxError { return .tmux(error) }
        if error is CancellationError || Task.isCancelled { return .tmux(.cancelled) }
        return .callback(error)
    }

    private static func build(
        _ window: WindowPlan,
        at windowIndex: Int,
        in created: Window,
        of workspace: Workspace,
        on server: Server,
        session: Session,
        readiness: PaneReadiness,
        readinessTimeout: Duration,
        onEvent: @Sendable (WorkspaceBuildEvent) async throws -> Void
    ) async throws {
        // The window arrives with one pane; only the rest are split in.
        var panes = try await server.snapshot().panes(of: created)
        for pane in window.panes.dropFirst() {
            guard let previous = panes.last else {
                throw TmuxError.invocationFailed(reason: "workspace window has no panes")
            }
            panes.append(
                try await server.split(
                    previous,
                    startDirectory: pane.startDirectory ?? window.startDirectory
                        ?? workspace.startDirectory,
                    environment: pane.environment ?? window.environment ?? [:],
                    shell: nonEmpty(pane.shell) ?? window.windowShell
                )
            )
            // Halving each pane in turn runs out of room by the fifth;
            // rebalancing after every split reclaims it. `window.layout`
            // below still has the final say.
            try await server.selectLayout(created, "tiled")
        }

        if let layout = window.layout, !layout.isEmpty {
            try await server.selectLayout(created, layout)
        }

        for (index, pair) in zip(window.panes, panes).enumerated() {
            let (plan, pane) = pair
            try await onEvent(
                .paneStarted(
                    windowIndex: windowIndex, index: index, pane: pane, window: created,
                    session: session))
            if !plan.shellCommands.isEmpty, readiness != .never,
                nonEmpty(plan.shell) ?? window.windowShell == nil,
                !(await waitForPrompt(pane, on: server, timeout: readinessTimeout))
            {
                try await onEvent(
                    .paneNotReady(
                        windowIndex: windowIndex, index: index, pane: pane, window: created,
                        session: session))
            }
            for command in plan.shellCommands {
                if let seconds = plan.sleepBefore, seconds > 0 {
                    try await Task.sleep(for: .seconds(seconds))
                }
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
                if let seconds = plan.sleepAfter, seconds > 0 {
                    try await Task.sleep(for: .seconds(seconds))
                }
            }
            try await onEvent(
                .paneCompleted(
                    windowIndex: windowIndex, index: index, pane: pane, window: created,
                    session: session))
        }
        // Pairing forward keeps this on the same pane the commands above
        // reached; a window that arrived with panes of its own makes the two
        // ends of the zip disagree.
        //
        // With no pane asking for focus the last one built is left active,
        // which is where tmuxp leaves it; splitting detached would otherwise
        // leave the first.
        let planned = Array(zip(window.panes, panes))
        let focused = planned.last { $0.0.focus == true }?.1 ?? planned.last?.1
        if let focused { try await server.select(focused) }
    }

    /// Waits up to `timeout` for `pane`'s shell to draw its prompt — moving
    /// the cursor away from the pane's top-left corner — so the first
    /// command sent to a freshly created pane is not echoed ahead of the
    /// prompt and then redrawn after it, showing twice.
    ///
    /// Reports whether the prompt was seen. A pane that cannot be read is
    /// counted as ready: there is nothing to wait for and nothing to say. A
    /// prompt that leaves the cursor where it started — `PS1=` — is
    /// indistinguishable from a shell that has not started, so the wait runs
    /// out, and the caller is told rather than the pane silently costing the
    /// whole timeout.
    private static func waitForPrompt(
        _ pane: Pane, on server: Server, timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            guard let cursor = try? await server.formatGlobal("#{cursor_x},#{cursor_y}", for: pane)
            else { return true }
            if cursor != "0,0" { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return true }
        }
        return false
    }

}

private enum RollbackRace: Sendable {
    case cleanup(TmuxError?)
    case deadline
}

private actor RollbackRaceGate {
    private var result: RollbackRace?
    private var waiter: CheckedContinuation<RollbackRace, Never>?

    func finish(_ result: RollbackRace) {
        guard self.result == nil else { return }
        self.result = result
        waiter?.resume(returning: result)
        waiter = nil
    }

    func value() async -> RollbackRace {
        if let result { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// tmuxp treats an empty pane-level `shell`/`window_shell` override the same
/// as one left out, rather than as a command to run nothing.
private func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

public indirect enum WorkspaceBuilderError: Error {
    case noWindows
    case sessionExists(String)
    case sessionVanished(String)
    case tmux(TmuxError)
    /// Whatever a configuration or event callback raised, carried whole: the
    /// caller that supplied the callback is the only one that can read it.
    case callback(any Error)
    case rollbackFailed(original: WorkspaceBuilderError, cleanup: TmuxError)
}
