#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Where a tmux server listens.
///
/// A *name* resolves against `TMUX_TMPDIR` in the environment captured by
/// ``Server``, so the same name can denote different servers in different
/// environments. A *path* denotes one socket. The two are mutually exclusive.
/// The endpoint initializers validate names and paths, including the path's
/// byte length. ``Server`` resolves names to absolute paths and validates the
/// resolved path at construction, before tmux can encounter a bind failure.
public enum Endpoint: Sendable, Hashable, Codable {
    case socketName(String)
    case socketPath(String)

    public init(socketName: String) throws(TmuxError) {
        guard !socketName.isEmpty else { throw .invalidEndpoint(.empty) }
        guard socketName != ".", socketName != "..",
            !socketName.contains("/"), !socketName.contains("\\"), !socketName.contains("\0")
        else { throw .invalidEndpoint(.invalidSocketName) }
        self = .socketName(socketName)
    }

    public init(socketPath: String) throws(TmuxError) {
        guard !socketPath.isEmpty else { throw .invalidEndpoint(.empty) }
        guard socketPath.hasPrefix("/"), !socketPath.contains("\0") else {
            throw .invalidEndpoint(.invalidSocketPath)
        }
        // `sun_path` is 104 bytes on the BSDs and 108 on Linux, including NUL.
        let byteCount = socketPath.utf8.count
        guard byteCount <= Endpoint.portableSocketPathByteLimit else {
            throw .invalidEndpoint(
                .socketPathTooLong(
                    actualBytes: byteCount,
                    maximumBytes: Endpoint.portableSocketPathByteLimit
                )
            )
        }
        self = .socketPath(socketPath)
    }

    /// The longest socket path this library will accept, in bytes.
    ///
    /// A UNIX socket path lives in a fixed array in the kernel, and the two
    /// supported systems size it differently: 108 bytes on Linux, 104 on
    /// Darwin. The smaller of the two, less the terminating NUL, is what a
    /// path can be and still bind on either — so the check is the same
    /// wherever it runs, and a path that works on one machine is not rejected
    /// on the next. Exceeding it fails at bind time, far from the call that
    /// chose the path, which is why this is checked up front.
    public static let portableSocketPathByteLimit = 103

    /// The argv pair that addresses this endpoint. tmux is always launched with
    /// an explicit endpoint so a caller can never reach the ambient server by
    /// accident.
    var addressArguments: [String] {
        switch self {
        case let .socketName(name): ["-L", name]
        case let .socketPath(path): ["-S", path]
        }
    }

    static func selected(
        socketPath: String?, socketName: String?, environment: [String: String]
    ) throws(TmuxError) -> Endpoint {
        guard socketPath == nil || socketName == nil else {
            throw .invalidEndpoint(.conflictingSelectors)
        }
        if let socketPath { return try Endpoint(socketPath: socketPath) }
        if let socketName { return try Endpoint(socketName: socketName) }
        if let path = environment["LIBTMUX_SOCKET_PATH"], !path.isEmpty {
            return try Endpoint(socketPath: path)
        }
        if let name = environment["LIBTMUX_SOCKET_NAME"], !name.isEmpty {
            return try Endpoint(socketName: name)
        }
        if let value = environment["TMUX"], !value.isEmpty {
            guard let context = TmuxContext(parsing: value) else {
                throw .invalidEndpoint(.invalidTmuxContext)
            }
            return try Endpoint(socketPath: context.socketPath)
        }
        return .socketName("default")
    }

    func resolved(environment: [String: String]) throws(TmuxError) -> ResolvedEndpoint {
        switch self {
        case let .socketPath(path):
            return ResolvedEndpoint(endpoint: try Endpoint(socketPath: path), directory: nil)
        case let .socketName(name):
            _ = try Endpoint(socketName: name)
            let configuredRoot = environment["TMUX_TMPDIR"] ?? ""
            let root = configuredRoot.isEmpty ? "/tmp" : configuredRoot
            guard root.hasPrefix("/"), !root.contains("\0") else {
                throw .invalidEndpoint(.invalidTemporaryDirectory)
            }
            // Preserve spelling: lexical '..' removal can hide a missing parent
            // or change traversal through a symlink.
            let directory = "\(root)/tmux-\(getuid())"
            return ResolvedEndpoint(
                endpoint: try Endpoint(socketPath: "\(directory)/\(name)"), directory: directory)
        }
    }
}

struct ResolvedEndpoint: Sendable {
    let endpoint: Endpoint
    let directory: String?

    func prepare() throws(TmuxError) {
        guard let directory else { return }
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw .processLaunchFailed(
                reason:
                    "Cannot create tmux socket directory \(directory): \(String(cString: strerror(errno)))"
            )
        }
        var status = stat()
        guard lstat(directory, &status) == 0 else {
            throw .processLaunchFailed(reason: "Cannot inspect tmux socket directory \(directory)")
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            status.st_uid == getuid(), status.st_mode & 0o007 == 0
        else {
            throw .processLaunchFailed(
                reason:
                    "tmux socket directory must be a real directory owned by this user with no other-user permissions: \(directory)"
            )
        }
    }
}
