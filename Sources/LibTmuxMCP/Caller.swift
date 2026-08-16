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
    public let paneID: String?
    /// From `TMUX`, in the same spelling ``Session/id`` uses.
    public let sessionID: String?
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
            paneID: environment["TMUX_PANE"],
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
/// Not a tier decision: an agent that legitimately runs at the destructive tier
/// still must not kill the pane it is talking through, and being told why is
/// more useful than watching the transport go quiet. Every guard names an
/// escape hatch, because "kill the pane I am in" is a legitimate thing to ask
/// for — it just has to be asked for on purpose.
struct CallerGuard: Sendable {
    let identity: CallerIdentity?
    /// Whether the caller is on the server these tools address. Resolved once
    /// per call, because it costs a tmux command.
    let isSameServer: Bool

    /// The pane the caller occupies on *this* server, if any.
    var ownPane: String? { isSameServer ? identity?.paneID : nil }

    func checkPane(_ paneID: String, override: Bool) throws {
        guard !override, let own = ownPane, own == paneID else { return }
        throw ToolError.refusedForSafety(
            """
            \(paneID) is the pane this MCP server runs in. Killing it ends the \
            session you are talking through, and nothing would come back to say \
            so. Pass confirm_self=true if that is genuinely the intent.
            """
        )
    }

    func checkWindow(_ windowID: String, panes: [Pane], override: Bool) throws {
        try checkContainer(
            "window \(windowID)",
            holds: { $0.windowID == windowID },
            panes: panes,
            override: override
        )
    }

    func checkSession(_ sessionID: String, panes: [Pane], override: Bool) throws {
        try checkContainer(
            "session \(sessionID)",
            holds: { $0.sessionID == sessionID },
            panes: panes,
            override: override
        )
    }

    func checkServer(override: Bool) throws {
        guard !override, isSameServer else { return }
        throw ToolError.refusedForSafety(
            """
            This is the tmux server the MCP runs inside, and killing it takes \
            every session on it — the one you are talking through included. Pass \
            confirm_self=true if that is genuinely the intent.
            """
        )
    }

    private func checkContainer(
        _ described: String,
        holds: (Pane) -> Bool,
        panes: [Pane],
        override: Bool
    ) throws {
        guard !override, let own = ownPane else { return }
        guard panes.contains(where: { $0.id == own && holds($0) }) else { return }
        throw ToolError.refusedForSafety(
            """
            \(described) holds \(own), the pane this MCP server runs in. Killing it \
            ends the session you are talking through, and nothing would come back \
            to say so. Pass confirm_self=true if that is genuinely the intent.
            """
        )
    }
}
