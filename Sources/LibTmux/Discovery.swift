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
    /// Failed probes and skipped filesystem entries, within the scan limits.
    public let diagnostics: [DiscoveryDiagnostic]

    public init(
        servers: [DiscoveredServer], truncated: Bool, diagnostics: [DiscoveryDiagnostic] = []
    ) {
        self.servers = servers
        self.truncated = truncated
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey { case servers, truncated, diagnostics }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        servers = try values.decode([DiscoveredServer].self, forKey: .servers)
        truncated = try values.decode(Bool.self, forKey: .truncated)
        diagnostics =
            try values.decodeIfPresent([DiscoveryDiagnostic].self, forKey: .diagnostics) ?? []
    }
}

/// A skipped path or a probe that did not return a reachable tmux daemon.
public struct DiscoveryDiagnostic: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case invalidRoot, unreadableRoot, skippedEntry, duplicate, failedProbe, timedOut
    }
    public let path: String
    public let kind: Kind
    public let detail: String
}

/// Finite filesystem and subprocess work for one discovery call.
public struct DiscoveryLimits: Sendable {
    public var maximumRoots: Int
    public var maximumEntries: Int
    public var maximumProbes: Int
    public var concurrentProbes: Int
    public var probeTimeout: Duration

    public init(
        maximumRoots: Int = 64, maximumEntries: Int = 4_096,
        maximumProbes: Int = 128, concurrentProbes: Int = 8,
        probeTimeout: Duration = .seconds(2)
    ) {
        self.maximumRoots = maximumRoots
        self.maximumEntries = maximumEntries
        self.maximumProbes = maximumProbes
        self.concurrentProbes = concurrentProbes
        self.probeTimeout = probeTimeout
    }

    func validate() throws(TmuxError) {
        guard maximumRoots > 0, maximumRoots <= 1_024,
            maximumEntries > 0, maximumEntries <= 65_536,
            maximumProbes > 0, maximumProbes <= 1_024,
            concurrentProbes > 0, concurrentProbes <= 64,
            probeTimeout > .zero, probeTimeout <= .seconds(60)
        else {
            throw .invocationFailed(reason: "discovery limits exceed their finite supported bounds")
        }
    }
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
    /// not answer within the configured timeout produces a diagnostic rather
    /// than an empty-server result. Defaults allow eight concurrent probes,
    /// each with two seconds to finish. The scan skips final symlink roots and
    /// entries; the filesystem resolves intermediate components unchanged.
    ///
    /// - Parameters:
    ///   - directories: where to look. Defaults to
    ///     ``defaultDirectories(environment:)``.
    ///   - tmuxExecutable: the tmux to ask with.
    ///   - environment: a captured child environment and default-root source;
    ///     discovery does not mutate the caller's environment.
    ///   - limits: root, entry, probe and concurrency ceilings and each probe's timeout.
    /// - Returns: Reachable servers, skipped/failed diagnostics and truncation.
    ///   The default probe ceiling is 128; these roots are not a machine-wide inventory.
    /// - Throws: ``TmuxError/cancelled`` when the calling task is cancelled.
    public static func discover(
        in directories: [String]? = nil,
        tmuxExecutable: String = "tmux",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        limits: DiscoveryLimits = DiscoveryLimits()
    ) async throws(TmuxError) -> ServerDiscovery {
        try limits.validate()
        @Sendable func probe(_ path: String) async throws(TmuxError) -> DiscoveredServer? {
            let server = try Server(
                endpoint: .socketPath(path), tmuxExecutable: tmuxExecutable,
                environment: environment, transport: DiscoveryTransport())
            let before = try await server.incarnation()
            let sessions = try await server.sessions()
            let after = try await server.incarnation()
            guard before == after else { throw .serverRestarted }
            return DiscoveredServer(
                socketPath: path, processID: before.processID, sessionCount: sessions.count)
        }
        return try await discover(
            in: directories ?? defaultDirectories(environment: environment),
            probeTimeout: limits.probeTimeout, limits: limits, probe: probe)
    }

    static func discover(
        in directories: [String]? = nil,
        probeTimeout: Duration = defaultProbeTimeout,
        limits: DiscoveryLimits = DiscoveryLimits(),
        probe: @escaping @Sendable (String) async throws(TmuxError) -> DiscoveredServer?
    ) async throws(TmuxError) -> ServerDiscovery {
        try limits.validate()
        let scan = try scanCandidates(in: directories ?? defaultDirectories(), limits: limits)
        if Task.isCancelled { throw .cancelled }
        return try await discover(
            candidates: scan.candidates, truncatedFromScan: scan.truncated,
            probeTimeout: probeTimeout, limits: limits, diagnostics: scan.diagnostics, probe: probe)
    }

    private static func scanCandidates(in roots: [String], limits: DiscoveryLimits)
        throws(TmuxError) -> CandidateScan
    {
        var scan = CandidateScan(limits: limits)
        scan.truncated = roots.count > limits.maximumRoots
        roots: for root in roots.prefix(limits.maximumRoots) {
            if Task.isCancelled { throw .cancelled }
            guard root.hasPrefix("/"), !root.contains("\0") else {
                scan.diagnostics.append(
                    DiscoveryDiagnostic(
                        path: root, kind: .invalidRoot, detail: "root must be an absolute path"))
                continue
            }
            var status = stat()
            guard lstat(root, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                let directory = opendir(root)
            else {
                scan.diagnostics.append(
                    DiscoveryDiagnostic(
                        path: root, kind: .unreadableRoot,
                        detail: "root is not a readable real directory"))
                continue
            }
            defer { closedir(directory) }
            // POSIX traversal preserves symlink/.. and missing/.. semantics.
            // URL standardization would change the path being inspected.
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 {
                        scan.diagnostics.append(
                            DiscoveryDiagnostic(
                                path: root, kind: .unreadableRoot,
                                detail: String(cString: strerror(errno))))
                    }
                    break
                }
                if Task.isCancelled { throw .cancelled }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(
                        to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                    ) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                guard scan.inspect(root + "/" + name, isSocket: isSocket(at:)) else { break roots }
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
        var scan = CandidateScan(limits: DiscoveryLimits())
        for entry in entries {
            if Task.isCancelled { throw .cancelled }
            guard scan.inspect(entry, isSocket: isSocket) else { break }
        }
        return try await discover(
            candidates: scan.candidates,
            truncatedFromScan: scan.truncated,
            probeTimeout: probeTimeout,
            diagnostics: scan.diagnostics,
            probe: probe
        )
    }

    static func discover(
        candidates discoveredCandidates: [String],
        truncatedFromScan: Bool = false,
        probeTimeout: Duration = defaultProbeTimeout,
        limits: DiscoveryLimits = DiscoveryLimits(),
        diagnostics: [DiscoveryDiagnostic] = [],
        probe: @escaping @Sendable (String) async throws(TmuxError) -> DiscoveredServer?
    ) async throws(TmuxError) -> ServerDiscovery {
        try limits.validate()
        let truncated = truncatedFromScan || discoveredCandidates.count > limits.maximumProbes
        let candidates = Array(discoveredCandidates.prefix(limits.maximumProbes))
        do {
            return try await withThrowingTaskGroup(of: ProbeResult.self) { group in
                var nextCandidate = 0
                for _ in 0..<min(limits.concurrentProbes, candidates.count) {
                    let path = candidates[nextCandidate]
                    nextCandidate += 1
                    group.addTask {
                        try await probeCandidate(path, timeout: probeTimeout, using: probe)
                    }
                }
                var found: [DiscoveredServer] = []
                var notes = diagnostics
                while let server = try await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        throw TmuxError.cancelled
                    }
                    if let value = server.server { found.append(value) }
                    if let diagnostic = server.diagnostic { notes.append(diagnostic) }
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
                    truncated: truncated,
                    diagnostics: notes.sorted {
                        ($0.path, $0.kind.rawValue) < ($1.path, $1.kind.rawValue)
                    }
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
    ) async throws(TmuxError) -> ProbeResult {
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
            case let .result(server):
                return ProbeResult(
                    server: server,
                    diagnostic: server == nil
                        ? DiscoveryDiagnostic(
                            path: path, kind: .failedProbe,
                            detail: "probe returned no reachable server") : nil)
            case .timedOut:
                return ProbeResult(
                    server: nil,
                    diagnostic: DiscoveryDiagnostic(
                        path: path, kind: .timedOut, detail: "probe deadline expired"))
            }
        } catch let error as TmuxError {
            if error == .cancelled { throw error }
            return ProbeResult(
                server: nil,
                diagnostic: DiscoveryDiagnostic(
                    path: path, kind: .failedProbe, detail: String(describing: error)))
        } catch {
            if error is CancellationError || Task.isCancelled { throw .cancelled }
            return ProbeResult(
                server: nil,
                diagnostic: DiscoveryDiagnostic(
                    path: path, kind: .failedProbe, detail: String(describing: error)))
        }
    }

    private struct ProbeResult: Sendable {
        let server: DiscoveredServer?
        let diagnostic: DiscoveryDiagnostic?
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
        let limits: DiscoveryLimits
        var diagnostics: [DiscoveryDiagnostic] = []
        var candidates: [String] = []
        var truncated = false
        private var inspectedEntries = 0
        private var seen: Set<String> = []

        init(limits: DiscoveryLimits) { self.limits = limits }

        mutating func inspect(_ path: String, isSocket: (String) -> Bool) -> Bool {
            guard inspectedEntries < limits.maximumEntries else {
                truncated = true
                return false
            }
            inspectedEntries += 1
            guard isSocket(path) else {
                diagnostics.append(
                    DiscoveryDiagnostic(
                        path: path, kind: .skippedEntry,
                        detail: "entry is not a socket or is a symlink"))
                return true
            }
            guard seen.insert(path).inserted else {
                diagnostics.append(
                    DiscoveryDiagnostic(
                        path: path, kind: .duplicate, detail: "socket path was already inspected"))
                return true
            }
            candidates.append(path)
            guard candidates.count <= limits.maximumProbes else {
                truncated = true
                return false
            }
            return true
        }
    }
}

/// Discovery clients cannot create a daemon when a socket disappears during probing.
private struct DiscoveryTransport: ProcessTransport {
    func run(
        executable: String, arguments: [String], environment: [String: String],
        perStreamOutputLimit: Int
    ) async throws(TmuxError) -> TmuxReply {
        try await SubprocessTransport().run(
            executable: executable, arguments: ["-N"] + arguments,
            environment: environment, perStreamOutputLimit: perStreamOutputLimit)
    }
}
