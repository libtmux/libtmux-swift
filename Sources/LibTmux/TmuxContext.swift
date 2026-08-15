import Foundation

/// Where the tmux this process is running inside can be found.
///
/// tmux sets `$TMUX` in every process it starts, holding the socket, the
/// server's pid, and the session — which is how a program launched from a pane
/// can find its way back to the server that launched it without being told.
///
/// The session arrives as a bare number where ``Session/id`` carries tmux's
/// `$` sigil, so it is normalised here. Comparing the two spellings directly is
/// a mismatch that looks like a missing session.
public struct TmuxContext: Sendable, Hashable, Codable {
    /// The socket the surrounding server listens on, which is what addressing
    /// it again needs.
    public let socketPath: String
    /// The server process, which is the one thing here that distinguishes two
    /// servers that reused a socket path.
    public let serverProcessID: Int
    /// The session, in the same spelling ``Session/id`` uses.
    public let sessionID: String

    public init(socketPath: String, serverProcessID: Int, sessionID: String) {
        self.socketPath = socketPath
        self.serverProcessID = serverProcessID
        self.sessionID = sessionID
    }

    /// Reads the value tmux puts in `$TMUX`.
    ///
    /// Returns `nil` for anything that is not that shape, including an empty
    /// string: a process not started by tmux has no context to report, and
    /// inventing one would point at a server that may not exist.
    public init?(parsing tmuxVariable: String) {
        // Split from the right: the last two fields are numbers, and the first
        // is a path, which is the only field allowed to contain a comma.
        let parts = tmuxVariable.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3,
            let processID = Int(parts[parts.count - 2]),
            !parts[parts.count - 1].isEmpty
        else { return nil }

        let path = parts[0..<(parts.count - 2)].joined(separator: ",")
        guard !path.isEmpty else { return nil }

        let session = String(parts[parts.count - 1])
        guard session.allSatisfy(\.isNumber) else { return nil }

        self.init(
            socketPath: path,
            serverProcessID: processID,
            sessionID: "$\(session)"
        )
    }

    /// The context of the tmux this process is running inside, or `nil` when it
    /// is not running inside one.
    ///
    /// - Parameter environment: where to read `$TMUX` from. Injectable so that
    ///   a caller — or a test — can ask about an environment other than its own.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TmuxContext? {
        guard let value = environment["TMUX"] else { return nil }
        return TmuxContext(parsing: value)
    }

    /// A server addressed at this context's socket.
    ///
    /// Separate from reading the context because addressing can fail — a socket
    /// path has a hard length limit — where reading an environment variable
    /// cannot.
    public func server(tmuxExecutable: String = "tmux") throws(TmuxError) -> Server {
        try Server(socketPath: socketPath, tmuxExecutable: tmuxExecutable)
    }
}
