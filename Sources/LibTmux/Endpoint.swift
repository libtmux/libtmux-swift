/// Where a tmux server listens.
///
/// tmux resolves a *name* against `$TMUX_TMPDIR` at exec time, so the same name
/// can denote different servers in different environments. A *path* denotes one
/// socket. The two are mutually exclusive, and a value of either kind is always
/// addressable — the length check that a path must pass happens here rather
/// than at bind time, where it would surface as an opaque failure.
public enum Endpoint: Sendable, Hashable, Codable {
    case socketName(String)
    case socketPath(String)

    public init(socketName: String) throws(TmuxError) {
        guard !socketName.isEmpty else {
            throw .invalidEndpoint(.empty)
        }
        self = .socketName(socketName)
    }

    public init(socketPath: String) throws(TmuxError) {
        guard !socketPath.isEmpty else {
            throw .invalidEndpoint(.empty)
        }
        // `sun_path` is 104 bytes on the BSDs and 108 on Linux; the portable
        // budget is the smaller one, minus its terminator.
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
}
