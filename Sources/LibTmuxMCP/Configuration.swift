import Foundation
import LibTmux

/// How the executable is configured, read from the environment.
///
/// An MCP server is launched by a client that passes no flags, so environment
/// is the only configuration surface there is. Parsed here rather than in the
/// executable so a test can check what a given environment produces.
public struct ServerConfiguration: Sendable, Hashable {
    public let socketName: String?
    public let socketPath: String?
    public let tmuxExecutable: String
    public let authority: ToolAuthority
    public var tier: SafetyTier { authority.tier }
    public let waitCeiling: Duration
    /// Anything the environment asked for that could not be honoured, to be
    /// reported on standard error rather than silently applied differently.
    public let warnings: [String]

    /// A wait longer than this is refused however it is configured. A client
    /// that hangs for minutes on one call is indistinguishable from one that
    /// has died.
    public static let hardWaitCeiling: Double = 300

    public init(environment: [String: String]) {
        var warnings: [String] = []

        self.socketPath = environment["LIBTMUX_SOCKET_PATH"]
        self.socketName =
            socketPath == nil ? (environment["LIBTMUX_SOCKET"] ?? "default") : nil
        self.tmuxExecutable = environment["LIBTMUX_TMUX_BIN"] ?? "tmux"

        let resolvedTier: SafetyTier
        if let requested = environment["LIBTMUX_SAFETY"] {
            if let tier = SafetyTier(rawValue: requested) {
                resolvedTier = tier
            } else {
                // Falling back to the *lowest* tier rather than the default:
                // a misspelt value is a configuration the operator did not
                // check, and reading is the only assumption safe to make on
                // their behalf.
                warnings.append(
                    "LIBTMUX_SAFETY=\(requested) is not one of "
                        + SafetyTier.allCases.map(\.rawValue).joined(separator: ", ")
                        + "; serving readonly tools only"
                )
                resolvedTier = .readonly
            }
        } else {
            resolvedTier = .readonly
        }

        if let exactNames = environment["LIBTMUX_MCP_TOOLS"] {
            let configured = ToolAuthority.configured(
                tier: resolvedTier,
                exactNames: exactNames
            )
            self.authority = configured.authority
            if let warning = configured.warning { warnings.append(warning) }
        } else {
            self.authority = ToolAuthority(tier: resolvedTier)
        }

        let rawCeiling = environment["LIBTMUX_MCP_WAIT_MAX_SECONDS"]
        var requestedCeiling: Double?
        if let rawCeiling {
            if let parsed = Double(rawCeiling), parsed.isFinite {
                requestedCeiling = parsed
            } else {
                warnings.append(
                    "LIBTMUX_MCP_WAIT_MAX_SECONDS=\(rawCeiling) is not a finite number; "
                        + "using 120s"
                )
            }
        }
        if let requestedCeiling, requestedCeiling > Self.hardWaitCeiling {
            warnings.append(
                "LIBTMUX_MCP_WAIT_MAX_SECONDS=\(rawCeiling ?? String(requestedCeiling)) "
                    + "exceeds the "
                    + "\(Int(Self.hardWaitCeiling))s hard ceiling; using that instead"
            )
        }
        if let requestedCeiling, requestedCeiling < 1 {
            warnings.append(
                "LIBTMUX_MCP_WAIT_MAX_SECONDS=\(rawCeiling ?? String(requestedCeiling)) "
                    + "is below the 1s floor; using that instead"
            )
        }
        let ceiling = min(requestedCeiling ?? 120, Self.hardWaitCeiling)
        self.waitCeiling = .seconds(max(1, ceiling))
        self.warnings = warnings
    }

    public func makeServer() throws(TmuxError) -> Server {
        if let socketPath {
            return try Server(socketPath: socketPath, tmuxExecutable: tmuxExecutable)
        }
        return try Server(
            socketName: socketName ?? "default",
            tmuxExecutable: tmuxExecutable
        )
    }

    public var endpointSummary: String {
        socketPath.map { "socket path \($0)" }
            ?? "socket name \(socketName ?? "default")"
    }
}
