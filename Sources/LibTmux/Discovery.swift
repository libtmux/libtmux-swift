import Foundation

/// A tmux server found listening on a socket.
public struct DiscoveredServer: Sendable, Hashable, Codable {
    public let socketPath: String
    public let processID: Int?
    public let sessionCount: Int

    public init(socketPath: String, processID: Int?, sessionCount: Int) {
        self.socketPath = socketPath
        self.processID = processID
        self.sessionCount = sessionCount
    }
}

/// Finding the tmux servers already running on this machine.
///
/// Every other call in this library addresses a server the caller already
/// names. This is the one that answers "what is there?" — which a program
/// arriving in an unfamiliar environment cannot ask any other way, because a
/// tmux server is a socket on disk and nothing enumerates them.
public enum TmuxServers {
    /// Where tmux puts sockets when nobody says otherwise.
    ///
    /// tmux builds this from the real user id, not the name, and honours
    /// `TMUX_TMPDIR` above it.
    public static func defaultDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        if let named = environment["TMUX_TMPDIR"], !named.isEmpty { return [named] }
        return ["/tmp/tmux-\(getuid())"]
    }

    /// Every server listening on a socket in `directories`.
    ///
    /// A socket file is not a running server: tmux leaves the file behind when
    /// it exits, so each candidate is asked whether it answers. One that does
    /// not is left out rather than reported as an empty server.
    ///
    /// - Parameters:
    ///   - directories: where to look. Defaults to
    ///     ``defaultDirectories(environment:)``.
    ///   - tmuxExecutable: the tmux to ask with.
    public static func discover(
        in directories: [String]? = nil,
        tmuxExecutable: String = "tmux"
    ) async -> [DiscoveredServer] {
        let roots = directories ?? defaultDirectories()
        var candidates: [String] = []
        for root in roots {
            let contents =
                (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for entry in contents.sorted() {
                let path = "\(root)/\(entry)"
                var isDirectory: ObjCBool = false
                guard
                    FileManager.default.fileExists(
                        atPath: path,
                        isDirectory: &isDirectory
                    ), !isDirectory.boolValue
                else { continue }
                candidates.append(path)
            }
        }

        // Probed concurrently: a socket whose server has gone costs a tmux
        // process that waits for a connection nobody will answer, and doing
        // that one at a time makes the whole scan as slow as the sum of them.
        return await withTaskGroup(of: DiscoveredServer?.self) { group in
            for path in candidates {
                group.addTask {
                    guard
                        let server = try? Server(
                            socketPath: path,
                            tmuxExecutable: tmuxExecutable
                        )
                    else { return nil }
                    guard let sessions = try? await server.sessions(),
                        !sessions.isEmpty
                    else { return nil }
                    return DiscoveredServer(
                        socketPath: path,
                        processID: try? await server.serverProcessID(),
                        sessionCount: sessions.count
                    )
                }
            }
            var found: [DiscoveredServer] = []
            for await server in group {
                if let server { found.append(server) }
            }
            return found.sorted { $0.socketPath < $1.socketPath }
        }
    }
}
