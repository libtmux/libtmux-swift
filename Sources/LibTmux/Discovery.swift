import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

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

/// The bounded result of scanning for tmux servers.
public struct ServerDiscovery: Sendable, Hashable, Codable {
    public let servers: [DiscoveredServer]
    /// Whether the scan stopped at its entry or socket-candidate ceiling.
    public let truncated: Bool
}

/// Finding the tmux servers already running on this machine.
///
/// Every other call in this library addresses a server the caller already
/// names. This is the one that answers "what is there?" — which a program
/// arriving in an unfamiliar environment cannot ask any other way, because a
/// tmux server is a socket on disk and nothing enumerates them.
public enum TmuxServers {
    /// The most socket candidates one discovery probes and can return.
    package static let maximumCandidates = 128
    private static let maximumInspectedEntries = 4_096
    private static let maximumConcurrentProbes = 8
    private static let defaultProbeTimeout = Duration.seconds(2)

    /// Where tmux puts sockets when nobody says otherwise.
    ///
    /// tmux builds this from the real user id, not the name, and honours
    /// `TMUX_TMPDIR` above it.
    public static func defaultDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let parent = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return [(parent as NSString).appendingPathComponent("tmux-\(getuid())")]
    }

    /// Every server listening on a socket in `directories`.
    ///
    /// A socket file is not a running server: tmux leaves the file behind when
    /// it exits, so each candidate is asked whether it answers. One that does
    /// not answer within two seconds is left out rather than reported as an
    /// empty server. At most eight candidates are asked at once.
    ///
    /// - Parameters:
    ///   - directories: where to look. Defaults to
    ///     ``defaultDirectories(environment:)``.
    ///   - tmuxExecutable: the tmux to ask with.
    /// - Returns: At most 128 reachable servers and whether the scan stopped
    ///   before exhausting entries or candidates.
    /// - Throws: ``TmuxError/cancelled`` when the calling task is cancelled.
    public static func discover(
        in directories: [String]? = nil,
        tmuxExecutable: String = "tmux"
    ) async throws(TmuxError) -> ServerDiscovery {
        @Sendable func probe(_ path: String) async throws(TmuxError) -> DiscoveredServer? {
            let server: Server
            do {
                server = try Server(
                    socketPath: path,
                    tmuxExecutable: tmuxExecutable
                )
            } catch {
                return nil
            }
            let sessions: [Session]
            do {
                sessions = try await server.sessions()
            } catch let error {
                if error == .cancelled { throw error }
                return nil
            }
            if sessions.isEmpty {
                guard try await server.isRunning() else { return nil }
            }
            let processID: Int?
            do {
                processID = try await server.serverProcessID()
            } catch let error {
                if error == .cancelled { throw error }
                processID = nil
            }
            return DiscoveredServer(
                socketPath: path,
                processID: processID,
                sessionCount: sessions.count
            )
        }
        return try await discover(
            in: directories,
            probeTimeout: defaultProbeTimeout,
            probe: probe
        )
    }

    static func discover(
        in directories: [String]? = nil,
        probeTimeout: Duration = defaultProbeTimeout,
        probe: @escaping @Sendable (String) async throws(TmuxError) -> DiscoveredServer?
    ) async throws(TmuxError) -> ServerDiscovery {
        let roots = directories ?? defaultDirectories()
        let scan = try scanCandidates(in: roots)

        if Task.isCancelled { throw .cancelled }
        return try await discover(
            candidates: scan.candidates,
            truncatedFromScan: scan.truncated,
            probeTimeout: probeTimeout,
            probe: probe
        )
    }

    private static func scanCandidates(
        in roots: [String]
    ) throws(TmuxError) -> CandidateScan {
        var scan = CandidateScan()
        roots: for root in roots {
            guard
                let entries = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: nil,
                    options: [.skipsSubdirectoryDescendants]
                )
            else { continue }
            for case let entry as URL in entries {
                if Task.isCancelled { throw .cancelled }
                guard scan.inspect(entry.path, isSocket: isSocket(at:)) else { break roots }
            }
        }
        return scan
    }

    static func discover<Entries: Sequence>(
        entries: Entries,
        isSocket: (String) -> Bool,
        probeTimeout: Duration = defaultProbeTimeout,
        probe: @escaping @Sendable (String) async throws(TmuxError) -> DiscoveredServer?
    ) async throws(TmuxError) -> ServerDiscovery where Entries.Element == String {
        var scan = CandidateScan()
        for entry in entries {
            if Task.isCancelled { throw .cancelled }
            guard scan.inspect(entry, isSocket: isSocket) else { break }
        }
        return try await discover(
            candidates: scan.candidates,
            truncatedFromScan: scan.truncated,
            probeTimeout: probeTimeout,
            probe: probe
        )
    }

    static func discover(
        candidates discoveredCandidates: [String],
        truncatedFromScan: Bool = false,
        probeTimeout: Duration = defaultProbeTimeout,
        probe: @escaping @Sendable (String) async throws(TmuxError) -> DiscoveredServer?
    ) async throws(TmuxError) -> ServerDiscovery {
        let truncated = truncatedFromScan || discoveredCandidates.count > maximumCandidates
        let candidates = Array(discoveredCandidates.prefix(maximumCandidates))
        do {
            return try await withThrowingTaskGroup(of: DiscoveredServer?.self) { group in
                var nextCandidate = 0
                for _ in 0..<min(maximumConcurrentProbes, candidates.count) {
                    let path = candidates[nextCandidate]
                    nextCandidate += 1
                    group.addTask {
                        try await probeCandidate(path, timeout: probeTimeout, using: probe)
                    }
                }
                var found: [DiscoveredServer] = []
                while let server = try await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        throw TmuxError.cancelled
                    }
                    if let server { found.append(server) }
                    if nextCandidate < candidates.count {
                        let path = candidates[nextCandidate]
                        nextCandidate += 1
                        group.addTask {
                            try await probeCandidate(path, timeout: probeTimeout, using: probe)
                        }
                    }
                }
                return ServerDiscovery(
                    servers: found.sorted { $0.socketPath < $1.socketPath },
                    truncated: truncated
                )
            }
        } catch {
            throw normalizedTmuxError(error)
        }
    }

    private static func probeCandidate(
        _ path: String,
        timeout: Duration,
        using probe: @escaping @Sendable (String) async throws(TmuxError) -> DiscoveredServer?
    ) async throws(TmuxError) -> DiscoveredServer? {
        if Task.isCancelled { throw .cancelled }
        do {
            let completion = try await withThrowingTaskGroup(of: ProbeCompletion.self) { group in
                group.addTask { .result(try await probe(path)) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? .timedOut
            }
            if Task.isCancelled { throw TmuxError.cancelled }
            switch completion {
            case let .result(server): return server
            case .timedOut: return nil
            }
        } catch let error as TmuxError {
            if error == .cancelled { throw error }
            return nil
        } catch {
            if error is CancellationError || Task.isCancelled { throw .cancelled }
            return nil
        }
    }

    private enum ProbeCompletion: Sendable {
        case result(DiscoveredServer?)
        case timedOut
    }

    private static func isSocket(at path: String) -> Bool {
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
    }

    private struct CandidateScan {
        var candidates: [String] = []
        var truncated = false
        private var inspectedEntries = 0
        private var seen: Set<String> = []

        mutating func inspect(_ path: String, isSocket: (String) -> Bool) -> Bool {
            guard inspectedEntries < TmuxServers.maximumInspectedEntries else {
                truncated = true
                return false
            }
            inspectedEntries += 1
            guard isSocket(path), seen.insert(path).inserted else { return true }
            candidates.append(path)
            guard candidates.count <= TmuxServers.maximumCandidates else {
                truncated = true
                return false
            }
            return true
        }
    }
}
