import Foundation
import LibTmux

public struct ServerProvenance: Sendable, Hashable, Codable {
    public let selector: String
    public let selectionProvenance: String
    public let serverState: String
    public let configurationProvenance: String
    public let resolvedSocketPath: String?
    public let attachCommand: String?

    public init(
        selector: String,
        selectionProvenance: String,
        serverState: String,
        configurationProvenance: String,
        resolvedSocketPath: String? = nil,
        attachCommand: String? = nil
    ) {
        self.selector = selector
        self.selectionProvenance = selectionProvenance
        self.serverState = serverState
        self.configurationProvenance = configurationProvenance
        self.resolvedSocketPath = resolvedSocketPath
        self.attachCommand = attachCommand
    }

    public static let unknown = ServerProvenance(
        selector: "unknown",
        selectionProvenance: "unknown",
        serverState: "unprobed",
        configurationProvenance: "unknown",
        resolvedSocketPath: nil,
        attachCommand: nil
    )
}

package struct StartupPin: Sendable {
    package let server: Server
    package let authority: ToolAuthority
    package let provenance: ServerProvenance

    package init(server: Server, authority: ToolAuthority, provenance: ServerProvenance) {
        self.server = server
        self.authority = authority
        self.provenance = provenance
    }
}

/// How the executable is configured, read from the environment.
///
/// An MCP server is launched by a client that passes no flags, so environment
/// is the only configuration surface there is. Parsed here rather than in the
/// executable so a test can check what a given environment produces.
///
/// The server is on the socket `LIBTMUX_SOCKET_PATH` names, else on the socket
/// name `LIBTMUX_SOCKET` gives. With neither, it passes tmux no socket and
/// tmux picks the server: the one in `TMUX` when the client that launched this
/// process runs inside tmux, and its default socket otherwise.
public struct ServerConfiguration: Sendable, Hashable {
    /// `LIBTMUX_SOCKET`, unless `LIBTMUX_SOCKET_PATH` is set, which wins.
    public let socketName: String?
    /// `LIBTMUX_SOCKET_PATH`, an absolute path.
    public let socketPath: String?
    public let tmuxExecutable: String
    public let tmuxConfigurationFile: String?
    public let authority: ToolAuthority
    public let waitCeiling: Duration
    /// Anything the environment asked for that could not be honoured, to be
    /// reported on standard error rather than silently applied differently.
    public let warnings: [String]
    /// Fatal configuration errors. The executable reports these before it
    /// constructs or probes a tmux server.
    public let errors: [String]

    /// A wait longer than this is refused however it is configured. A client
    /// that hangs for minutes on one call is indistinguishable from one that
    /// has died.
    public static let hardWaitCeiling: Double = 300

    public init(environment: [String: String]) {
        var warnings: [String] = []
        var errors: [String] = []

        // A variable that is empty or only whitespace counts as unset, each one
        // on its own. Any other value is used as written.
        func set(_ name: String) -> String? {
            environment[name].flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            }
        }
        let configuredName = set("LIBTMUX_SOCKET")
        let configuredPath = set("LIBTMUX_SOCKET_PATH")
        let configuredConfiguration = environment["LIBTMUX_TMUX_CONFIG"]
        if let configuredPath, !configuredPath.hasPrefix("/") {
            errors.append("LIBTMUX_SOCKET_PATH must be an absolute path")
        }
        if let configuredConfiguration, !configuredConfiguration.hasPrefix("/") {
            errors.append("LIBTMUX_TMUX_CONFIG must be a nonempty absolute path")
        }
        self.socketPath = configuredPath
        // Both set: the path wins, as it does in the Python library, and tmux
        // ignores `-L` beside `-S` in any case.
        self.socketName = configuredPath == nil ? configuredName : nil
        self.tmuxExecutable = environment["LIBTMUX_TMUX_BIN"] ?? "tmux"
        self.tmuxConfigurationFile = configuredConfiguration

        if environment.keys.contains("LIBTMUX_TMUX_CONF") {
            errors.append("LIBTMUX_TMUX_CONF is retired; use LIBTMUX_TMUX_CONFIG")
        }

        if environment.keys.contains("LIBTMUX_SAFETY") {
            errors.append(
                "LIBTMUX_SAFETY is retired; use LIBTMUX_TOOLSETS, LIBTMUX_TOOLS, "
                    + "and LIBTMUX_EXCLUDE_TOOLS"
            )
        }
        if environment.keys.contains("LIBTMUX_MCP_TOOLS") {
            errors.append(
                "LIBTMUX_MCP_TOOLS is retired; use LIBTMUX_TOOLSETS= with LIBTMUX_TOOLS"
            )
        }

        let knownTools = Set(TmuxTools.definitions.map(\.name))
        let explicitToolsets = environment.keys.contains("LIBTMUX_TOOLSETS")
        let parsedToolsets = Self.parseList(
            environment["LIBTMUX_TOOLSETS"],
            variable: "LIBTMUX_TOOLSETS",
            allowWholeEmpty: true,
            errors: &errors
        )
        var toolsets: Set<Toolset> =
            explicitToolsets
            ? [] : [.inspect, .manage, .execute]
        for name in parsedToolsets {
            guard let toolset = Toolset(rawValue: name) else {
                errors.append("unknown LIBTMUX_TOOLSETS name: \(name)")
                continue
            }
            toolsets.insert(toolset)
        }

        let included = Set(
            Self.parseList(
                environment["LIBTMUX_TOOLS"],
                variable: "LIBTMUX_TOOLS",
                allowWholeEmpty: true,
                errors: &errors
            ))
        let excluded = Set(
            Self.parseList(
                environment["LIBTMUX_EXCLUDE_TOOLS"],
                variable: "LIBTMUX_EXCLUDE_TOOLS",
                allowWholeEmpty: true,
                errors: &errors
            ))
        for name in included.union(excluded).subtracting(knownTools).sorted() {
            errors.append("unknown tool name: \(name)")
        }
        self.authority = ToolAuthority(
            toolsets: errors.isEmpty ? toolsets : [],
            includedTools: errors.isEmpty ? included : [],
            excludedTools: errors.isEmpty ? excluded : []
        )

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
        self.errors = errors
    }

    private static func parseList(
        _ value: String?,
        variable: String,
        allowWholeEmpty: Bool,
        errors: inout [String]
    ) -> [String] {
        guard let value else { return [] }
        if value.isEmpty, allowWholeEmpty { return [] }
        let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard tokens.allSatisfy({ !$0.isEmpty }) else {
            errors.append("\(variable) contains an empty token")
            return []
        }
        return tokens
    }

    package func pinForStartup(server suppliedServer: Server? = nil) async throws(TmuxError)
        -> StartupPin
    {
        let server: Server
        if let suppliedServer {
            server = suppliedServer
        } else {
            server = try makeServer()
        }
        let wasRunning = try await server.isRunning()
        let resolvedSocketPath =
            if wasRunning {
                try await server.incarnation().socketPath
            } else {
                socketPath
            }
        return StartupPin(
            server: server,
            authority: authority,
            provenance: ServerProvenance(
                selector: socketPath.map { "path:\($0)" } ?? socketName.map { "name:\($0)" }
                    ?? Self.tmuxChoice,
                selectionProvenance: socketPath != nil
                    ? "socket-path" : socketName != nil ? "socket-name" : Self.tmuxChoice,
                serverState: wasRunning ? "existing" : "absent",
                configurationProvenance: wasRunning ? "unknown" : "user-configured",
                resolvedSocketPath: resolvedSocketPath,
                attachCommand: attachCommand(
                    runningAt: wasRunning ? resolvedSocketPath : nil)
            )
        )
    }

    /// What names a server that tmux picks, in a selector and in a provenance.
    private static let tmuxChoice = "tmux-choice"

    public func makeServer() throws(TmuxError) -> Server {
        if let socketPath {
            let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
            do {
                try FileManager.default.createDirectory(
                    atPath: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw .invocationFailed(reason: "cannot create socket directory: \(error)")
            }
            return try Server(
                socketPath: socketPath,
                tmuxExecutable: tmuxExecutable,
                configurationFile: tmuxConfigurationFile
            )
        }
        if let socketName {
            return try Server(
                socketName: socketName,
                tmuxExecutable: tmuxExecutable,
                configurationFile: tmuxConfigurationFile
            )
        }
        return Server(
            endpoint: .tmuxChoice,
            tmuxExecutable: tmuxExecutable,
            configurationFile: tmuxConfigurationFile
        )
    }

    public var endpointSummary: String {
        socketPath.map { "socket path \($0)" }
            ?? socketName.map { "socket name \($0)" }
            ?? "the server tmux picks"
    }

    /// The command that joins this server from a shell.
    ///
    /// A server tmux picked is named by the socket it turned out to be on once
    /// it runs, because the shell the command is pasted into may hold a
    /// different `TMUX` or `TMUX_TMPDIR` and pick another server.
    private func attachCommand(runningAt resolved: String?) -> String {
        let endpoint =
            socketPath.map { " -S \(Self.shellQuote($0))" }
            ?? socketName.map { " -L \(Self.shellQuote($0))" }
            ?? resolved.map { " -S \(Self.shellQuote($0))" }
            ?? ""
        return "\(Self.shellQuote(tmuxExecutable)) -N\(endpoint) attach"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
