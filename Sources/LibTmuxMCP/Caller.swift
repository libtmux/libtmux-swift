import Foundation
import LibTmux

/// Where this MCP server is itself running, when that is inside tmux.
///
/// An agent driving tmux from a pane is one `kill-pane` away from ending the
/// conversation it is having. Knowing which pane is its own is what lets the
/// tools refuse that, and lets a listing mark the row that is the caller so the
/// agent never has to ask.
public struct CallerIdentity: Sendable, Hashable, Codable {
    /// From `TMUX_PANE`, which tmux sets in every process it starts.
    public let paneID: PaneID?
    /// From `TMUX`, in the same `$…` spelling as a session id.
    public let sessionID: SessionID?
    public let socketPath: String?
    /// The surrounding server's process id. It authenticates alternate routes
    /// to one socket and rejects a daemon that replaced one exact route.
    public let serverProcessID: Int?

    /// Reads the surrounding tmux, or `nil` when both context variables are absent.
    ///
    /// An incomplete or malformed environment remains present as an invalid
    /// identity so an input guard cannot mistake it for a detached process.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CallerIdentity? {
        let hasTmux = environment.keys.contains("TMUX")
        let hasPane = environment.keys.contains("TMUX_PANE")
        guard hasTmux || hasPane else {
            return nil
        }
        guard let rawTmux = environment["TMUX"],
            let context = TmuxContext(parsing: rawTmux),
            let rawPane = environment["TMUX_PANE"],
            let paneID = PaneID(rawValue: rawPane)
        else {
            return CallerIdentity(
                paneID: nil,
                sessionID: nil,
                socketPath: nil,
                serverProcessID: nil
            )
        }
        return CallerIdentity(
            paneID: paneID,
            sessionID: context.sessionID,
            socketPath: context.socketPath,
            serverProcessID: context.serverProcessID
        )
    }

    /// Whether `server` is the tmux this process is running inside, including
    /// when caller and server reached its socket through different links.
    public func isOn(_ server: ServerIncarnation) -> Bool {
        guard let serverProcessID, let socketPath, Self.isSafeSocketPath(socketPath) else {
            return false
        }
        return serverProcessID == server.processID
    }

    fileprivate static func isSafeSocketPath(_ path: String) -> Bool {
        path.utf8.first == 0x2f
            && !path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f })
    }
}

/// Refuses the calls that would end the conversation.
///
/// Not a toolset decision: an agent with teardown authority still must not kill
/// the pane it is talking through, and being told why is
/// more useful than watching the transport go quiet. Every guard names an
/// escape hatch, because "kill the pane I am in" is a legitimate thing to ask
/// for — it just has to be asked for on purpose.
struct CallerGuard: Sendable {
    let identity: CallerIdentity?
    /// Whether the caller is on the server these tools address. Resolved once
    /// per call, because it costs a tmux command.
    let isSameServer: Bool

    /// The pane the caller occupies on *this* server, if any.
    var ownPane: PaneID? { isSameServer ? identity?.paneID : nil }

    func validate(in snapshot: Snapshot) throws {
        guard let identity else {
            guard !isSameServer else {
                throw ToolError.refusedForSafety("caller context is inconsistent")
            }
            return
        }
        guard let paneID = identity.paneID,
            let sessionID = identity.sessionID,
            let socketPath = identity.socketPath,
            CallerIdentity.isSafeSocketPath(socketPath),
            let processID = identity.serverProcessID,
            processID > 0
        else {
            throw ToolError.refusedForSafety("caller context is incomplete or malformed")
        }

        if socketPath == snapshot.incarnation.socketPath,
            processID != snapshot.serverProcessID
        {
            throw ToolError.refusedForSafety(
                "caller context names a stale selected tmux daemon"
            )
        }
        guard processID == snapshot.serverProcessID else {
            guard !isSameServer else {
                throw ToolError.refusedForSafety("caller context is inconsistent")
            }
            return
        }
        guard isSameServer else {
            throw ToolError.refusedForSafety("caller context is inconsistent")
        }
        let sessions = snapshot.sessions.filter {
            $0.incarnation == snapshot.incarnation && $0.id == sessionID
        }
        let panes = snapshot.panes.filter {
            $0.incarnation == snapshot.incarnation && $0.id == paneID
        }
        guard sessions.count == 1,
            let pane = panes.first,
            panes.count == 1,
            snapshot.windows.filter({
                $0.incarnation == snapshot.incarnation && $0.id == pane.windowID
            }).count == 1,
            snapshot.windowLinks.contains(where: {
                $0.incarnation == snapshot.incarnation
                    && $0.sessionID == sessionID && $0.windowID == pane.windowID
            })
        else {
            throw ToolError.refusedForSafety(
                "caller context does not resolve in the selected tmux snapshot"
            )
        }
    }

    func checkPane(_ paneID: PaneID, override: Bool) throws {
        guard !override, let own = ownPane, own == paneID else { return }
        throw ToolError.refusedForSafety(
            """
            \(paneID) is the pane this MCP server runs in. Killing it ends the \
            session you are talking through, and nothing would come back to say \
            so. Pass force=true if that is genuinely the intent.
            """
        )
    }

    func checkPaneInput(_ paneID: PaneID, override: Bool) throws {
        guard !override, let own = ownPane, own == paneID else { return }
        throw ToolError.refusedForSafety(
            "\(paneID) is the pane this MCP server runs in; pass force=true to send input there"
        )
    }

    func checkWindow(_ windowID: WindowID, override: Bool) throws {
        try checkContainer(
            "window \(windowID)",
            override: override
        )
    }

    func checkSession(_ sessionID: SessionID, override: Bool) throws {
        try checkContainer("session \(sessionID)", override: override)
    }

    private func checkContainer(
        _ described: String,
        override: Bool
    ) throws {
        guard !override, let own = ownPane else { return }
        throw ToolError.refusedForSafety(
            """
            \(described) is on the server containing \(own), the pane this MCP runs \
            in. Pane membership can change between inspection and a separate kill, \
            so this cannot safely prove the container will still exclude the caller. \
            Pass force=true if killing it is genuinely the intent.
            """
        )
    }
}
