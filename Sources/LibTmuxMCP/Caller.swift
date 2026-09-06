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
    /// The surrounding server's process id. This, rather than the socket path,
    /// is what identifies a server: a daemon that died and was replaced binds
    /// the same path, and comparing paths would then call the replacement
    /// "ours" and refuse to touch panes that only reuse an id.
    public let serverProcessID: Int?

    /// Reads the surrounding tmux, or `nil` when there is none.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CallerIdentity? {
        guard let context = TmuxContext.current(environment: environment) else {
            return nil
        }
        return CallerIdentity(
            paneID: environment["TMUX_PANE"].flatMap(PaneID.init(rawValue:)),
            sessionID: context.sessionID,
            socketPath: context.socketPath,
            serverProcessID: context.serverProcessID
        )
    }

    /// Whether `server` is the tmux this process is running inside.
    public func isOn(serverProcessID processID: Int?) -> Bool {
        guard let serverProcessID, let processID else { return false }
        return serverProcessID == processID
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
