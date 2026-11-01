import Foundation

/// Where a tmux server listens.
///
/// tmux resolves a *name* against `$TMUX_TMPDIR` at exec time, so the same name
/// can denote different servers in different environments. A *path* denotes one
/// socket. The two are mutually exclusive, and a value of either kind is always
/// addressable — the length check that a path must pass happens here rather
/// than at bind time, where it would surface as an opaque failure.
///
/// A third kind names no socket at all. tmux then chooses the server itself, as
/// it does for a command typed in a shell: the one in `TMUX` when the process
/// runs inside tmux, and the default socket in `TMUX_TMPDIR` otherwise.
public enum Endpoint: Sendable, Hashable, Codable {
    case socketName(String)
    case socketPath(String)
    /// No socket: tmux is passed neither `-L` nor `-S` and picks the server.
    ///
    /// The server is the one in `TMUX` inside tmux, and the default socket
    /// otherwise, so which one a command reaches depends on the environment it
    /// runs in. Name a socket when the answer must not.
    case tmuxChoice

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

    /// The endpoint an environment names: `LIBTMUX_SOCKET_PATH` as a path, else
    /// `LIBTMUX_SOCKET` as a name, else ``tmuxChoice``.
    ///
    /// A variable that is empty or only whitespace counts as unset, each one on
    /// its own, and any other value is used as written. The path wins when both
    /// are set. ``Server/init(tmuxExecutable:configurationFile:environment:)``
    /// is the public way to this, and describes the rule for callers.
    ///
    /// - Throws: ``TmuxError/invalidEndpoint(_:)`` for a path past
    ///   ``portableSocketPathByteLimit``. The error names the length and never
    ///   the value.
    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(TmuxError) {
        if let path = Endpoint.setValue(of: "LIBTMUX_SOCKET_PATH", in: environment) {
            self = try Endpoint(socketPath: path)
        } else if let name = Endpoint.setValue(of: "LIBTMUX_SOCKET", in: environment) {
            self = try Endpoint(socketName: name)
        } else {
            self = .tmuxChoice
        }
    }

    /// The value of `variable`, or `nil` when it is absent, empty or blank.
    private static func setValue(
        of variable: String, in environment: [String: String]
    ) -> String? {
        guard let value = environment[variable],
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return value
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

    /// The argv that addresses this endpoint: `-L` or `-S` with its value, and
    /// nothing for ``tmuxChoice``, which leaves the choice to tmux.
    var addressArguments: [String] {
        switch self {
        case let .socketName(name): ["-L", name]
        case let .socketPath(path): ["-S", path]
        case .tmuxChoice: []
        }
    }
}
